#!/usr/bin/env bats
# =============================================================================
# Unit tests for _mongo_load_credentials in mongodb-recovery.sh.
#
# Tests the credential loading logic, specifically:
#   - Normal path: both user and password read from secret via key names
#   - direct_user path: username provided directly, only password from secret
#   - Error cases: missing secret, empty values
#
# Mock control env vars:
#   MOCK_SECRET_USER   — base64-encoded value returned for the user key
#   MOCK_SECRET_PASS   — base64-encoded value returned for the pass key
#   MOCK_SECRET_MISS   — if "1", kubectl get secret exits 1 (secret absent)
# =============================================================================

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export K8S_NAMESPACE="mongo-1"
  export _LOG_CURRENT_LEVEL=3
  LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export LIB_DIR

  export MOCK_SECRET_USER
  export MOCK_SECRET_PASS
  MOCK_SECRET_USER=$(printf 'testuser' | base64)
  MOCK_SECRET_PASS=$(printf 'testpass' | base64)
  export MOCK_SECRET_MISS=0
  export AQSH_RESULT_FILE="${TEST_TMPDIR}/result.json"

  mkdir -p "${TEST_TMPDIR}/bin"

  # jq stub: delegate to the real jq so error JSON matches the actual expression
  # (the stub used to hand-build JSON from --arg names, producing wrong field names
  # like "ns" instead of "namespace"). Fall back to a minimal stub only if jq is absent.
  cat > "${TEST_TMPDIR}/bin/jq" << 'JQ_EOF'
#!/usr/bin/env bash
# Delegate to the real jq binary (search system paths, bypassing this stub).
for _jq in /usr/bin/jq /usr/local/bin/jq /opt/homebrew/bin/jq; do
  [[ -x "$_jq" ]] && exec "$_jq" "$@"
done
# Fallback: handle jq -n --arg key val [--arg ...] 'expr' with flat key-value output.
args=()
declare -A jq_vars
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) shift ;;
    --arg) jq_vars["$2"]="$3"; shift 3 ;;
    *) args+=("$1"); shift ;;
  esac
done
out="{"
sep=""
for k in "${!jq_vars[@]}"; do
  out+="${sep}\"${k}\":\"${jq_vars[$k]}\""
  sep=","
done
out+="}"
printf '%s\n' "$out"
JQ_EOF
  chmod +x "${TEST_TMPDIR}/bin/jq"

  cat > "${TEST_TMPDIR}/bin/kubectl" << 'KUBECTL_EOF'
#!/usr/bin/env bash
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context|--namespace|-n|--kubeconfig) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
cmd="${args[0]:-}"
sub="${args[1]:-}"
flags="${args[*]:-}"

if [[ "$cmd" == "get" && "$sub" == "secret" ]]; then
  [[ "${MOCK_SECRET_MISS:-0}" == "1" ]] && exit 1
  # The lib calls: kubectl ... get secret <name> -o jsonpath="{.data.<KEY>}"
  # Match the key name embedded in the jsonpath expression.
  if [[ "$flags" == *"PASS"* ]]; then
    printf '%s' "${MOCK_SECRET_PASS}"
  else
    printf '%s' "${MOCK_SECRET_USER}"
  fi
  exit 0
fi
exit 0
KUBECTL_EOF
  chmod +x "${TEST_TMPDIR}/bin/kubectl"

  # shellcheck source=/dev/null
  source "${LIB_DIR}/logging.sh"
  source "${LIB_DIR}/response.sh"
  source "${LIB_DIR}/k8s.sh"
  source "${LIB_DIR}/mongodb.sh"
  source "${LIB_DIR}/mongodb-recovery.sh"
}

# ---------------------------------------------------------------------------
# Helpers: run _mongo_load_credentials in a subshell so exit 1 doesn't kill
# the test process; capture result file output on failure.
# ---------------------------------------------------------------------------
_run_load() {
  # args: namespace secret user_key pass_key [direct_user]
  (
    _MONGO_USER=""
    _MONGO_PASS=""
    _mongo_load_credentials "$@"
    printf 'USER=%s PASS=%s' "$_MONGO_USER" "$_MONGO_PASS"
  )
}

# ---------------------------------------------------------------------------
# Normal path: both user and password from secret
# ---------------------------------------------------------------------------

@test "loads username and password from secret keys (normal path)" {
  out=$(_run_load "mongo-1" "mongodb-credentials" "MONGO_ROOT_USER" "MONGO_ROOT_PASS")
  [[ "$out" == *"USER=testuser"* ]]
  [[ "$out" == *"PASS=testpass"* ]]
}

@test "uses custom user_key and pass_key when provided" {
  MOCK_SECRET_USER=$(printf 'adminuser' | base64)
  MOCK_SECRET_PASS=$(printf 'adminpass' | base64)
  out=$(_run_load "mongo-1" "mongodb-credentials" "ADMIN_USER" "ADMIN_PASS")
  [[ "$out" == *"USER=adminuser"* ]]
  [[ "$out" == *"PASS=adminpass"* ]]
}

