#!/usr/bin/env bats
# =============================================================================
# Unit tests for mongodb-recovery.sh library functions.
# Uses a mock kubectl placed in $TEST_TMPDIR/bin; no external cluster required.
#
# Mock control env vars (set in setup or per-test):
#   MOCK_HAS_INIT_CONTAINER  1|0    G1: init container present/absent
#   MOCK_HAS_CM              1|0    G2: ConfigMap present/absent
#   MOCK_PRIMARY_POD         name   which pod responds as primary
#   MOCK_POD0_PHASE          string phase for mongodb-0
#   MOCK_DATA_MB             number du output for G5
#   MOCK_AVAIL_MB            number df available MB for G6
#   MOCK_OPLOG_VERDICT       ok|resize  G4 verdict from mongosh
#   MOCK_PATCH_FAIL          1|0    kubectl patch returns error
#   MOCK_FREEZE_FAIL         1|0    rs.freeze returns error
# =============================================================================

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export K8S_NAMESPACE="mongo-1"
  export _LOG_CURRENT_LEVEL=3   # suppress all but CRIT in tests
  export FORCE_WIPE="false"
  LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export LIB_DIR

  export MOCK_HAS_INIT_CONTAINER=1
  export MOCK_HAS_CM=1
  export MOCK_PRIMARY_POD="mongodb-0"
  export MOCK_POD0_PHASE="Running"
  export MOCK_DATA_MB=1024
  export MOCK_AVAIL_MB=2000
  export MOCK_OPLOG_VERDICT="ok"
  export MOCK_PATCH_FAIL=0
  export MOCK_FREEZE_FAIL=0
  export MOCK_POD_ABSENT=0
  export RECOVERY_POLL_INTERVAL=0   # no real sleeping in unit tests

  mkdir -p "${TEST_TMPDIR}/bin"

  # ── Mock kubectl ──────────────────────────────────────────────────────────
  cat > "${TEST_TMPDIR}/bin/kubectl" << 'KUBECTL_EOF'
#!/usr/bin/env bash
# Strip kubectl global flags
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context|--namespace|-n|--kubeconfig) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

cmd="${args[0]:-}"
sub="${args[1]:-}"
name="${args[2]:-}"
flags="${args[*]:-}"

