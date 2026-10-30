#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Per test: kubectl and gpg PATH stubs that log to $TEST_TMPDIR,
# plus the env create-account.sh reads.
setup() {
  bats_require_minimum_version 1.5.0
  export TEST_TMPDIR="$BATS_TEST_TMPDIR"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mariadb/create-account.sh"
  export MARIADB_NAME=mariadb
  export EXPECTED_DATABASE=app_db
  unset ACCOUNT_PRIVILEGES ALLOW_EXISTING ALLOW_ADMIN_PRIVILEGES ALLOW_GLOBAL
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
  *" --encrypt "*) cat > "${TEST_TMPDIR}/encrypted-input"; printf '%s\n' '-----BEGIN PGP MESSAGE-----' 'encrypted-test-payload' '-----END PGP MESSAGE-----'; exit 0 ;;
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
      svc-password|mariadb)
        printf '%s' '{"data":{"password":"Rml4ZWRTZXJ2aWNlUGFzczEyMyE=","db.password":"RG90dGVkUGFzczEyMyE=","monitor.password":"Rml4ZWRTZXJ2aWNlUGFzczEyMyE="}}'
        exit 0 ;;
      empty-password) printf '%s' '{"data":{"password":""}}'; exit 0 ;;
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
    SHOW\ PRIVILEGES)
      [[ "${SQL_FAIL_PRIVILEGES:-0}" != 1 ]] || exit 1
      while IFS='|' read -r name level; do
        [[ "$name" != "${OMIT_PRIVILEGE:-}" ]] || continue
        printf '%s\t%s\tfixture\n' "$name" "$level"
      done <<'PRIVILEGES'
SELECT|Databases,Tables,Columns
INSERT|Databases,Tables,Columns
UPDATE|Databases,Tables,Columns
DELETE|Databases,Tables
CREATE|Databases,Tables,Indexes
DROP|Databases,Tables
REFERENCES|Databases,Tables,Columns
INDEX|Databases,Tables
ALTER|Databases,Tables
CREATE TEMPORARY TABLES|Databases
LOCK TABLES|Databases
EXECUTE|Functions,Procedures
CREATE VIEW|Databases,Tables
SHOW VIEW|Databases,Tables
CREATE ROUTINE|Databases
ALTER ROUTINE|Functions,Procedures
EVENT|Server Admin
TRIGGER|Tables
DELETE HISTORY|Databases,Tables
PROCESS|Server Admin
BINLOG MONITOR|Server Admin
SLAVE MONITOR|Server Admin
REPLICATION SLAVE|Server Admin
SHOW DATABASES|Server Admin
RELOAD|Server Admin
SUPER|Server Admin
FILE|File access on server
SHUTDOWN|Server Admin
CREATE USER|Server Admin
Read_only admin|Server Admin
GRANT OPTION|Databases,Tables,Functions,Procedures
PRIVILEGES
      ;;
    CREATE\ USER*|ALTER\ USER*)
      [[ "${SQL_FAIL_MUTATION:-0}" != 1 ]] || exit 1
      touch "${TEST_TMPDIR}/mutation-applied"
      ;;
    REVOKE*) [[ "${SQL_FAIL_REVOKE:-0}" != 1 ]] || exit 1 ;;
    GRANT*) [[ "${SQL_FAIL_GRANT:-0}" != 1 ]] || exit 1 ;;
    SHOW\ GRANTS*)
      if [[ -e "${TEST_TMPDIR}/mutation-applied" ]]; then
        [[ "${SQL_FAIL_VERIFY:-0}" != 1 ]] || exit 1
      else
        [[ "${SQL_FAIL_EXISTING_GRANTS:-0}" != 1 ]] || exit 1
      fi
      grants="$(
        if [[ ! -e "${TEST_TMPDIR}/mutation-applied" && -n "${PREEXISTING_GRANTS:-}" ]]; then
          printf '%s\n' "$PREEXISTING_GRANTS"
        elif [[ -n "${EXPECTED_GRANTS:-}" ]]; then
          printf '%s\n' "$EXPECTED_GRANTS"
        elif [[ "${VERIFY_MISMATCH:-0}" == 1 ]]; then
          printf "GRANT INSERT ON *.* TO 'svc'@'%%'\n"
        elif [[ -n "${EXPECTED_DATABASE:-}" ]]; then
          printf "GRANT %s ON \`%s\`.* TO 'svc'@'%%'\n" "${EXPECTED_PRIVILEGES:-SELECT}" "${EXPECTED_DATABASE//_/\\_}"
        else
          printf "GRANT SELECT ON *.* TO 'svc'@'%%'\n"
        fi
      )"
      if [[ " ${command[*]} " == *" --raw "* ]]; then
        printf 'raw-show-grants\n' >> "${TEST_TMPDIR}/client-flags.log"
      else
        # Model mariadb --batch transport escaping instead of raw SQL output.
        grants="${grants//\\/\\\\}"
      fi
      printf '%s\n' "$grants"
      ;;
    *) echo "unexpected SQL: $query" >&2; exit 1 ;;
  esac
  exit 0
