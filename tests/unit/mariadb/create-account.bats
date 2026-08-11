#!/usr/bin/env bats

setup() {
  export TEST_TMPDIR="$BATS_TEST_TMPDIR"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mariadb/create-account.sh"
  export MARIADB_NAME=mariadb
  export SECRETS_AUTODETECT_DEFAULT=false
  export _LOG_CURRENT_LEVEL=4
  mkdir -p "${TEST_TMPDIR}/bin"

  # PGP behavior is deterministic here; integration tests own real crypto.
  cat > "${TEST_TMPDIR}/bin/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" --import "*) cat >/dev/null; [[ "${GPG_FAIL_IMPORT:-0}" != 1 ]]; exit 0 ;;
  *" --with-colons "*) printf 'fpr:::::::::0123456789ABCDEF0123456789ABCDEF01234567:\n'; exit 0 ;;
  *" --encrypt "*) cat >/dev/null; printf '%s\n' '-----BEGIN PGP MESSAGE-----' 'encrypted-test-payload' '-----END PGP MESSAGE-----'; exit 0 ;;
esac
exit 1
EOF

  cat > "${TEST_TMPDIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --context || "$1" == --namespace || "$1" == --kubeconfig || "$1" == -n ]]; then
    shift 2
  else
    args+=("$1")
    shift
  fi
done
cmd="${args[0]:-}"
if [[ "$cmd" == exec ]]; then
  printf 'exec %s\n' "${args[1]:-}" >> "${TEST_TMPDIR}/kubectl.log"
else
  printf '%s\n' "${args[*]}" >> "${TEST_TMPDIR}/kubectl.log"
fi

if [[ "$cmd" == cluster-info ]]; then
  [[ "${KUBECTL_UNAVAILABLE:-0}" != 1 ]] || exit 1
  exit 0
fi

if [[ "$cmd" == get ]]; then
  resource="${args[1]:-}"; name="${args[2]:-}"; output="${args[*]}"
  if [[ "$resource" == mariadb && "$name" == mariadb ]]; then
    case "$output" in
      *status.currentPrimary*) printf 'mariadb-0' ;;
      *spec.replicas*) printf '1' ;;
      *) exit 1 ;;
    esac
    exit 0
  fi
  if [[ "$resource" == statefulset && "$name" == mariadb ]]; then printf '1'; exit 0; fi
  if [[ "$resource" == secret ]]; then
    case "$name" in
      svc-password) printf 'Rml4ZWRTZXJ2aWNlUGFzczEyMyE='; exit 0 ;;
      empty-password) printf ''; exit 0 ;;
      *) exit 1 ;;
    esac
  fi
fi

if [[ "$cmd" == exec ]]; then
  pod="${args[1]:-}"
  split=0
  for i in "${!args[@]}"; do [[ "${args[$i]}" != -- ]] || { split=$((i + 1)); break; }; done
  command=("${args[@]:$split}")
  if [[ "$pod" == mariadb-0 && "${command[*]}" == 'printenv MARIADB_ROOT_PASSWORD' ]]; then
    printf 'root-pass'; exit 0
  fi
  query="${command[$((${#command[@]} - 1))]}"
  printf '%s\n' "$query" >> "${TEST_TMPDIR}/sql.log"
  case "$query" in
    SELECT\ COUNT\(\*\)*)
      [[ "${SQL_FAIL_LOOKUP:-0}" != 1 ]] || exit 1
      printf '%s\n' "${ACCOUNT_COUNT:-0}"
      ;;
    CREATE\ USER*|ALTER\ USER*) [[ "${SQL_FAIL_MUTATION:-0}" != 1 ]] || exit 1 ;;
    REVOKE*) [[ "${SQL_FAIL_REVOKE:-0}" != 1 ]] || exit 1 ;;
    GRANT*) [[ "${SQL_FAIL_GRANT:-0}" != 1 ]] || exit 1 ;;
    SHOW\ GRANTS*)
      [[ "${SQL_FAIL_VERIFY:-0}" != 1 ]] || exit 1
      if [[ "${VERIFY_MISMATCH:-0}" == 1 ]]; then
        printf "GRANT INSERT ON *.* TO 'svc'@'%%'\n"
      elif [[ -n "${EXPECTED_DATABASE:-}" ]]; then
        printf "GRANT %s ON \`%s\`.* TO 'svc'@'%%'\n" "${EXPECTED_PRIVILEGES:-SELECT}" "$EXPECTED_DATABASE"
      else
        printf "GRANT SELECT ON *.* TO 'svc'@'%%'\n"
      fi
      ;;
  esac
  exit 0
