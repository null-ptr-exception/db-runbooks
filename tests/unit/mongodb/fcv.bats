#!/usr/bin/env bats
# =============================================================================
# Unit tests for lib/mongodb-fcv.sh (fcv/status + fcv/set helpers): the
# version->FCV compatibility table, direction math, and the sentinel-guarded
# mongosh round trips (fcv_read_info / fcv_execute_set). Uses a mock kubectl
# placed in $TEST_TMPDIR/bin; no cluster.
#
# Mock control env vars:
#   MOCK_POD_LIST      pod names returned by `kubectl get pods -l ...`
#   MOCK_POD_READY     True/False  Ready-condition status for every pod
#   MOCK_POD_PHASE     phase  pod phase for every pod (Running fallback path)
#   MOCK_FCV_EXEC_OUT  text   what the exec'd mongosh prints (e.g.
#                             "FCVINFO:{...}", "FCVSETERR:...", or raw
#                             kubectl error text with no sentinel)
#   MOCK_EXEC_RECORD_FILE path  when set, the exec'd argv (including the
#                             --eval JS) is appended here — used to assert
#                             whether confirm:true was included
# =============================================================================

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export K8S_NAMESPACE="mongo-1"
  export _LOG_CURRENT_LEVEL=4
  LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export LIB_DIR

  export MOCK_POD_LIST=""
  export MOCK_POD_READY=""
  export MOCK_POD_PHASE=""
  export MOCK_FCV_EXEC_OUT=""
  export MOCK_EXEC_RECORD_FILE=""

  mkdir -p "${TEST_TMPDIR}/bin"

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

case "$cmd" in
  get)
    case "$sub" in
      pods)
        if [[ -n "${MOCK_POD_LIST:-}" ]]; then
          printf '%s\n' ${MOCK_POD_LIST}
        fi
        exit 0 ;;
      pod)
        if [[ "$flags" == *"conditions"* ]]; then
          printf '%s' "${MOCK_POD_READY:-}"
        elif [[ "$flags" == *"phase"* ]]; then
          printf '%s' "${MOCK_POD_PHASE:-}"
        fi
        exit 0 ;;
      statefulset|sts)
        if [[ "$flags" == *"go-template"* ]]; then
          printf 'app=mongodb,'
        fi
        exit 0 ;;
    esac
    exit 0 ;;
  exec)
    if [[ -n "${MOCK_EXEC_RECORD_FILE:-}" ]]; then
      printf '%s\n' "$flags" >> "${MOCK_EXEC_RECORD_FILE}"
    fi
    if [[ -n "${MOCK_FCV_EXEC_OUT:-}" ]]; then
      printf '%s\n' "${MOCK_FCV_EXEC_OUT}"
    fi
    exit 0 ;;
esac
exit 0
KUBECTL_EOF
  chmod +x "${TEST_TMPDIR}/bin/kubectl"

  # shellcheck source=/dev/null
  source "${LIB_DIR}/logging.sh"
  source "${LIB_DIR}/response.sh"
  source "${LIB_DIR}/k8s.sh"
  source "${LIB_DIR}/mongodb.sh"
  source "${LIB_DIR}/mongodb-recovery.sh"
  source "${LIB_DIR}/mongodb-fcv.sh"
}

# ── fcv_binary_series ───────────────────────────────────────────────────────

@test "binary_series reduces a full version to major.minor" {
  run fcv_binary_series "7.0.21"
  [ "$status" -eq 0 ]
  [ "$output" = "7.0" ]
}

@test "binary_series handles patch suffixes" {
  run fcv_binary_series "8.0.4"
  [ "$status" -eq 0 ]
  [ "$output" = "8.0" ]
}

@test "binary_series accepts a bare major.minor" {
  run fcv_binary_series "6.0"
  [ "$status" -eq 0 ]
  [ "$output" = "6.0" ]
}