fi

echo "unexpected kubectl invocation: ${args[*]}" >&2
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/gpg" "${TEST_TMPDIR}/bin/kubectl"
}

# Common apply-mode arguments; tests append the options they exercise.
ACTUAL_ARGS=(
  --namespace mariadb-1 --mdb mariadb --username svc --database app_db
  --dry-run false --confirm true --json
)

# Print one jq path from the task result captured in $output.
json_field() { printf '%s' "$output" | jq -r "$1"; }

@test "dry-run defaults to a database read-only profile without credentials or cluster calls" {
  run "$SCRIPT" --namespace mariadb-1 --database app_db --username svc --json
  [ "$status" -eq 0 ]
  [ "$(json_field '.status')" = READY ]
  [ "$(json_field '.account_type')" = ro ]
  [ "$(json_field '.if_exists')" = skip ]
  [ "$(json_field '.scope.kind')" = database ]
  [ "$(json_field '.grants[0].scope')" = '`app\_db`.*' ]
  [ "$(json_field '.privileges | join(",")')" = SELECT ]
  [ "$(json_field '.delivery_payload')" = null ]
  [ "$(json_field '.mutation_applied')" = false ]
  [[ "$(json_field '.sql_plan[0]')" == *"'<redacted>' PASSWORD EXPIRE" ]]
  [ ! -e "${TEST_TMPDIR}/kubectl.log" ]
}

@test "read-only profile requires an explicit database rather than exposing system schemas" {
  run "$SCRIPT" --namespace mariadb-1 --username svc --json
  [ "$status" -eq 2 ]
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
}

@test "unknown profiles and caller-selected global scope are rejected" {
  run "$SCRIPT" --namespace mariadb-1 --username svc --account-type arbitrary --json
  [ "$status" -eq 2 ]
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
  run "$SCRIPT" --namespace mariadb-1 --username svc --database '*.*' --json
  [ "$status" -eq 2 ]
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
}

@test "admin username is allowed but platform system accounts remain protected" {
  run "$SCRIPT" --namespace mariadb-1 --database app_db --username admin --account-type admin --json
  [ "$status" -eq 0 ]
  [ "$(json_field '.privileges | index("DROP") != null')" = true ]
  [ "$(json_field '.privileges | index("CREATE TEMPORARY TABLES") != null')" = true ]
  for name in root mysql mariadb.sys; do
    run "$SCRIPT" --namespace mariadb-1 --username "$name" --account-type none --json
    [ "$status" -eq 2 ]
    [ "$(json_field '.reason_code')" = INVALID_INPUT ]
  done
}

@test "profile rejects global-only privileges at database scope before mutation" {
  export MARIADB_ACCOUNT_RO_DATABASE_PRIVILEGES_DEFAULT=PROCESS
  run "$SCRIPT" "${ACTUAL_ARGS[@]}"
  [ "$status" -eq 2 ]
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
  [ ! -e "${TEST_TMPDIR}/kubectl.log" ]
}

@test "all native expiry modes produce their MariaDB SQL" {
  local mode expected
  for mode in first_login never default; do
    case "$mode" in
      first_login) expected='PASSWORD EXPIRE' ;;
      never) expected='PASSWORD EXPIRE NEVER' ;;
      default) expected='PASSWORD EXPIRE DEFAULT' ;;
    esac
    run "$SCRIPT" --namespace mariadb-1 --database app_db --username svc --password-expire-mode "$mode" --json
    [ "$(json_field '.status')" = READY ]
    [[ "$(json_field '.sql_plan[0]')" == *"$expected" ]]
  done
  run "$SCRIPT" --namespace mariadb-1 --database app_db --username svc --password-expire-mode interval --validity-days 30 --json
  [[ "$(json_field '.sql_plan[0]')" == *'PASSWORD EXPIRE INTERVAL 30 DAY' ]]
}