fi

echo "unexpected kubectl invocation: ${args[*]}" >&2
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/gpg" "${TEST_TMPDIR}/bin/kubectl"
}

actual_args() {
  printf '%s\n' \
    --namespace mariadb-1 --mdb mariadb --username svc \
    --dry-run false --confirm true --json
}

json_field() { printf '%s' "$output" | jq -r "$1"; }

@test "dry-run defaults to all-database SELECT and first-login expiry" {
  run "$SCRIPT" --namespace mariadb-1 --username svc --json
  [ "$status" -eq 0 ]
  [ "$(json_field '.status')" = READY ]
  [ "$(json_field '.scope.kind')" = all_databases_read_only ]
  [ "$(json_field '.scope.grant')" = '*.*' ]
  [ "$(json_field '.privileges | join(",")')" = SELECT ]
  [ "$(json_field '.password_expire_mode')" = first_login ]
  [ "$(json_field '.sql_plan[0]')" = "CREATE USER 'svc'@'%' IDENTIFIED BY '<redacted>' PASSWORD EXPIRE" ]
  [[ "$output" != *password_secret* ]]
}

@test "all-database scope fails closed for non-SELECT privileges" {
  run "$SCRIPT" --namespace mariadb-1 --username svc --privileges SELECT,INSERT --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
  [[ "$(json_field '.errors | join(" ")')" == *'permits exactly SELECT'* ]]
}

@test "invalid privileges produce an empty privileges array" {
  run "$SCRIPT" --namespace mariadb-1 --username svc --privileges NOT_ALLOWED --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
  [ "$(json_field '.privileges | length')" -eq 0 ]
}

@test "explicit global database spelling is rejected" {
  run "$SCRIPT" --namespace mariadb-1 --database '*.*' --username svc --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
}

@test "database scope retains requested allowed privileges" {
  run "$SCRIPT" --namespace mariadb-1 --database app_db --username svc --privileges SELECT,INSERT --json
  [ "$(json_field '.status')" = READY ]
  [ "$(json_field '.scope.kind')" = database ]
  [ "$(json_field '.scope.grant')" = '`app_db`.*' ]
  [ "$(json_field '.privileges | join(",")')" = SELECT,INSERT ]
}

@test "all native expiry modes produce their MariaDB SQL" {
  local mode expected days
  for mode in first_login never default; do
    case "$mode" in
      first_login) expected='PASSWORD EXPIRE' ;;
      never) expected='PASSWORD EXPIRE NEVER' ;;
      default) expected='PASSWORD EXPIRE DEFAULT' ;;
    esac
    run "$SCRIPT" --namespace mariadb-1 --username svc --password-expire-mode "$mode" --json
    [ "$(json_field '.status')" = READY ]
    [[ "$(json_field '.sql_plan[0]')" == *"$expected" ]]
  done
  run "$SCRIPT" --namespace mariadb-1 --username svc --password-expire-mode interval --validity-days 30 --json
  [[ "$(json_field '.sql_plan[0]')" == *'PASSWORD EXPIRE INTERVAL 30 DAY' ]]
}

@test "expiry validity_days combinations are validated" {
  run "$SCRIPT" --namespace mariadb-1 --username svc --password-expire-mode interval --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
  run "$SCRIPT" --namespace mariadb-1 --username svc --password-expire-mode never --validity-days 7 --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
  run "$SCRIPT" --namespace mariadb-1 --username svc --password-expire-mode interval --validity-days nope --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
}