# ---------------------------------------------------------------------------
# direct_user path: username provided directly, password still from secret
# ---------------------------------------------------------------------------

@test "direct_user bypasses user key lookup — username comes from argument" {
  out=$(_run_load "mongo-1" "mongodb-credentials" "MONGO_ROOT_USER" "MONGO_ROOT_PASS" "root")
  [[ "$out" == *"USER=root"* ]]
  [[ "$out" == *"PASS=testpass"* ]]
}

@test "direct_user works with a custom account name (elsh)" {
  out=$(_run_load "mongo-1" "mongodb-credentials" "MONGO_ROOT_USER" "MONGO_ROOT_PASS" "elsh")
  [[ "$out" == *"USER=elsh"* ]]
  [[ "$out" == *"PASS=testpass"* ]]
}

@test "direct_user still reads password from secret" {
  MOCK_SECRET_PASS=$(printf 'secret-from-vault' | base64)
  out=$(_run_load "mongo-1" "mongodb-credentials" "MONGO_ROOT_USER" "MONGO_ROOT_PASS" "root")
  [[ "$out" == *"PASS=secret-from-vault"* ]]
}

@test "direct_user='' (empty string) falls back to reading user from secret" {
  out=$(_run_load "mongo-1" "mongodb-credentials" "MONGO_ROOT_USER" "MONGO_ROOT_PASS" "")
  [[ "$out" == *"USER=testuser"* ]]
}

# ---------------------------------------------------------------------------
# Error: secret missing
# ---------------------------------------------------------------------------

@test "fails with JSON error when secret does not exist (normal path)" {
  export MOCK_SECRET_MISS=1
  out=$(_run_load "mongo-1" "mongodb-credentials" "MONGO_ROOT_USER" "MONGO_ROOT_PASS") || true
  # On failure the subshell exits 1 and writes to AQSH_RESULT_FILE
  [[ -f "$AQSH_RESULT_FILE" ]]
  cat "$AQSH_RESULT_FILE" | grep -q '"status":"error"'
}

@test "fails with JSON error when secret does not exist even with direct_user" {
  export MOCK_SECRET_MISS=1
  out=$(_run_load "mongo-1" "mongodb-credentials" "MONGO_ROOT_USER" "MONGO_ROOT_PASS" "root") || true
  [[ -f "$AQSH_RESULT_FILE" ]]
  cat "$AQSH_RESULT_FILE" | grep -q '"status":"error"'
}

# ---------------------------------------------------------------------------
# Error: empty values
# ---------------------------------------------------------------------------

@test "fails when secret user key decodes to empty string" {
  MOCK_SECRET_USER=$(printf '' | base64)
  out=$(_run_load "mongo-1" "mongodb-credentials" "MONGO_ROOT_USER" "MONGO_ROOT_PASS") || true
  [[ -f "$AQSH_RESULT_FILE" ]]
  cat "$AQSH_RESULT_FILE" | grep -q '"status":"error"'
  cat "$AQSH_RESULT_FILE" | grep -q 'missing required key'
}

@test "fails when secret pass key decodes to empty string" {
  MOCK_SECRET_PASS=$(printf '' | base64)
  out=$(_run_load "mongo-1" "mongodb-credentials" "MONGO_ROOT_USER" "MONGO_ROOT_PASS") || true
  [[ -f "$AQSH_RESULT_FILE" ]]
  cat "$AQSH_RESULT_FILE" | grep -q '"status":"error"'
}

@test "fails when direct_user given but password key decodes to empty string" {
  MOCK_SECRET_PASS=$(printf '' | base64)
  out=$(_run_load "mongo-1" "mongodb-credentials" "MONGO_ROOT_USER" "MONGO_ROOT_PASS" "root") || true
  [[ -f "$AQSH_RESULT_FILE" ]]
  cat "$AQSH_RESULT_FILE" | grep -q '"status":"error"'
}

# ---------------------------------------------------------------------------
# Error: JSON output fields when credential loading fails
# ---------------------------------------------------------------------------

@test "error JSON includes namespace and secret name" {
  export MOCK_SECRET_MISS=1
  _run_load "mongo-1" "mongodb-credentials" "MONGO_ROOT_USER" "MONGO_ROOT_PASS" || true
  [[ -f "$AQSH_RESULT_FILE" ]]
  cat "$AQSH_RESULT_FILE" | grep -q '"namespace":"mongo-1"'
  cat "$AQSH_RESULT_FILE" | grep -q '"secret":"mongodb-credentials"'
}

@test "empty-value error JSON includes user_key and pass_key for diagnosis" {
  MOCK_SECRET_USER=$(printf '' | base64)
  _run_load "mongo-1" "mongodb-credentials" "MONGO_ROOT_USER" "MONGO_ROOT_PASS" || true
  [[ -f "$AQSH_RESULT_FILE" ]]
  cat "$AQSH_RESULT_FILE" | grep -q '"user_key":"MONGO_ROOT_USER"'
  cat "$AQSH_RESULT_FILE" | grep -q '"pass_key":"MONGO_ROOT_PASS"'
}