@test "expiry validity_days combinations are validated" {
  run "$SCRIPT" --namespace mariadb-1 --database app_db --username svc --password-expire-mode interval --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
  run "$SCRIPT" --namespace mariadb-1 --database app_db --username svc --password-expire-mode never --validity-days 7 --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
  run "$SCRIPT" --namespace mariadb-1 --database app_db --username svc --password-expire-mode interval --validity-days nope --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
}

@test "password generation policy rejects short lengths and unsafe charsets" {
  run "$SCRIPT" --namespace mariadb-1 --database app_db --username svc --password-length 11 --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
  run "$SCRIPT" --namespace mariadb-1 --database app_db --username svc --password-special-max nope --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
  run "$SCRIPT" --namespace mariadb-1 --database app_db --username svc --password-special-chars "safe'no" --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
}

@test "generated plaintext delivery follows the MongoDB payload shape and policy" {
  run "$SCRIPT" "${ACTUAL_ARGS[@]}"
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
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --password-delivery-mode encrypted_payload --recipient-pgp-pubkey test-key
  [ "$(json_field '.status')" = CREATED ]
  [ "$(json_field '.delivery_payload.mode')" = encrypted_payload ]
  [ "$(json_field '.delivery_payload.recipient_key_fingerprint')" = 0123456789ABCDEF0123456789ABCDEF01234567 ]
  [ "$(json_field '.delivery_payload.content_type')" = application/pgp-encrypted ]
  [[ "$(json_field '.delivery_payload.ciphertext')" == *'BEGIN PGP MESSAGE'* ]]
  [ "$(json_field '.delivery_payload.password // empty')" = '' ]
}

@test "encryption failure returns DELIVERY_ENCRYPT_FAILED without mutation" {
  export GPG_FAIL_IMPORT=1
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --password-delivery-mode encrypted_payload --recipient-pgp-pubkey invalid-key
  [ "$(json_field '.reason_code')" = DELIVERY_ENCRYPT_FAILED ]
  run ! grep -qE '^(CREATE|ALTER|GRANT)' "${TEST_TMPDIR}/sql.log"
}

@test "generator failure returns PASSWORD_GENERATION_FAILED without mutation" {
  cat > "${TEST_TMPDIR}/bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/python3"
  run "$SCRIPT" "${ACTUAL_ARGS[@]}"
  [ "$(json_field '.reason_code')" = PASSWORD_GENERATION_FAILED ]
  run ! grep -qE '^(CREATE|ALTER|GRANT)' "${TEST_TMPDIR}/sql.log"
}

@test "caller-provided Secret is read-only and returned by reference" {
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --password-secret-name svc-password
  [ "$(json_field '.status')" = CREATED ]
  [ "$(json_field '.delivery_payload.mode')" = caller_provided_secret ]
  [ "$(json_field '.delivery_payload.secret_name')" = svc-password ]
  [ "$(json_field '.delivery_payload.secret_key')" = password ]
  [[ "$output" != *FixedServicePass123* ]]
  grep -q '^get secret svc-password ' "${TEST_TMPDIR}/kubectl.log"
  run ! grep -qE '^(create|apply|patch|replace|delete|annotate|label) secret ' "${TEST_TMPDIR}/kubectl.log"
}

@test "caller-provided Secret supports a dotted data key" {
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --password-secret-name svc-password --password-secret-key db.password
  [ "$(json_field '.status')" = CREATED ]
  [ "$(json_field '.delivery_payload.secret_key')" = db.password ]
  grep -Fq "get secret svc-password -o json" "${TEST_TMPDIR}/kubectl.log"
  grep -Fq "IDENTIFIED BY 'DottedPass123!'" "${TEST_TMPDIR}/sql.log"
}

@test "caller Secret and generated delivery options are mutually exclusive" {
  run "$SCRIPT" --namespace mariadb-1 --database app_db --username svc --password-secret-name svc-password --password-delivery-mode encrypted_payload --recipient-pgp-pubkey key --json
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
}