@test "password generation policy rejects short lengths and unsafe charsets" {
  run "$SCRIPT" --namespace mariadb-1 --username svc --password-length 11 --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
  run "$SCRIPT" --namespace mariadb-1 --username svc --password-special-max nope --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
  run "$SCRIPT" --namespace mariadb-1 --username svc --password-special-chars "safe'no" --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
}

@test "generated plaintext delivery follows the MongoDB payload shape and policy" {
  run "$SCRIPT" $(actual_args)
  [ "$(json_field '.status')" = CREATED ]
  [ "$(json_field '.reason_code')" = ACCOUNT_CREATED ]
  [ "$(json_field '.delivery_payload.mode')" = one_time_plaintext ]
  password="$(json_field '.delivery_payload.password')"
  [ "${#password}" -eq 24 ]
  [[ "$password" =~ [a-z] && "$password" =~ [A-Z] && "$password" =~ [0-9] ]]
  specials="$(printf '%s' "$password" | sed 's/[[:alnum:]]//g')"
  [ "${#specials}" -le 4 ]
}

@test "encrypted delivery returns the MongoDB-compatible payload" {
  run "$SCRIPT" $(actual_args) --password-delivery-mode encrypted_payload --recipient-pgp-pubkey test-key
  [ "$(json_field '.status')" = CREATED ]
  [ "$(json_field '.delivery_payload.mode')" = encrypted_payload ]
  [ "$(json_field '.delivery_payload.recipient_key_fingerprint')" = 0123456789ABCDEF0123456789ABCDEF01234567 ]
  [ "$(json_field '.delivery_payload.content_type')" = application/pgp-encrypted ]
  [[ "$(json_field '.delivery_payload.ciphertext')" == *'BEGIN PGP MESSAGE'* ]]
  [ "$(json_field '.delivery_payload.password // empty')" = '' ]
}

@test "encryption failure returns DELIVERY_ENCRYPT_FAILED without mutation" {
  export GPG_FAIL_IMPORT=1
  run "$SCRIPT" $(actual_args) --password-delivery-mode encrypted_payload --recipient-pgp-pubkey invalid-key
  [ "$(json_field '.reason_code')" = DELIVERY_ENCRYPT_FAILED ]
  ! grep -qE '^(CREATE|ALTER|GRANT)' "${TEST_TMPDIR}/sql.log"
}

@test "generator failure returns PASSWORD_GENERATION_FAILED without mutation" {
  cat > "${TEST_TMPDIR}/bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/python3"
  run "$SCRIPT" $(actual_args)
  [ "$(json_field '.reason_code')" = PASSWORD_GENERATION_FAILED ]
  ! grep -qE '^(CREATE|ALTER|GRANT)' "${TEST_TMPDIR}/sql.log"
}

@test "caller-provided Secret is read-only and returned by reference" {
  run "$SCRIPT" $(actual_args) --password-secret-name svc-password
  [ "$(json_field '.status')" = CREATED ]
  [ "$(json_field '.delivery_payload.mode')" = caller_provided_secret ]
  [ "$(json_field '.delivery_payload.secret_name')" = svc-password ]
  [ "$(json_field '.delivery_payload.secret_key')" = password ]
  [[ "$output" != *FixedServicePass123* ]]
  grep -q '^get secret svc-password ' "${TEST_TMPDIR}/kubectl.log"
  ! grep -qE '^(create|apply|patch|replace|delete|annotate|label) secret ' "${TEST_TMPDIR}/kubectl.log"
}

@test "caller-provided Secret supports a dotted data key" {
  run "$SCRIPT" $(actual_args) --password-secret-name svc-password --password-secret-key db.password
  [ "$(json_field '.status')" = CREATED ]
  [ "$(json_field '.delivery_payload.secret_key')" = db.password ]
  grep -Fq "jsonpath={.data['db.password']}" "${TEST_TMPDIR}/kubectl.log"
}

@test "caller Secret and generated delivery options are mutually exclusive" {
  run "$SCRIPT" --namespace mariadb-1 --username svc --password-secret-name svc-password --password-delivery-mode encrypted_payload --recipient-pgp-pubkey key --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
}