case "$cmd" in
  get)
    case "$sub" in
      statefulset|sts)
        if [[ "$flags" == *"-o json"* || "$flags" == *"json"* ]]; then
          IC_BLOCK=""
          if [[ "${MOCK_HAS_INIT_CONTAINER:-1}" == "1" ]]; then
            IC_BLOCK='"initContainers":[{"name":"data-recovery"}],'
          fi
          printf '{"spec":{"replicas":3,"selector":{"matchLabels":{"app":"mongodb"}},"updateStrategy":{"rollingUpdate":{"partition":3}},"template":{"spec":{%s"containers":[{"image":"mongo:6"}]}}},"status":{"replicas":3,"readyReplicas":3}}\n' "${IC_BLOCK}"
        elif [[ "$flags" == *"go-template"* ]]; then
          printf 'app=mongodb,'
        elif [[ "$flags" == *"replicas"* ]]; then
          printf '3'
        elif [[ "$flags" == *"partition"* ]]; then
          printf '3'
        fi
        exit 0 ;;
      configmap|cm)
        [[ "${MOCK_HAS_CM:-1}" == "0" ]] && exit 1
        if [[ "$flags" == *"wipe-targets"* ]]; then
          printf ''
        else
          printf '{"data":{"wipe-targets":"","recovery-version":"0"}}\n'
        fi
        exit 0 ;;
      pods)
        printf 'mongodb-0\nmongodb-1\nmongodb-2\n'
        exit 0 ;;
      pod)
        if [[ "$flags" == *"phase"* ]]; then
          case "$name" in
            mongodb-0) printf '%s' "${MOCK_POD0_PHASE:-Running}" ;;
            *) printf 'Running' ;;
          esac
        elif [[ "$flags" == *"metadata.uid"* ]]; then
          # Simulate pod restart: UID changes once a wipe patch has been applied
          if [[ "${MOCK_POD_ABSENT:-0}" == "1" && ! -f "${TEST_TMPDIR}/patched-statefulset-mongodb" ]]; then
            printf ''                       # pod was absent before wipe
          elif [[ -f "${TEST_TMPDIR}/patched-statefulset-mongodb" ]]; then
            printf 'uid-new-%s' "$name"     # post-wipe → recreated
          else
            printf 'uid-old-%s' "$name"     # pre-wipe
          fi
        fi
        exit 0 ;;
      pvc) exit 1 ;;
    esac ;;
  exec)
    pod="${args[1]:-}"
    js="${flags}"
    if [[ "$js" == *"isWritablePrimary"* || "$js" == *"ismaster"* ]]; then
      [[ "$pod" == "${MOCK_PRIMARY_POD:-mongodb-0}" ]] && printf '1' || printf '0'
    elif [[ "$js" == *"stateStr"*"health"* ]]; then
      [[ "$pod" == "${MOCK_PRIMARY_POD:-mongodb-0}" ]] && printf 'PRIMARY,1' || printf 'SECONDARY,1'
    elif [[ "$js" == *"stateStr"*"self"* || "$js" == *"stateStr"*"optime"* ]]; then
      [[ "$pod" == "${MOCK_PRIMARY_POD:-mongodb-0}" ]] && printf 'PRIMARY,1,1700000000' || printf 'SECONDARY,1,1699990000'
    elif [[ "$js" == *"replSetResizeOplog"* ]]; then
      printf '{"ok":1}'
    elif [[ "$js" == *"collStats"* || "$js" == *"oplog.rs"* ]]; then
      if [[ "${MOCK_OPLOG_VERDICT:-ok}" == "ok" ]]; then
        printf '4096,12,300,1,4,2048,ok\n'
      else
        printf '512,2,200,1,4,2048,resize\n'
      fi
    elif [[ "$js" == *"du -sm"* ]]; then
      printf '%s\t/bitnami/mongodb/data/db\n' "${MOCK_DATA_MB:-1024}"
    elif [[ "$js" == *"df -m"* ]]; then
      printf 'Filesystem 1M Used Avail Use%% Mount\n/dev/sda1 50000 10000 %s 20%% /bitnami\n' "${MOCK_AVAIL_MB:-2000}"
    elif [[ "$js" == *"rs.freeze"* ]]; then
      [[ "${MOCK_FREEZE_FAIL:-0}" == "1" ]] && printf 'err:freeze failed' || printf 'ok'
    elif [[ "$js" == *"rs.conf"* ]]; then
      printf '{"_id":"rs0","version":5,"members":[{"_id":0,"host":"mongodb-0.mongodb.mongo-1.svc.cluster.local:27017","priority":1,"votes":1},{"_id":1,"host":"mongodb-1.mongodb.mongo-1.svc.cluster.local:27017","priority":1,"votes":1},{"_id":2,"host":"mongodb-2.mongodb.mongo-1.svc.cluster.local:27017","priority":1,"votes":1}]}'
    elif [[ "$js" == *"rs.reconfig"* ]]; then
      printf '{"ok":1}'
    elif [[ "$js" == *"rs.add"* ]]; then
      printf '{"ok":1}'
    elif [[ "$js" == *"RECOVERING"* ]]; then
      printf ''
    elif [[ "$js" == *"optime"* ]]; then
      [[ "$pod" == "${MOCK_PRIMARY_POD:-mongodb-0}" ]] && printf '1700000000' || printf '1699990000'
    fi
    exit 0 ;;
  patch)
    [[ "${MOCK_PATCH_FAIL:-0}" == "1" ]] && { printf 'patch forbidden\n' >&2; exit 1; }
    touch "${TEST_TMPDIR}/patched-${sub}-${name}"
    printf '%s/%s patched\n' "$sub" "$name"
    exit 0 ;;