@test "protected and missing caller Secrets fail without exposing credentials" {
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --password-secret-name mariadb
  [ "$(json_field '.reason_code')" = PROTECTED_SECRET ]
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --password-secret-name missing
  [ "$(json_field '.reason_code')" = PASSWORD_SECRET_UNAVAILABLE ]
  [[ "$output" != *root-pass* ]]
}

@test "existing account fails when if_exists is error" {
  export ACCOUNT_COUNT=1
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --if-exists error
  [ "$(json_field '.status')" = ERROR ]
  [ "$(json_field '.reason_code')" = ACCOUNT_ALREADY_EXISTS ]
  run ! grep -qE '^(ALTER|GRANT|REVOKE)' "${TEST_TMPDIR}/sql.log"
}

@test "if_exists recreate rotates credential and replaces grants" {
  export ACCOUNT_COUNT=1 EXPECTED_PRIVILEGES='INSERT, SELECT'
  export MARIADB_ACCOUNT_RO_DATABASE_PRIVILEGES_DEFAULT=SELECT,INSERT
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --if-exists recreate --password-expire-mode never
  [ "$(json_field '.status')" = RECREATED ]
  [ "$(json_field '.reason_code')" = ACCOUNT_RECREATED ]
  grep -q '^ALTER USER .*PASSWORD EXPIRE NEVER;' "${TEST_TMPDIR}/sql.log"
  grep -q '^REVOKE ALL PRIVILEGES, GRANT OPTION FROM' "${TEST_TMPDIR}/sql.log"
  grep -q '^GRANT SELECT, INSERT ON `app\\_db`\.\*' "${TEST_TMPDIR}/sql.log"
}

@test "recreate blocks role and PROXY grants before reading a password Secret" {
  export ACCOUNT_COUNT=1
  existing_grants=(
    "GRANT \`app_role\` TO \`svc\`@\`%\`"
    "GRANT PROXY ON 'other'@'%' TO 'svc'@'%'"
  )
  for grant in "${existing_grants[@]}"; do
    export PREEXISTING_GRANTS="$grant"
    run "$SCRIPT" "${ACTUAL_ARGS[@]}" --if-exists recreate --password-secret-name missing
    [ "$status" -eq 1 ]
    [ "$(json_field '.status')" = BLOCKED ]
    [ "$(json_field '.reason_code')" = UNSUPPORTED_EXISTING_GRANTS ]
    [ "$(json_field '.account_exists')" = true ]
    [ "$(json_field '.mutation_applied')" = false ]
    [ "$(json_field '.delivery_payload')" = null ]
    [ ! -e "${TEST_TMPDIR}/mutation-applied" ]
    # run ! overwrites $status/$output: re-run the task before checking them again.
    run ! grep -qE '^(CREATE|ALTER|REVOKE|GRANT)' "${TEST_TMPDIR}/sql.log"
    run ! grep -q '^get secret ' "${TEST_TMPDIR}/kubectl.log"
  done
}

@test "blocked recreation never generates or encrypts a password" {
  export ACCOUNT_COUNT=1 PREEXISTING_GRANTS="GRANT app_role TO 'svc'@'%'"
  export REAL_PYTHON3
  REAL_PYTHON3="$(command -v python3)"
  cat > "${TEST_TMPDIR}/bin/python3" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == - ]]; then
  touch "${TEST_TMPDIR}/generator-called"
  exit 99
fi
exec "$REAL_PYTHON3" "$@"
STUB
  chmod +x "${TEST_TMPDIR}/bin/python3"
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --if-exists recreate --password-delivery-mode encrypted_payload --recipient-pgp-pubkey test-key
  [ "$status" -eq 1 ]
  [ "$(json_field '.reason_code')" = UNSUPPORTED_EXISTING_GRANTS ]
  [ "$(json_field '.delivery_payload')" = null ]
  [ ! -e "${TEST_TMPDIR}/generator-called" ]
  [ ! -e "${TEST_TMPDIR}/encrypted-input" ]
}

@test "unreadable or unrecognized existing grants fail before mutation" {
  export ACCOUNT_COUNT=1 SQL_FAIL_EXISTING_GRANTS=1
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --if-exists recreate
  [ "$status" -eq 2 ]
  [ "$(json_field '.reason_code')" = SQL_VERIFY_FAILED ]
  [ "$(json_field '.mutation_applied')" = false ]
  [ "$(json_field '.delivery_payload')" = null ]
  unset SQL_FAIL_EXISTING_GRANTS
  export PREEXISTING_GRANTS='unrecognized output'
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --if-exists recreate
  [ "$status" -eq 1 ]
  [ "$(json_field '.reason_code')" = UNSUPPORTED_EXISTING_GRANTS ]
  [ "$(json_field '.mutation_applied')" = false ]
  run ! grep -qE '^(CREATE|ALTER|REVOKE|GRANT)' "${TEST_TMPDIR}/sql.log"
}

