#!/usr/bin/env bats
#
# Contract tests for mariadb/migration/write-db-env-to-vault.sh.
#
# Locked-down behaviours:
#   - fetched values are written to Vault (KV-v2, AppRole auth) and NEVER
#     appear anywhere in the task's own JSON result, stdout, or result file
#   - Vault AppRole (VAULT_ROLE_ID/VAULT_SECRET_ID/VAULT_ADDR/VAULT_MOUNT) is
#     deploy-time config only — there is no task-input override
#   - --mdb is required — this task never auto-detects a target
#   - --envs entries may rename the Vault key: VAR=vault_key
#   - vault_path is validated (no leading '/', no '..')
#   - a var that exists but lookup fails is "missing"; nothing is written to
#     Vault at all when zero requested vars are found

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mariadb/migration/write-db-env-to-vault.sh"
  export _LOG_CURRENT_LEVEL=3
  unset MARIADB_NAME MARIADB_STS_NAME || true
  mkdir -p "${TEST_TMPDIR}/bin"

  # Default mock values for env vars fetched via printenv.
  export MOCK_ENV_MARIADB_ROOT_PASSWORD="secret-root-pass"
  export MOCK_ENV_MARIADB_DATABASE="mydb"

  # Deploy-time Vault AppRole config (see aqsh-tasks/config/mariadb.env).
  export VAULT_ADDR="https://vault.example.test:8200"
  export VAULT_MOUNT="secret"
  export VAULT_ROLE_ID="test-role-id"
  export VAULT_SECRET_ID="test-secret-id"

  CURL_LOG="${TEST_TMPDIR}/curl.log"
  export CURL_LOG
  VAULT_WRITE_CAPTURE="${TEST_TMPDIR}/vault-write.json"
  export VAULT_WRITE_CAPTURE
  POD_LOOKUP_LOG="${TEST_TMPDIR}/pod-lookup.log"
  export POD_LOOKUP_LOG

  cat > "${TEST_TMPDIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

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

if [[ "$cmd" == "get" ]]; then
  resource="${args[1]:-}"
  name="${args[2]:-}"
  output="${args[*]}"

  if [[ "$resource" == "mariadb" && -n "$name" && "$name" != "-o" ]]; then
    cat <<'JSON'
{"spec":{"replicas":1},"status":{"currentPrimary":"mariadb-0","currentPrimaryPodIndex":0,"conditions":[{"type":"Ready","status":"True"}]}}
JSON
    exit 0
  fi

  if [[ "$resource" == "statefulset" && -n "$name" && "$name" != "-o" ]]; then
    cat <<'JSON'
{"spec":{"replicas":1,"updateStrategy":{"type":"RollingUpdate"}},"status":{"readyReplicas":1,"observedGeneration":1}}
JSON
    exit 0
  fi

  if [[ "$resource" == "secret" ]]; then
    case "$output" in
      *'.data.'*)
        key="${output##*data.}"
        key="${key%\}}"
        mock_var="MOCK_SECRET_KEY_${key}"
        [[ -n "${!mock_var+x}" ]] && printf '%s' "${!mock_var}"
        exit 0
        ;;
    esac
  fi
fi

if [[ "$cmd" == "exec" ]]; then
  shift_index=0
  for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "--" ]]; then
      shift_index=$((i + 1))
      break
    fi
  done
  command=("${args[@]:$shift_index}")

  if [[ "${command[0]:-}" == "printenv" && "${#command[@]}" -gt 1 ]]; then
    var_name="${command[1]}"
    [[ -n "${POD_LOOKUP_LOG:-}" ]] && printf '%s\n' "$var_name" >> "${POD_LOOKUP_LOG}"
    mock_key="MOCK_ENV_${var_name}"
    # Exit 1 (unset) when the MOCK_ENV_<VAR> shell variable is not exported.
    if [[ -z "${!mock_key+x}" ]]; then
      exit 1
    fi
    printf '%s' "${!mock_key}"
    exit 0
  fi
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
    [[ "${MOCK_VAULT_WRITE_FAIL:-0}" == "1" ]] && exit 1
    # Body now arrives via --data-binary @- (stdin), not a --data argv value.
    if [[ -n "${VAULT_WRITE_CAPTURE:-}" ]]; then
      cat > "${VAULT_WRITE_CAPTURE}"
    else
      cat > /dev/null
    fi
    echo '{}'
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
# Happy path: values reach Vault, never the task result
# ---------------------------------------------------------------------------

