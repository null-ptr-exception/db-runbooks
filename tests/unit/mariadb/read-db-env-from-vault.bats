#!/usr/bin/env bats
#
# Contract tests for mariadb/migration/read-db-env-from-vault.sh.
#
# Locked-down behaviours:
#   - values read from Vault (KV-v2, AppRole auth) are materialized into a
#     Kubernetes Secret and NEVER appear anywhere in the task's own JSON
#     result, stdout, or result file
#   - Vault AppRole config is deploy-time only — there is no task-input override
#   - --keys entries may rename the destination Secret key: VAULT_KEY=secret_key
#   - omitting --keys imports every key at the vault path
#   - the Secret write is idempotent (jq-built manifest | apply)
#   - vault_path / secret_name are validated
#   - decrypted Vault values never appear as a kubectl argv element (only in
#     the base64 `data:` payload of the manifest piped via stdin)

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mariadb/migration/read-db-env-from-vault.sh"
  export _LOG_CURRENT_LEVEL=3
  mkdir -p "${TEST_TMPDIR}/bin"

  # Deploy-time Vault AppRole config (see aqsh-tasks/config/mariadb.env).
  export VAULT_ADDR="https://vault.example.test:8200"
  export VAULT_MOUNT="secret"
  export VAULT_ROLE_ID="test-role-id"
  export VAULT_SECRET_ID="test-secret-id"

  # Default Vault KV-v2 response for GET .../data/<path>.
  export MOCK_VAULT_KV_RESPONSE='{"data":{"data":{"root_password":"secret-root-pass","other_key":"other-val"}}}'

  CURL_LOG="${TEST_TMPDIR}/curl.log"
  export CURL_LOG
  SECRET_APPLY_CAPTURE="${TEST_TMPDIR}/secret-apply.yaml"
  export SECRET_APPLY_CAPTURE
  KUBECTL_LOG="${TEST_TMPDIR}/kubectl.log"
  export KUBECTL_LOG

  cat > "${TEST_TMPDIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ -n "${KUBECTL_LOG:-}" ]] && printf '%s\n' "$*" >> "${KUBECTL_LOG}"

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context|--namespace|--kubeconfig)
      shift 2
      ;;
    -n)
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

cmd="${args[0]:-}"

if [[ "$cmd" == "cluster-info" ]]; then
  echo "Kubernetes control plane is running"
  exit 0
fi

if [[ "$cmd" == "apply" ]]; then
  [[ "${MOCK_SECRET_APPLY_FAIL:-0}" == "1" ]] && { cat >/dev/null; echo "apply failed" >&2; exit 1; }
  if [[ -n "${SECRET_APPLY_CAPTURE:-}" ]]; then
    cat > "${SECRET_APPLY_CAPTURE}"
  else
    cat >/dev/null
  fi
  exit 0
fi

echo "unexpected kubectl invocation: ${args[*]}" >&2
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/kubectl"

  # --- curl mock (Vault HTTP API) ---------------------------------------------
  cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args=("$@")
[[ -n "${CURL_LOG:-}" ]] && printf '%s\n' "${args[*]}" >> "${CURL_LOG}"

url="${args[$(( ${#args[@]} - 1 ))]}"

case "$url" in
  */auth/approle/login)
    # Drain the piped request body first, like real curl does (it must read
    # the whole body to send Content-Length) — an early exit here races with
    # the writer and can SIGPIPE it under `pipefail`.
    cat > /dev/null
    [[ "${MOCK_VAULT_LOGIN_FAIL:-0}" == "1" ]] && exit 1
    echo '{"auth":{"client_token":"test-vault-token"}}'
    exit 0
    ;;
  */data/*)
    [[ "${MOCK_VAULT_READ_FAIL:-0}" == "1" ]] && exit 1
    echo "${MOCK_VAULT_KV_RESPONSE}"
    exit 0
    ;;
  */auth/token/revoke-self)
    exit 0
    ;;
  *)
    echo "unexpected curl invocation: ${args[*]}" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/bin/curl"
}

# ---------------------------------------------------------------------------
# Happy path: values reach the Secret, never the task result
# ---------------------------------------------------------------------------

@test "imports every key at the vault path when --keys is omitted" {
  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1/source \
    --secret-name migration-job-1-source-creds --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "OK" ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "ENV_IMPORTED_FROM_VAULT" ]
  [ "$(printf '%s' "$output" | jq -r '.secret.name')" = "migration-job-1-source-creds" ]
  written="$(printf '%s' "$output" | jq -c '.secret.keysWritten | sort')"
  [ "$written" = '["other_key","root_password"]' ]

  [ -f "${SECRET_APPLY_CAPTURE}" ]
  [ "$(jq -r '.data.root_password' "${SECRET_APPLY_CAPTURE}" | base64 -d)" = "secret-root-pass" ]
  [ "$(jq -r '.data.other_key' "${SECRET_APPLY_CAPTURE}" | base64 -d)" = "other-val" ]
}

@test "--keys selects a subset of vault keys" {
  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1/source \
    --secret-name migration-job-1-source-creds --keys root_password --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.secret.keysWritten')" = '["root_password"]' ]
  [ -f "${SECRET_APPLY_CAPTURE}" ]
  [ "$(jq '.data | has("root_password")' "${SECRET_APPLY_CAPTURE}")" = "true" ]
  [ "$(jq '.data | has("other_key")' "${SECRET_APPLY_CAPTURE}")" = "false" ]
}