esac
exit 0
KUBECTL_EOF
  chmod +x "${TEST_TMPDIR}/bin/kubectl"

  # Source all required libs
  # shellcheck source=/dev/null
  source "${LIB_DIR}/logging.sh"
  source "${LIB_DIR}/response.sh"
  source "${LIB_DIR}/k8s.sh"
  source "${LIB_DIR}/mongodb.sh"
  source "${LIB_DIR}/mongodb-recovery.sh"
}

# ── G1 ────────────────────────────────────────────────────────────────────────

@test "G1 passes when init container is present" {
  out=$(_recovery_gate_g1 "mongodb")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
}

@test "G1 fails when init container is absent" {
  export MOCK_HAS_INIT_CONTAINER=0
  out=$(_recovery_gate_g1 "mongodb") || true
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "false" ]
  [ "$code" = "INIT_CONTAINER_MISSING" ]
}

# ── G2 ────────────────────────────────────────────────────────────────────────

@test "G2 passes when ConfigMap exists" {
  out=$(_recovery_gate_g2 "mongodb-recovery-config")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
}

@test "G2 fails when ConfigMap is missing" {
  export MOCK_HAS_CM=0
  out=$(_recovery_gate_g2 "mongodb-recovery-config") || true
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "false" ]
  [ "$code" = "CONFIGMAP_MISSING" ]
}

# ── G5 ────────────────────────────────────────────────────────────────────────

@test "G5 passes when data is within 100GB limit" {
  export MOCK_DATA_MB=20480
  out=$(_recovery_gate_g5 "mongodb" "mongodb-2")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  data_mb=$(printf '%s' "$out" | grep -o '"data_mb":[0-9]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
  [ "$data_mb" = "20480" ]
}

@test "G5 blocks when data exceeds 100GB and FORCE_WIPE is false" {
  export MOCK_DATA_MB=110000
  export FORCE_WIPE=false
  out=$(_recovery_gate_g5 "mongodb" "mongodb-2") || true
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "false" ]
  [ "$code" = "DATA_TOO_LARGE" ]
}

@test "G5 passes with warn when FORCE_WIPE=true and data exceeds 100GB" {
  export MOCK_DATA_MB=110000
  export FORCE_WIPE=true
  out=$(_recovery_gate_g5 "mongodb" "mongodb-2")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  warn=$(printf '%s' "$out" | grep -o '"warn":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
  [ "$warn" = "true" ]
}

# ── G4 ────────────────────────────────────────────────────────────────────────

@test "G4 passes when oplog window is sufficient" {
  export MOCK_OPLOG_VERDICT=ok
  out=$(_recovery_gate_g4 "mongodb" "user" "pass" "1024")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
}

@test "G4 auto-resizes and passes with warn when oplog is too small" {
  export MOCK_OPLOG_VERDICT=resize
  out=$(_recovery_gate_g4 "mongodb" "user" "pass" "10240")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  warn=$(printf '%s' "$out" | grep -o '"warn":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
  [ "$warn" = "true" ]
}

# ── G7 ────────────────────────────────────────────────────────────────────────

@test "G7 passes for non-pod-0 target without primary check" {
  out=$(_recovery_gate_g7 "mongodb" "mongodb-2" "user" "pass")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
}

@test "G7 blocks when pod-0 is Running and is the current primary" {
  export MOCK_PRIMARY_POD=mongodb-0
  export MOCK_POD0_PHASE=Running
  out=$(_recovery_gate_g7 "mongodb" "mongodb-0" "user" "pass") || true
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "false" ]
  [ "$code" = "POD0_IS_PRIMARY" ]
}

@test "G7 passes when pod-0 is not Running" {
  export MOCK_POD0_PHASE=CrashLoopBackOff
  out=$(_recovery_gate_g7 "mongodb" "mongodb-0" "user" "pass")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
}

@test "G7 passes when pod-0 is Running but is secondary" {
  export MOCK_PRIMARY_POD=mongodb-1
  export MOCK_POD0_PHASE=Running
  out=$(_recovery_gate_g7 "mongodb" "mongodb-0" "user" "pass")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
}

# ── recovery_wipe_pod ─────────────────────────────────────────────────────────

@test "recovery_wipe_pod patches CM and STS for a non-pod-0 target" {
  result=$(recovery_wipe_pod "mongodb" "mongodb-2" "mongodb-recovery-config")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "success" ]
  [ -f "${TEST_TMPDIR}/patched-configmap-mongodb-recovery-config" ]
  [ -f "${TEST_TMPDIR}/patched-statefulset-mongodb" ]
}