@test "writes a single env var to vault and reports it as written" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs MARIADB_ROOT_PASSWORD --vault-path migration/job-1/source --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "OK" ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "ENV_EXPORTED_TO_VAULT" ]
  [ "$(printf '%s' "$output" | jq -r '.vault.path')" = "migration/job-1/source" ]
  [ "$(printf '%s' "$output" | jq -c '.vault.keysWritten')" = '["MARIADB_ROOT_PASSWORD"]' ]
  [ "$(printf '%s' "$output" | jq -c '.vault.keysMissing')" = '[]' ]
}

@test "writes multiple env vars, all listed in keysWritten" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs MARIADB_ROOT_PASSWORD,MARIADB_DATABASE --vault-path migration/job-1/source --json

  [ "$status" -eq 0 ]
  written="$(printf '%s' "$output" | jq -c '.vault.keysWritten | sort')"
  [ "$written" = '["MARIADB_DATABASE","MARIADB_ROOT_PASSWORD"]' ]
}

@test "a requested-but-unset var is reported missing, not written" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs MARIADB_ROOT_PASSWORD,DOES_NOT_EXIST --vault-path migration/job-1/source --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.vault.keysWritten')" = '["MARIADB_ROOT_PASSWORD"]' ]
  [ "$(printf '%s' "$output" | jq -c '.vault.keysMissing')" = '["DOES_NOT_EXIST"]' ]
}

@test "an invalid env var name is reported missing without a pod lookup" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs "1BAD_NAME" --vault-path migration/job-1/source --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.vault.keysMissing')" = '["1BAD_NAME"]' ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "NO_VARS_FOUND" ]
  # Proves the pod lookup itself was skipped, not merely attempted-and-failed
  # (the mock's printenv handler would exit 1 for any unset MOCK_ENV_<VAR>,
  # which would look identical from the outcome alone).
  [ ! -f "${POD_LOOKUP_LOG}" ]
}

@test "the vault write payload contains exactly the values that were found" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs MARIADB_ROOT_PASSWORD,MARIADB_DATABASE --vault-path migration/job-1/source --json

  [ "$status" -eq 0 ]
  [ -f "${VAULT_WRITE_CAPTURE}" ]
  payload="$(cat "${VAULT_WRITE_CAPTURE}")"
  [ "$(jq -r '.data.MARIADB_ROOT_PASSWORD' <<<"$payload")" = "secret-root-pass" ]
  [ "$(jq -r '.data.MARIADB_DATABASE' <<<"$payload")" = "mydb" ]
}

# ---------------------------------------------------------------------------
# Vault key renaming: VAR=vault_key
# ---------------------------------------------------------------------------

@test "an envs entry with =vault_key stores under the renamed key" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs "MARIADB_ROOT_PASSWORD=root_password" --vault-path migration/job-1/source --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.vault.keysWritten')" = '["root_password"]' ]
  [ -f "${VAULT_WRITE_CAPTURE}" ]
  payload="$(cat "${VAULT_WRITE_CAPTURE}")"
  [ "$(jq -r '.data.root_password' <<<"$payload")" = "secret-root-pass" ]
  [ "$(jq 'has("MARIADB_ROOT_PASSWORD")' <<<"$(jq '.data' <<<"$payload")")" = "false" ]
}