@test "SHOW GRANTS verification accepts reordered profile privileges" {
  export MARIADB_ACCOUNT_RO_DATABASE_PRIVILEGES_DEFAULT=SELECT,INSERT
  export EXPECTED_PRIVILEGES='INSERT, SELECT'
  run "$SCRIPT" "${ACTUAL_ARGS[@]}"
  [ "$status" -eq 0 ]
  [ "$(json_field '.status')" = CREATED ]
}

@test "SHOW GRANTS must contain the effective requested grant" {
  export VERIFY_MISMATCH=1
  run "$SCRIPT" "${ACTUAL_ARGS[@]}"
  [ "$(json_field '.reason_code')" = SQL_VERIFY_FAILED ]
  [ "$(json_field '.mutation_applied')" = true ]
}

@test "grant failure reports an explicit partial mutation" {
  export SQL_FAIL_GRANT=1
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --password-secret-name svc-password
  [ "$(json_field '.reason_code')" = SQL_FAILED ]
  [ "$(json_field '.mutation_applied')" = true ]
  [[ "$(json_field '.summary')" == *'credential changed'* ]]
  [[ "$output" != *FixedServicePass123* ]]
}

@test "revoke failure after ALTER reports an explicit partial mutation" {
  export ACCOUNT_COUNT=1 SQL_FAIL_REVOKE=1
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --if-exists recreate --password-secret-name svc-password
  [ "$(json_field '.reason_code')" = SQL_FAILED ]
  [ "$(json_field '.mutation_applied')" = true ]
  [[ "$(json_field '.summary')" == *'revoking the prior grants failed'* ]]
  [ "$(json_field '.delivery_payload.mode')" = caller_provided_secret ]
  [ "$(json_field '.delivery_payload.secret_name')" = svc-password ]
  [[ "$output" != *FixedServicePass123* && "$output" != *root-pass* ]]
}

@test "post-mutation failures retain the applied plaintext credential in JSON and result file" {
  export ACCOUNT_COUNT=1
  for failure in SQL_FAIL_REVOKE SQL_FAIL_GRANT SQL_FAIL_VERIFY VERIFY_MISMATCH; do
    export "$failure=1"
    rm -f "${TEST_TMPDIR}/mutation-applied" "${TEST_TMPDIR}/sql.log"
    run "$SCRIPT" "${ACTUAL_ARGS[@]}" --if-exists recreate --result-file "${TEST_TMPDIR}/result.json"
    [ "$status" -eq 2 ]
    [ "$(json_field '.status')" = ERROR ]
    [ "$(json_field '.mutation_applied')" = true ]
    [ "$(json_field '.delivery_payload.mode')" = one_time_plaintext ]
    password="$(json_field '.delivery_payload.password')"
    [ "${#password}" -eq 24 ]
    grep -Fq "IDENTIFIED BY '$password'" "${TEST_TMPDIR}/sql.log"
    [ "$(jq -r '.delivery_payload.password' "${TEST_TMPDIR}/result.json")" = "$password" ]
    [[ "$output" != *root-pass* ]]
    unset "$failure"
  done
}

@test "post-mutation encrypted delivery stays encrypted on failure" {
  export ACCOUNT_COUNT=1 SQL_FAIL_GRANT=1
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --if-exists recreate --password-delivery-mode encrypted_payload --recipient-pgp-pubkey test-key
  [ "$status" -eq 2 ]
  [ "$(json_field '.mutation_applied')" = true ]
  [ "$(json_field '.delivery_payload.mode')" = encrypted_payload ]
  [ "$(json_field '.delivery_payload.password // empty')" = '' ]
  [[ "$(json_field '.delivery_payload.ciphertext')" == *'BEGIN PGP MESSAGE'* ]]
  password="$(cat "${TEST_TMPDIR}/encrypted-input")"
  [ "${#password}" -eq 24 ]
  grep -Fq "IDENTIFIED BY '$password'" "${TEST_TMPDIR}/sql.log"
  [[ "$output" != *"$password"* && "$output" != *root-pass* ]]
}

