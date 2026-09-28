#!/usr/bin/env bats
# =============================================================================
# Unit tests for account/create-account.sh's caller-provided Secret path
# (password_secret_name). The e2e twin is tests/mongodb/account_lifecycle.bats;
# this checks the same no-plaintext-in-result guarantee without a cluster.
#
# Mocks (PATH stubs, logged to $TEST_TMPDIR):
#   kubectl  — `get secret` for the root and caller Secrets; everything else
#              fails, so an unexpected call shows up as a task error
#   mongosh  — isMaster (standalone), ping, getUser, createUser, policy upsert
# =============================================================================

FIXED_PASSWORD='FixedServicePass123!'

setup() {
  export TEST_TMPDIR="$BATS_TEST_TMPDIR"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mongodb/account/create-account.sh"
  export _LOG_CURRENT_LEVEL=4
  export SECRETS_AUTODETECT_DEFAULT=false
  export SECRETS_PROTECTED_NAMES_DEFAULT=mongodb-credentials
  export FIXED_PASSWORD
  export DB_NAMESPACE=mongo-1 ACCOUNT_USERNAME=svc DRY_RUN=false CONFIRM=true
  mkdir -p "${TEST_TMPDIR}/bin"

  cat > "${TEST_TMPDIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context|--namespace|-n|--kubeconfig) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
printf '%s\n' "${args[*]}" >> "${TEST_TMPDIR}/kubectl.log"
if [[ "${args[0]:-} ${args[1]:-}" == "get secret" ]]; then
  case "${args[2]:-} ${args[*]:3}" in
    "mongodb-credentials "*MONGO_ROOT_USER*) printf 'root' | base64; exit 0 ;;
    "mongodb-credentials "*MONGO_ROOT_PASS*) printf 'root-pass' | base64; exit 0 ;;
    "svc-password -o jsonpath={.data.password}") printf '%s' "$FIXED_PASSWORD" | base64; exit 0 ;;
  esac
fi
exit 1
EOF

  cat > "${TEST_TMPDIR}/bin/mongosh" <<'EOF'
#!/usr/bin/env bash
js=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == --eval ]] && { js="$2"; shift; }
  shift
done
printf '%s\n' "$js" >> "${TEST_TMPDIR}/mongosh.log"
case "$js" in
  *isMaster*) printf '{"ismaster":true}\n' ;;
  *ping*) printf '{ ok: 1 }\n' ;;
  *getUser\(*)
    if [[ -e "${TEST_TMPDIR}/user-created" ]]; then
      printf '{"user":"svc","credentials":{"SCRAM-SHA-256":{"storedKey":"k"}}}\n'
    else
      printf 'null\n'
    fi
    ;;
  *createUser\(*|*updateUser\(*) touch "${TEST_TMPDIR}/user-created"; printf '{"ok":1}\n' ;;
  *updateOne\(*) printf '{"ok":1}\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/bin/kubectl" "${TEST_TMPDIR}/bin/mongosh"
}

json_field() { printf '%s' "$output" | jq -r "$1"; }

@test "caller-provided Secret: password is used but never returned" {
  run env PASSWORD_SECRET_NAME=svc-password "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(json_field '.status')" = CREATED ]
  [ "$(json_field '.delivery_payload.mode')" = caller_provided_secret ]
  [ "$(json_field '.delivery_payload.secret_name')" = svc-password ]
  [ "$(json_field '.delivery_payload.secret_key')" = password ]
  [ "$(json_field '.delivery_payload | keys | join(",")')" = mode,secret_key,secret_name ]
  [[ "$output" != *"$FIXED_PASSWORD"* ]]
  [[ "$output" != *root-pass* ]]
  # The Secret's value, not a generated one, reached createUser.
  grep -Fq "pwd:'${FIXED_PASSWORD}'" "${TEST_TMPDIR}/mongosh.log"
  grep -Fq "password_delivery_mode\":\"caller_provided_secret\"" "${TEST_TMPDIR}/mongosh.log"
}

@test "caller-provided Secret combined with a plaintext-emitting delivery option is rejected before any lookup" {
  run env PASSWORD_SECRET_NAME=svc-password PASSWORD_DELIVERY_MODE=encrypted_payload RECIPIENT_PGP_PUBKEY=key "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
  run env PASSWORD_SECRET_NAME=svc-password RECIPIENT_PGP_PUBKEY=key "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(json_field '.reason_code')" = INVALID_INPUT ]
  [ ! -e "${TEST_TMPDIR}/kubectl.log" ]
  [ ! -e "${TEST_TMPDIR}/mongosh.log" ]
}

@test "protected or missing caller Secrets fail without exposing credentials" {
  run env PASSWORD_SECRET_NAME=mongodb-credentials PASSWORD_SECRET_KEY=MONGO_ROOT_PASS "$SCRIPT"
  [ "$(json_field '.reason_code')" = PROTECTED_SECRET ]
  [[ "$output" != *root-pass* ]]
  run env PASSWORD_SECRET_NAME=missing "$SCRIPT"
  [ "$(json_field '.reason_code')" = PASSWORD_SECRET_UNAVAILABLE ]
  [ ! -e "${TEST_TMPDIR}/user-created" ]
}