@test "mixed renamed and unrenamed envs entries in one call" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs "MARIADB_ROOT_PASSWORD=root_password,MARIADB_DATABASE" \
    --vault-path migration/job-1/source --json

  [ "$status" -eq 0 ]
  written="$(printf '%s' "$output" | jq -c '.vault.keysWritten | sort')"
  [ "$written" = '["MARIADB_DATABASE","root_password"]' ]
}

@test "a missing var with a rename is still reported missing by its env var name" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs "DOES_NOT_EXIST=some_key" --vault-path migration/job-1/source --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.vault.keysMissing')" = '["DOES_NOT_EXIST"]' ]
}

# ---------------------------------------------------------------------------
# Secret-source mode
# ---------------------------------------------------------------------------

@test "reads a key from --secret-keys without requiring --mdb" {
  export MOCK_SECRET_KEY_password="bXktcmVwbC1wYXNz" # "my-repl-pass"

  run "${SCRIPT}" --namespace db-1 --secret-name mariadb-account-repl-user \
    --secret-keys password --vault-path migration/job-1/source --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "OK" ]
  [ "$(printf '%s' "$output" | jq -c '.vault.keysWritten')" = '["password"]' ]
  [[ "$output" != *"my-repl-pass"* ]]
}

@test "--secret-keys entry with =vault_key stores under the renamed key" {
  export MOCK_SECRET_KEY_password="bXktcmVwbC1wYXNz" # "my-repl-pass"

  run "${SCRIPT}" --namespace db-1 --secret-name mariadb-account-repl-user \
    --secret-keys "password=repl_password" --vault-path migration/job-1/source --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.vault.keysWritten')" = '["repl_password"]' ]
}

@test "a requested-but-missing secret key is reported missing, not written" {
  run "${SCRIPT}" --namespace db-1 --secret-name mariadb-account-repl-user \
    --secret-keys does_not_exist --vault-path migration/job-1/source --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "NO_VARS_FOUND" ]
  [ "$(printf '%s' "$output" | jq -c '.vault.keysMissing')" = '["does_not_exist"]' ]
}

@test "combines --envs (pod) and --secret-keys (Secret) into one vault write" {
  export MOCK_ENV_MARIADB_ROOT_PASSWORD="secret-root-pass"
  export MOCK_SECRET_KEY_password="bXktcmVwbC1wYXNz" # "my-repl-pass"

  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs "MARIADB_ROOT_PASSWORD=root_password" \
    --secret-name mariadb-account-repl-user --secret-keys "password=repl_password" \
    --vault-path migration/job-1/source --json

  [ "$status" -eq 0 ]
  written="$(printf '%s' "$output" | jq -c '.vault.keysWritten | sort')"
  [ "$written" = '["repl_password","root_password"]' ]
  [ -f "${VAULT_WRITE_CAPTURE}" ]
  payload="$(cat "${VAULT_WRITE_CAPTURE}")"
  [ "$(jq -r '.data.root_password' <<<"$payload")" = "secret-root-pass" ]
  [ "$(jq -r '.data.repl_password' <<<"$payload")" = "my-repl-pass" ]
}

# ---------------------------------------------------------------------------
# Credential safety: the whole point of this task
# ---------------------------------------------------------------------------

@test "the result never exposes the actual value, on success" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs MARIADB_ROOT_PASSWORD --vault-path migration/job-1/source --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"secret-root-pass"* ]]
}

@test "the result never exposes the actual value, written to a result file" {
  local result_file="${TEST_TMPDIR}/result.json"
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs MARIADB_ROOT_PASSWORD --vault-path migration/job-1/source \
    --result-file "$result_file"
  [ "$status" -eq 0 ]
  run grep "secret-root-pass" "$result_file"
  [ "$status" -ne 0 ]
}

@test "no result ever includes a 'vars' field with raw values" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs MARIADB_ROOT_PASSWORD --vault-path migration/job-1/source --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'has("vars")')" = "false" ]
}