@test "recovery_wipe_pod returns error when STS patch fails" {
  export MOCK_PATCH_FAIL=1
  result=$(recovery_wipe_pod "mongodb" "mongodb-2" "mongodb-recovery-config") || true
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "error" ]
}

@test "recovery_wipe_pod sets the correct partition ordinal (pod-2 → partition 2)" {
  result=$(recovery_wipe_pod "mongodb" "mongodb-2" "mongodb-recovery-config")
  ordinal=$(printf '%s' "$result" | grep -o '"ordinal":[0-9]*' | cut -d':' -f2)
  [ "$ordinal" = "2" ]
}

@test "recovery_wipe_pod sets partition 0 for pod-0 target" {
  result=$(recovery_wipe_pod "mongodb" "mongodb-0" "mongodb-recovery-config")
  ordinal=$(printf '%s' "$result" | grep -o '"ordinal":[0-9]*' | cut -d':' -f2)
  [ "$ordinal" = "0" ]
}

# ── recovery_reset ────────────────────────────────────────────────────────────

@test "recovery_reset patches CM and STS with correct partition" {
  result=$(recovery_reset "mongodb" "mongodb-recovery-config" "3")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  partition=$(printf '%s' "$result" | grep -o '"partition":[0-9]*' | cut -d':' -f2)
  [ "$status_val" = "success" ]
  [ "$partition" = "3" ]
  [ -f "${TEST_TMPDIR}/patched-configmap-mongodb-recovery-config" ]
}

@test "recovery_reset returns error when CM patch fails" {
  export MOCK_PATCH_FAIL=1
  result=$(recovery_reset "mongodb" "mongodb-recovery-config" "3") || true
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "error" ]
}

# ── recovery_run_gates (report mode) ─────────────────────────────────────────