@test "unacknowledged account mutation preserves prepared delivery without claiming success" {
  export ACCOUNT_COUNT=1 SQL_FAIL_MUTATION=1
  for mode in one_time_plaintext encrypted_payload; do
    delivery_args=(--password-delivery-mode "$mode")
    [[ "$mode" != encrypted_payload ]] || delivery_args+=(--recipient-pgp-pubkey test-key)
    run "$SCRIPT" "${ACTUAL_ARGS[@]}" --if-exists recreate "${delivery_args[@]}"
    [ "$status" -eq 2 ]
    [ "$(json_field '.reason_code')" = ACCOUNT_MUTATION_FAILED ]
    [ "$(json_field '.mutation_applied')" = false ]
    [ "$(json_field '.delivery_payload.mode')" = "$mode" ]
    [[ "$(json_field '.summary')" == *'credential state may be uncertain'* ]]
    if [[ "$mode" == one_time_plaintext ]]; then
      password="$(json_field '.delivery_payload.password')"
      [ "${#password}" -eq 24 ]
      grep -Fq "IDENTIFIED BY '$password'" "${TEST_TMPDIR}/sql.log"
    else
      [ "$(json_field '.delivery_payload.password // empty')" = '' ]
      [[ "$output" != *"$(cat "${TEST_TMPDIR}/encrypted-input")"* ]]
    fi
  done
}

@test "SQL mutation failures are redacted" {
  export SQL_FAIL_MUTATION=1
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --password-secret-name svc-password
  [ "$(json_field '.reason_code')" = ACCOUNT_MUTATION_FAILED ]
  [[ "$output" != *FixedServicePass123* ]]
  [[ "$output" != *root-pass* ]]
}

@test "confirmed execution is required for mutations" {
  run "$SCRIPT" --namespace mariadb-1 --database app_db --username svc --dry-run false --json
  [ "$(json_field '.reason_code')" = CONFIRM_REQUIRED ]
  [ ! -e "${TEST_TMPDIR}/sql.log" ]
}

@test "existing account skips by default without generating or reading account credentials" {
  export ACCOUNT_COUNT=1
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --password-secret-name missing
  [ "$status" -eq 0 ]
  [ "$(json_field '.status')" = SKIPPED ]
  [ "$(json_field '.reason_code')" = ACCOUNT_EXISTS ]
  [ "$(json_field '.mutation_applied')" = false ]
  [ "$(json_field '.delivery_payload')" = null ]
  [ "$(json_field '.sql_plan | length')" -eq 0 ]
  run ! grep -qE '^(CREATE|ALTER|GRANT|REVOKE|SHOW PRIVILEGES)' "${TEST_TMPDIR}/sql.log"
  run ! grep -q '^get secret ' "${TEST_TMPDIR}/kubectl.log"
}

@test "none profile creates a login without any data grants" {
  export EXPECTED_GRANTS="GRANT USAGE ON *.* TO 'svc'@'%'"
  run "$SCRIPT" --namespace mariadb-1 --mdb mariadb --username svc --account-type none --dry-run false --confirm true --json
  [ "$status" -eq 0 ]
  [ "$(json_field '.status')" = CREATED ]
  [ "$(json_field '.privileges | join(",")')" = USAGE ]
  grep -q '^CREATE USER ' "${TEST_TMPDIR}/sql.log"
  run ! grep -q '^GRANT ' "${TEST_TMPDIR}/sql.log"
}

@test "monitor profile grants monitoring privileges at global scope" {
  export EXPECTED_GRANTS="GRANT SLAVE MONITOR, PROCESS, BINLOG MONITOR ON *.* TO 'svc'@'%'"
  run "$SCRIPT" --namespace mariadb-1 --mdb mariadb --username svc --account-type monitor --dry-run false --confirm true --json
  [ "$status" -eq 0 ]
  [ "$(json_field '.status')" = CREATED ]
  [ "$(json_field '.scope.kind')" = global ]
  grep -Fq "GRANT PROCESS, BINLOG MONITOR, SLAVE MONITOR ON *.*" "${TEST_TMPDIR}/sql.log"
}