@test "protected and missing caller Secrets fail without exposing credentials" {
  run "$SCRIPT" $(actual_args) --password-secret-name mariadb
  [ "$(json_field '.reason_code')" = PROTECTED_SECRET ]
  run "$SCRIPT" $(actual_args) --password-secret-name missing
  [ "$(json_field '.reason_code')" = PASSWORD_SECRET_UNAVAILABLE ]
  [[ "$output" != *root-pass* ]]
}

@test "existing account fails by default" {
  export ACCOUNT_COUNT=1
  run "$SCRIPT" $(actual_args)
  [ "$(json_field '.status')" = ERROR ]
  [ "$(json_field '.reason_code')" = ACCOUNT_ALREADY_EXISTS ]
  ! grep -qE '^(ALTER|GRANT|REVOKE)' "${TEST_TMPDIR}/sql.log"
}

@test "allow_existing recreates credential and replaces grants" {
  export ACCOUNT_COUNT=1 EXPECTED_DATABASE=app_db EXPECTED_PRIVILEGES='INSERT, SELECT'
  run "$SCRIPT" $(actual_args) --database app_db --privileges SELECT,INSERT --allow-existing true --password-expire-mode never
  [ "$(json_field '.status')" = RECREATED ]
  [ "$(json_field '.reason_code')" = ACCOUNT_RECREATED ]
  grep -q '^ALTER USER .*PASSWORD EXPIRE NEVER;' "${TEST_TMPDIR}/sql.log"
  grep -q '^REVOKE ALL PRIVILEGES, GRANT OPTION FROM' "${TEST_TMPDIR}/sql.log"
  grep -q '^GRANT SELECT, INSERT ON `app_db`\.\*' "${TEST_TMPDIR}/sql.log"
}

@test "SHOW GRANTS verification accepts canonical ALL PRIVILEGES" {
  export EXPECTED_DATABASE=app_db EXPECTED_PRIVILEGES='ALL PRIVILEGES'
  run "$SCRIPT" $(actual_args) --database app_db --privileges ALL --allow-admin-privileges true
  [ "$(json_field '.status')" = CREATED ]
}

@test "SHOW GRANTS must contain the effective requested grant" {
  export VERIFY_MISMATCH=1
  run "$SCRIPT" $(actual_args)
  [ "$(json_field '.reason_code')" = SQL_VERIFY_FAILED ]
  [ "$(json_field '.mutation_applied')" = true ]
}

@test "grant failure reports an explicit partial mutation" {
  export SQL_FAIL_GRANT=1
  run "$SCRIPT" $(actual_args) --password-secret-name svc-password
  [ "$(json_field '.reason_code')" = SQL_FAILED ]
  [ "$(json_field '.mutation_applied')" = true ]
  [[ "$(json_field '.summary')" == *'credential changed'* ]]
  [[ "$output" != *FixedServicePass123* ]]
}

@test "revoke failure after ALTER reports an explicit partial mutation" {
  export ACCOUNT_COUNT=1 SQL_FAIL_REVOKE=1
  run "$SCRIPT" $(actual_args) --allow-existing true --password-secret-name svc-password
  [ "$(json_field '.reason_code')" = SQL_FAILED ]
  [ "$(json_field '.mutation_applied')" = true ]
  [[ "$(json_field '.summary')" == *'revoking the prior grants failed'* ]]
}

@test "SQL mutation failures are redacted" {
  export SQL_FAIL_MUTATION=1
  run "$SCRIPT" $(actual_args) --password-secret-name svc-password
  [ "$(json_field '.reason_code')" = ACCOUNT_MUTATION_FAILED ]
  [[ "$output" != *FixedServicePass123* ]]
  [[ "$output" != *root-pass* ]]
}

@test "confirmed execution is required for mutations" {
  run "$SCRIPT" --namespace mariadb-1 --username svc --dry-run false --json
  [ "$(json_field '.reason_code')" = CONFIRM_REQUIRED ]
  [ ! -e "${TEST_TMPDIR}/sql.log" ]
}