@test "binary_series rejects garbage" {
  run fcv_binary_series "not-a-version"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "binary_series rejects a bare major" {
  run fcv_binary_series "7"
  [ "$status" -eq 1 ]
}

# ── fcv_previous_series (the compatibility table) ───────────────────────────

@test "previous_series covers the full documented table" {
  local pairs=("8.0 7.0" "7.0 6.0" "6.0 5.0" "5.0 4.4" "4.4 4.2" "4.2 4.0")
  local pair
  for pair in "${pairs[@]}"; do
    run fcv_previous_series "${pair% *}"
    [ "$status" -eq 0 ]
    [ "$output" = "${pair#* }" ]
  done
}

@test "previous_series derives future annual releases numerically" {
  run fcv_previous_series "9.0"
  [ "$status" -eq 0 ]
  [ "$output" = "8.0" ]
  run fcv_previous_series "10.0"
  [ "$status" -eq 0 ]
  [ "$output" = "9.0" ]
}

@test "previous_series fails closed below the table (4.0, 3.6)" {
  run fcv_previous_series "4.0"
  [ "$status" -eq 1 ]
  run fcv_previous_series "3.6"
  [ "$status" -eq 1 ]
}

@test "previous_series fails closed for a non-.0 series like 7.1" {
  run fcv_previous_series "7.1"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ── fcv_allowed_targets ─────────────────────────────────────────────────────

@test "allowed_targets is previous + current series" {
  run fcv_allowed_targets "7.0"
  [ "$status" -eq 0 ]
  [ "$output" = "6.0 7.0" ]
}

@test "allowed_targets fails when the series has no mapping" {
  run fcv_allowed_targets "7.1"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ── fcv_direction ───────────────────────────────────────────────────────────

@test "direction detects upgrade, downgrade, and none" {
  run fcv_direction "6.0" "7.0"
  [ "$output" = "upgrade" ]
  run fcv_direction "7.0" "6.0"
  [ "$output" = "downgrade" ]
  run fcv_direction "7.0" "7.0"
  [ "$output" = "none" ]
}

@test "direction compares minor within the same major (4.2 vs 4.4)" {
  run fcv_direction "4.2" "4.4"
  [ "$output" = "upgrade" ]
  run fcv_direction "4.4" "4.2"
  [ "$output" = "downgrade" ]
}

# ── _fcv_probe_pod ──────────────────────────────────────────────────────────

@test "probe_pod picks the first Ready pod" {
  export MOCK_POD_LIST="mongodb-0 mongodb-1"
  export MOCK_POD_READY="True"
  run _fcv_probe_pod "mongodb"
  [ "$status" -eq 0 ]
  [ "$output" = "mongodb-0" ]
}

@test "probe_pod falls back to a Running pod when none are Ready" {
  export MOCK_POD_LIST="mongodb-0"
  export MOCK_POD_READY="False"
  export MOCK_POD_PHASE="Running"
  run _fcv_probe_pod "mongodb"
  [ "$status" -eq 0 ]
  [ "$output" = "mongodb-0" ]
}

@test "probe_pod fails when no pod is Ready or Running" {
  export MOCK_POD_LIST="mongodb-0"
  export MOCK_POD_READY="False"
  export MOCK_POD_PHASE="Pending"
  run _fcv_probe_pod "mongodb"
  [ "$status" -eq 1 ]
}

# ── fcv_read_info ───────────────────────────────────────────────────────────

@test "read_info returns the FCVINFO JSON payload" {
  export MOCK_FCV_EXEC_OUT='FCVINFO:{"version":"7.0.21","fcv":"7.0","targetFcv":null}'
  run fcv_read_info "mongodb-0" "mongodb-0:27017" "root" "pass"
  [ "$status" -eq 0 ]
  [ "$output" = '{"version":"7.0.21","fcv":"7.0","targetFcv":null}' ]
}

@test "read_info surfaces a transitional targetFcv" {
  export MOCK_FCV_EXEC_OUT='FCVINFO:{"version":"7.0.21","fcv":"6.0","targetFcv":"7.0"}'
  run fcv_read_info "mongodb-0" "mongodb-0:27017" "root" "pass"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.targetFcv == "7.0"'
}

@test "read_info rejects kubectl error text with no sentinel (the stderr-merge case)" {
  export MOCK_FCV_EXEC_OUT='Error from server (NotFound): pods "mongodb-0" not found'
  run fcv_read_info "mongodb-0" "mongodb-0:27017" "root" "pass"
  [ "$status" -eq 1 ]
}

@test "read_info rejects an FCVERR sentinel (JS-level failure)" {
  export MOCK_FCV_EXEC_OUT='FCVERR:not authorized on admin'
  run fcv_read_info "mongodb-0" "mongodb-0:27017" "root" "pass"
  [ "$status" -eq 1 ]
}

@test "read_info fails on empty output" {
  export MOCK_FCV_EXEC_OUT=''
  run fcv_read_info "mongodb-0" "mongodb-0:27017" "root" "pass"
  [ "$status" -eq 1 ]
}

# ── fcv_execute_set ─────────────────────────────────────────────────────────

@test "execute_set succeeds on ok:1 and returns the server response" {
  export MOCK_FCV_EXEC_OUT='FCVSET:{"ok":1}'
  run fcv_execute_set "mongodb-0" "mongodb-0:27017" "root" "pass" "6.0" "7"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":1}' ]
}

@test "execute_set includes confirm:true for server major 7 and 8" {
  export MOCK_FCV_EXEC_OUT='FCVSET:{"ok":1}'
  local major
  for major in 7 8; do
    export MOCK_EXEC_RECORD_FILE="${TEST_TMPDIR}/argv-${major}"
    run fcv_execute_set "mongodb-0" "mongodb-0:27017" "root" "pass" "7.0" "$major"
    [ "$status" -eq 0 ]
    grep -q "cmd.confirm=true" "${MOCK_EXEC_RECORD_FILE}"
  done
}

@test "execute_set omits confirm for server major 6" {
  export MOCK_FCV_EXEC_OUT='FCVSET:{"ok":1}'
  export MOCK_EXEC_RECORD_FILE="${TEST_TMPDIR}/argv-6"
  run fcv_execute_set "mongodb-0" "mongodb-0:27017" "root" "pass" "5.0" "6"
  [ "$status" -eq 0 ]
  ! grep -q "confirm" "${MOCK_EXEC_RECORD_FILE}"
}

@test "execute_set fails on ok:0 server response" {
  export MOCK_FCV_EXEC_OUT='FCVSET:{"ok":0,"errmsg":"cannot downgrade"}'
  run fcv_execute_set "mongodb-0" "mongodb-0:27017" "root" "pass" "6.0" "7"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.errmsg == "cannot downgrade"'
}

@test "execute_set fails on FCVSETERR sentinel and passes the diagnostic through" {
  export MOCK_FCV_EXEC_OUT='FCVSETERR:CannotDowngrade:collection has incompatible index'
  run fcv_execute_set "mongodb-0" "mongodb-0:27017" "root" "pass" "6.0" "7"
  [ "$status" -eq 1 ]
  [ "$output" = "CannotDowngrade:collection has incompatible index" ]
}

@test "execute_set rejects kubectl error text with no sentinel" {
  export MOCK_FCV_EXEC_OUT='error: unable to upgrade connection'
  run fcv_execute_set "mongodb-0" "mongodb-0:27017" "root" "pass" "6.0" "7"
  [ "$status" -eq 1 ]
}

@test "execute_set refuses a malformed target (JS-injection guard)" {
  run fcv_execute_set "mongodb-0" "mongodb-0:27017" "root" "pass" "6.0';db.dropDatabase();'" "7"
  [ "$status" -eq 1 ]
}