@test "--keys entry with =secret_key stores under the renamed Secret key" {
  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1/source \
    --secret-name migration-job-1-source-creds \
    --keys "root_password=repl_password" --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.secret.keysWritten')" = '["repl_password"]' ]
  [ -f "${SECRET_APPLY_CAPTURE}" ]
  [ "$(jq -r '.data.repl_password' "${SECRET_APPLY_CAPTURE}" | base64 -d)" = "secret-root-pass" ]
  [ "$(jq '.data | has("root_password")' "${SECRET_APPLY_CAPTURE}")" = "false" ]
}

@test "a requested-but-missing key is reported missing, not written" {
  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1/source \
    --secret-name migration-job-1-source-creds \
    --keys "root_password,does_not_exist" --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.secret.keysWritten')" = '["root_password"]' ]
  [ "$(printf '%s' "$output" | jq -c '.secret.keysMissing')" = '["does_not_exist"]' ]
}

@test "reports NO_KEYS_FOUND and writes no secret when all requested keys are missing" {
  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1/source \
    --secret-name migration-job-1-source-creds --keys does_not_exist --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "NO_KEYS_FOUND" ]
  [ "$(printf '%s' "$output" | jq -r '.secret.name')" = "null" ]
  [ ! -f "${SECRET_APPLY_CAPTURE}" ]
}

@test "reports VAULT_PATH_EMPTY when the vault entry has no keys" {
  export MOCK_VAULT_KV_RESPONSE='{"data":{"data":{}}}'

  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1/source \
    --secret-name migration-job-1-source-creds --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "VAULT_PATH_EMPTY" ]
  [ "$(printf '%s' "$output" | jq -r '.secret')" = "null" ]
  [ ! -f "${SECRET_APPLY_CAPTURE}" ]
}

# ---------------------------------------------------------------------------
# Credential safety: the whole point of this task
# ---------------------------------------------------------------------------

@test "the result never exposes the actual value, on success" {
  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1/source \
    --secret-name migration-job-1-source-creds --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"secret-root-pass"* ]]
}

@test "the result never exposes the actual value, written to a result file" {
  local result_file="${TEST_TMPDIR}/result.json"
  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1/source \
    --secret-name migration-job-1-source-creds --result-file "$result_file"
  [ "$status" -eq 0 ]
  run grep "secret-root-pass" "$result_file"
  [ "$status" -ne 0 ]
}

@test "the raw vault value never appears as a kubectl argv element" {
  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1/source \
    --secret-name migration-job-1-source-creds --json
  [ "$status" -eq 0 ]
  [ -f "${KUBECTL_LOG}" ]
  run grep -F "secret-root-pass" "${KUBECTL_LOG}"
  [ "$status" -ne 0 ]
}

@test "no result ever includes a 'data' or 'vars' field with raw values" {
  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1/source \
    --secret-name migration-job-1-source-creds --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'has("data")')" = "false" ]
  [ "$(printf '%s' "$output" | jq 'has("vars")')" = "false" ]
}

# ---------------------------------------------------------------------------
# vault_path / secret_name / namespace validation
# ---------------------------------------------------------------------------

@test "exits 2 when --namespace is missing" {
  run "${SCRIPT}" --vault-path migration/job-1 --secret-name creds --json
  [ "$status" -eq 2 ]
}

@test "exits 2 when --vault-path is missing" {
  run "${SCRIPT}" --namespace db-1 --secret-name creds --json
  [ "$status" -eq 2 ]
}

@test "exits 2 when --vault-path is absolute" {
  run "${SCRIPT}" --namespace db-1 --vault-path /migration/job-1 --secret-name creds --json
  [ "$status" -eq 2 ]
}

@test "exits 2 when --vault-path contains '..'" {
  run "${SCRIPT}" --namespace db-1 --vault-path "migration/../secret" --secret-name creds --json
  [ "$status" -eq 2 ]
}

@test "exits 2 when --secret-name is missing" {
  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1 --json
  [ "$status" -eq 2 ]
}

@test "exits 2 when --secret-name is not a valid k8s object name" {
  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1 --secret-name "Bad_Name!" --json
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Vault AppRole failures
# ---------------------------------------------------------------------------

@test "fails with VAULT_NOT_CONFIGURED when Vault AppRole is not set up" {
  unset VAULT_ROLE_ID VAULT_SECRET_ID
  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1/source \
    --secret-name migration-job-1-source-creds --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "VAULT_NOT_CONFIGURED" ]
  [ "$(printf '%s' "$output" | jq -r '.secret')" = "null" ]
  [ ! -f "${CURL_LOG}" ]
}

@test "fails with VAULT_LOGIN_FAILED when AppRole login fails" {
  export MOCK_VAULT_LOGIN_FAIL=1
  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1/source \
    --secret-name migration-job-1-source-creds --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "VAULT_LOGIN_FAILED" ]
}

@test "fails with VAULT_READ_FAILED when the KV read fails" {
  export MOCK_VAULT_READ_FAIL=1
  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1/source \
    --secret-name migration-job-1-source-creds --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "VAULT_READ_FAILED" ]
}

# ---------------------------------------------------------------------------
# Secret write failures
# ---------------------------------------------------------------------------

@test "fails with SECRET_WRITE_FAILED when kubectl apply fails" {
  export MOCK_SECRET_APPLY_FAIL=1
  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1/source \
    --secret-name migration-job-1-source-creds --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "SECRET_WRITE_FAILED" ]
  [[ "$output" != *"secret-root-pass"* ]]
}

# ---------------------------------------------------------------------------
# Idempotency: re-running updates the Secret rather than colliding
# ---------------------------------------------------------------------------

@test "re-running against an existing secret name succeeds (apply, not create-only)" {
  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1/source \
    --secret-name migration-job-1-source-creds --json
  [ "$status" -eq 0 ]

  run "${SCRIPT}" --namespace db-1 --vault-path migration/job-1/source \
    --secret-name migration-job-1-source-creds --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "OK" ]
}