@test "recovery_run_gates passes in report mode when all checks are healthy" {
  result=$(recovery_run_gates "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "report")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  fail_count=$(printf '%s' "$result" | grep -o '"fail":[0-9]*' | head -1 | cut -d':' -f2)
  [ "$status_val" = "success" ]
  [ "${fail_count:-1}" = "0" ]
}

@test "recovery_run_gates report mode returns error status when G1 fails" {
  export MOCK_HAS_INIT_CONTAINER=0
  result=$(recovery_run_gates "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "report") || true
  fail_count=$(printf '%s' "$result" | grep -o '"fail":[0-9]*' | head -1 | cut -d':' -f2)
  [ "${fail_count:-0}" -ge "1" ]
}

@test "recovery_run_gates gate mode exits immediately on G1 failure" {
  export MOCK_HAS_INIT_CONTAINER=0
  result=$(recovery_run_gates "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "gate") || true
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "error" ]
  # In gate mode only 1 gate result is emitted (G1)
  gate_count=$(printf '%s' "$result" | grep -o '"gate":"G[0-9]"' | wc -l | tr -d ' ')
  [ "$gate_count" -eq "1" ]
}

@test "recovery_run_gates gate mode exits immediately on G2 failure" {
  export MOCK_HAS_CM=0
  result=$(recovery_run_gates "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "gate") || true
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "error" ]
}

@test "recovery_run_gates gate mode exits on G5 when data exceeds 100GB" {
  export MOCK_DATA_MB=110000
  export FORCE_WIPE=false
  result=$(recovery_run_gates "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "gate") || true
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "error" ]
}

# ── recovery_fix_diagnose ─────────────────────────────────────────────────────

@test "fix_diagnose reports PRIMARY_EXISTS when primary pod is Running" {
  result=$(recovery_fix_diagnose "mongodb" "user" "pass")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  diagnosis=$(printf '%s' "$result" | grep -o '"diagnosis":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "success" ]
  [ "$diagnosis" = "PRIMARY_EXISTS" ]
}

@test "fix_diagnose primary_count is at least 1 in a healthy cluster" {
  result=$(recovery_fix_diagnose "mongodb" "user" "pass")
  primary_count=$(printf '%s' "$result" | grep -o '"primary_count":[0-9]*' | head -1 | cut -d':' -f2)
  [ "${primary_count:-0}" -ge "1" ]
}

# ── recovery_fix_unfreeze ─────────────────────────────────────────────────────

@test "fix_unfreeze succeeds on all Running pods" {
  result=$(recovery_fix_unfreeze "mongodb" "user" "pass")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  success_count=$(printf '%s' "$result" | grep -o '"success_count":[0-9]*' | head -1 | cut -d':' -f2)
  [ "$status_val" = "success" ]
  [ "${success_count:-0}" -ge "1" ]
}

@test "fix_unfreeze returns error when all pods fail to freeze" {
  export MOCK_FREEZE_FAIL=1
  result=$(recovery_fix_unfreeze "mongodb" "user" "pass") || true
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "error" ]
}

# ── recovery_fix_reconfig ─────────────────────────────────────────────────────

@test "fix_reconfig succeeds and returns reconfig_pod" {
  result=$(recovery_fix_reconfig "mongodb" "user" "pass")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "success" ]
  printf '%s' "$result" | grep -q '"reconfig_pod"'
}

# ── recovery_fix_force_primary ────────────────────────────────────────────────

@test "fix_force_primary completes with re_add_results" {
  result=$(recovery_fix_force_primary "mongodb" "mongodb-0" "user" "pass")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "success" ]
  printf '%s' "$result" | grep -q '"re_add_results"'
  printf '%s' "$result" | grep -q '"force_pod"'
}

# ── _recovery_pod_ordinal ─────────────────────────────────────────────────────

@test "_recovery_pod_ordinal extracts ordinal from pod name" {
  [ "$(_recovery_pod_ordinal mongodb-0)" = "0" ]
  [ "$(_recovery_pod_ordinal mongodb-1)" = "1" ]
  [ "$(_recovery_pod_ordinal mongodb-12)" = "12" ]
}

# ── recovery_recover (orchestrator) ──────────────────────────────────────────

@test "recovery_recover completes full flow: gates -> wipe -> wait -> reset" {
  result=$(recovery_recover "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "3" "30")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "success" ]
  # both wipe (CM+STS) and reset patches happened
  [ -f "${TEST_TMPDIR}/patched-configmap-mongodb-recovery-config" ]
  [ -f "${TEST_TMPDIR}/patched-statefulset-mongodb" ]
  printf '%s' "$result" | grep -q '"reached_running":true'
  printf '%s' "$result" | grep -q '"partition_restored":3'
}

@test "recovery_recover aborts at gates when init container is missing (no wipe applied)" {
  export MOCK_HAS_INIT_CONTAINER=0
  result=$(recovery_recover "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "3" "30") || true
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  phase=$(printf '%s' "$result" | grep -o '"phase":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "error" ]
  [ "$phase" = "gates" ]
  # no STS patch should have been applied
  [ ! -f "${TEST_TMPDIR}/patched-statefulset-mongodb" ]
}

@test "recovery_recover handles a previously-absent pod (empty old UID)" {
  export MOCK_POD_ABSENT=1
  result=$(recovery_recover "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "3" "30")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "success" ]
}

@test "recovery_recover result includes a next_step pointer to monitor sync" {
  result=$(recovery_recover "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "3" "30")
  printf '%s' "$result" | grep -q '"next_step"'
}