@test "VAULT_SECRET_ID, the client token, and the relayed value never appear in curl argv" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs MARIADB_ROOT_PASSWORD --vault-path migration/job-1/source --json
  [ "$status" -eq 0 ]
  [ -f "${CURL_LOG}" ]
  # role_id/secret_id go to jq over env vars and the login body over stdin;
  # the token goes in a --config file, never --header on the command line.
  run grep -F "${VAULT_SECRET_ID}" "${CURL_LOG}"
  [ "$status" -ne 0 ]
  run grep -F "test-vault-token" "${CURL_LOG}"
  [ "$status" -ne 0 ]
  run grep -F "secret-root-pass" "${CURL_LOG}"
  [ "$status" -ne 0 ]
  run grep -F -- "--header" "${CURL_LOG}"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# vault_path validation
# ---------------------------------------------------------------------------

@test "exits 2 when --vault-path is missing" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --envs MARIADB_ROOT_PASSWORD --json
  [ "$status" -eq 2 ]
}

@test "exits 2 when --vault-path is absolute" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --envs MARIADB_ROOT_PASSWORD \
    --vault-path /migration/job-1 --json
  [ "$status" -eq 2 ]
}

@test "exits 2 when --vault-path contains '..'" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --envs MARIADB_ROOT_PASSWORD \
    --vault-path "migration/../secret" --json
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Vault AppRole failures
# ---------------------------------------------------------------------------

@test "fails with VAULT_NOT_CONFIGURED when Vault AppRole is not set up" {
  unset VAULT_ROLE_ID VAULT_SECRET_ID
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --envs MARIADB_ROOT_PASSWORD \
    --vault-path migration/job-1/source --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "VAULT_NOT_CONFIGURED" ]
  [ "$(printf '%s' "$output" | jq -r '.vault')" = "null" ]
  [ ! -f "${CURL_LOG}" ]
}

@test "fails with VAULT_LOGIN_FAILED when AppRole login fails" {
  export MOCK_VAULT_LOGIN_FAIL=1
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --envs MARIADB_ROOT_PASSWORD \
    --vault-path migration/job-1/source --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "VAULT_LOGIN_FAILED" ]
}

@test "fails with VAULT_WRITE_FAILED when the KV write fails" {
  export MOCK_VAULT_WRITE_FAIL=1
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --envs MARIADB_ROOT_PASSWORD \
    --vault-path migration/job-1/source --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "VAULT_WRITE_FAILED" ]
}

@test "does not call vault at all when no requested vars are found" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --envs DOES_NOT_EXIST \
    --vault-path migration/job-1/source --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "NO_VARS_FOUND" ]
  [ ! -f "${CURL_LOG}" ]
}

# ---------------------------------------------------------------------------
# Target resolution
# ---------------------------------------------------------------------------

@test "target pod is included in the result" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs MARIADB_ROOT_PASSWORD --vault-path migration/job-1/source --json

  [ "$status" -eq 0 ]
  pod=$(printf '%s' "$output" | jq -r '.target.pod')
  [ "$pod" = "mariadb-0" ]
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "exits 2 when --namespace is missing" {
  run "${SCRIPT}" --mdb mariadb --envs MARIADB_ROOT_PASSWORD \
    --vault-path migration/job-1/source --json
  [ "$status" -eq 2 ]
}

@test "exits 2 when --mdb is missing" {
  run "${SCRIPT}" --namespace db-1 --envs MARIADB_ROOT_PASSWORD \
    --vault-path migration/job-1/source --json
  [ "$status" -eq 2 ]
}

@test "exits 2 when neither --envs nor --secret-keys is given" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --vault-path migration/job-1/source --json
  [ "$status" -eq 2 ]
}

@test "exits 2 when --secret-keys is given without --secret-name" {
  run "${SCRIPT}" --namespace db-1 --secret-keys password \
    --vault-path migration/job-1/source --json
  [ "$status" -eq 2 ]
}