@test "deployment can configure a zero-grant monitor or explicit USAGE" {
  export MARIADB_ACCOUNT_MONITOR_GLOBAL_PRIVILEGES_DEFAULT=''
  run "$SCRIPT" --namespace mariadb-1 --username svc --account-type monitor --json
  [ "$status" -eq 0 ]
  [ "$(json_field '.privileges | join(",")')" = USAGE ]
  export MARIADB_ACCOUNT_MONITOR_GLOBAL_PRIVILEGES_DEFAULT=USAGE
  run "$SCRIPT" --namespace mariadb-1 --username svc --account-type monitor --json
  [ "$status" -eq 0 ]
  [ "$(json_field '.scope.kind')" = none ]
}

@test "deployment global admin policy allows writes without a caller-selected wildcard" {
  export MARIADB_ACCOUNT_ADMIN_DATABASE_PRIVILEGES_DEFAULT=''
  export MARIADB_ACCOUNT_ADMIN_GLOBAL_PRIVILEGES_DEFAULT='SELECT,INSERT,UPDATE,DELETE,CREATE,DROP,CREATE USER,RELOAD,GRANT OPTION'
  export EXPECTED_GRANTS="GRANT DROP, CREATE USER, RELOAD, CREATE, DELETE, INSERT, SELECT, UPDATE ON *.* TO 'svc'@'%' WITH GRANT OPTION"
  run "$SCRIPT" --namespace mariadb-1 --mdb mariadb --username svc --account-type admin --dry-run false --confirm true --json
  [ "$status" -eq 0 ]
  [ "$(json_field '.status')" = CREATED ]
  grep -Fq "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, CREATE USER, RELOAD ON *.* TO 'svc'@'%' WITH GRANT OPTION;" "${TEST_TMPDIR}/sql.log"
}

@test "deployment policy accepts the native READ_ONLY ADMIN spelling" {
  export MARIADB_ACCOUNT_MONITOR_GLOBAL_PRIVILEGES_DEFAULT='READ_ONLY ADMIN'
  export EXPECTED_GRANTS="GRANT READ_ONLY ADMIN ON *.* TO 'svc'@'%'"
  run "$SCRIPT" --namespace mariadb-1 --mdb mariadb --username svc --account-type monitor --dry-run false --confirm true --json
  [ "$status" -eq 0 ]
  [ "$(json_field '.status')" = CREATED ]
  grep -Fq "GRANT READ_ONLY ADMIN ON *.* TO 'svc'@'%';" "${TEST_TMPDIR}/sql.log"
  export MARIADB_ACCOUNT_MONITOR_GLOBAL_PRIVILEGES_DEFAULT='READ ONLY ADMIN'
  run "$SCRIPT" --namespace mariadb-1 --username svc --account-type monitor --json
  [ "$status" -eq 2 ]
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
}

@test "database and global privileges are applied and verified separately" {
  export MARIADB_ACCOUNT_RO_GLOBAL_PRIVILEGES_DEFAULT=PROCESS
  EXPECTED_GRANTS="$(cat <<'GRANTS'
GRANT USAGE ON *.* TO 'svc'@'%'
GRANT SELECT ON `app\_db`.* TO 'svc'@'%'
GRANT PROCESS ON *.* TO 'svc'@'%'
GRANTS
)"
  export EXPECTED_GRANTS
  run "$SCRIPT" "${ACTUAL_ARGS[@]}"
  [ "$status" -eq 0 ]
  [ "$(json_field '.scope.kind')" = mixed ]
  [ "$(json_field '.grants | length')" -eq 2 ]
  grep -Fq 'GRANT SELECT ON `app\_db`.*' "${TEST_TMPDIR}/sql.log"
  grep -Fq 'GRANT PROCESS ON *.*' "${TEST_TMPDIR}/sql.log"
}

@test "unsupported server privileges fail before changing credentials" {
  export OMIT_PRIVILEGE=SELECT
  run "$SCRIPT" "${ACTUAL_ARGS[@]}"
  [ "$status" -eq 2 ]
  [ "$(json_field '.reason_code')" = UNSUPPORTED_PRIVILEGE ]
  [ "$(json_field '.mutation_applied')" = false ]
  [ "$(json_field '.delivery_payload')" = null ]
  run ! grep -qE '^(CREATE|ALTER|GRANT|REVOKE)' "${TEST_TMPDIR}/sql.log"
}

@test "unexpected broader grants and role membership are not accepted as success" {
  export EXPECTED_PRIVILEGES='SELECT, INSERT'
  run "$SCRIPT" "${ACTUAL_ARGS[@]}"
  [ "$status" -eq 2 ]
  [ "$(json_field '.reason_code')" = SQL_VERIFY_FAILED ]
  [ "$(json_field '.mutation_applied')" = true ]
  export EXPECTED_GRANTS="GRANT app_role TO 'svc'@'%'"
  run "$SCRIPT" "${ACTUAL_ARGS[@]}"
  [ "$status" -eq 2 ]
  [ "$(json_field '.reason_code')" = SQL_VERIFY_FAILED ]
}

@test "explicit Secret read policy permits only the configured key on protected credentials" {
  export MARIADB_ACCOUNT_PASSWORD_SECRET_REFS_DEFAULT=mariadb/monitor.password
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --password-secret-name mariadb --password-secret-key monitor.password
  [ "$status" -eq 0 ]
  [ "$(json_field '.status')" = CREATED ]
  [ "$(json_field '.delivery_payload.secret_key')" = monitor.password ]
  [[ "$output" != *FixedServicePass* && "$output" != *root-pass* ]]
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --password-secret-name mariadb --password-secret-key password
  [ "$status" -eq 2 ]
  [ "$(json_field '.reason_code')" = PROTECTED_SECRET ]
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --password-secret-name svc-password
  [ "$status" -eq 2 ]
  [ "$(json_field '.reason_code')" = PROTECTED_SECRET ]
}

@test "dry-run never invokes the generator, encryption, or Secret access" {
  cat > "${TEST_TMPDIR}/bin/python3" <<'STUB'
#!/usr/bin/env bash
echo generator-called >&2
exit 99
STUB
  chmod +x "${TEST_TMPDIR}/bin/python3"
  run "$SCRIPT" --namespace mariadb-1 --username svc --account-type none --json
  [ "$status" -eq 0 ]
  [ "$(json_field '.delivery_payload')" = null ]
  [ ! -e "${TEST_TMPDIR}/kubectl.log" ]
  run "$SCRIPT" --namespace mariadb-1 --username svc --account-type none --password-secret-name mariadb --json
  [ "$status" -eq 0 ]
  [ "$(json_field '.delivery_payload')" = null ]
  [ ! -e "${TEST_TMPDIR}/kubectl.log" ]
}

@test "failures always exit nonzero after publishing structured results" {
  run "$SCRIPT" --namespace mariadb-1 --username svc --account-type invalid --result-file "${TEST_TMPDIR}/result.json" --json
  [ "$status" -eq 2 ]
  [ "$(jq -r '.reason_code' "${TEST_TMPDIR}/result.json")" = INVALID_INPUT ]
  [ "$(json_field '.status')" = ERROR ]
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --confirm false
  [ "$status" -eq 1 ]
  [ "$(json_field '.reason_code')" = CONFIRM_REQUIRED ]
  export SQL_FAIL_MUTATION=1
  run "$SCRIPT" "${ACTUAL_ARGS[@]}"
  [ "$status" -eq 2 ]
  [ "$(json_field '.reason_code')" = ACCOUNT_MUTATION_FAILED ]
}

@test "legacy privilege and existing-account controls are rejected explicitly" {
  export ACCOUNT_PRIVILEGES=SELECT
  run "$SCRIPT" "${ACTUAL_ARGS[@]}"
  [ "$status" -eq 2 ]
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
  unset ACCOUNT_PRIVILEGES
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --privileges SELECT
  [ "$status" -eq 2 ]
  [[ "$output" == *'unknown option: --privileges'* ]]
  run "$SCRIPT" "${ACTUAL_ARGS[@]}" --if-exists invalid
  [ "$status" -eq 2 ]
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
}

@test "SHOW GRANTS verifier handles native canonicalization and rejects scope expansion" {
  run python3 -B -m unittest discover -s "${BATS_TEST_DIRNAME}" -p test_account_grants.py
  [ "$status" -eq 0 ]
}

@test "grant verification reads literal escaped database scopes in raw client mode" {
  run "$SCRIPT" "${ACTUAL_ARGS[@]}"
  [ "$status" -eq 0 ]
  [ "$(json_field '.status')" = CREATED ]
  [ "$(json_field '.grants[0].scope')" = '`app\_db`.*' ]
  grep -Fxq raw-show-grants "${TEST_TMPDIR}/client-flags.log"
}
