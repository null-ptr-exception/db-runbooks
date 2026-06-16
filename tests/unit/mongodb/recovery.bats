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
  export MOCK_SYNCFROM_FAIL=0
  export MOCK_RECOVERING_MEMBER=""
  export MOCK_ALL_PODS_PHASE=""
  export MOCK_NON_PRIMARY_STATE="SECONDARY,1"
  export MOCK_WIPE_TARGETS=""
  export MOCK_CROSS_CLUSTER_PRIMARY=0        # 1 = primary lives in another cluster
  export MOCK_CROSS_CLUSTER_PRIMARY_HOST="cluster-a-primary:27017"
  export RECOVERY_POLL_INTERVAL=0          # no real sleeping in unit tests
  export RECOVERY_SYNCFROM_RETRY_DELAY=0   # no sleep between syncFrom retries

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
        # initContainers jsonpath must be matched before the generic json case
        if [[ "$flags" == *"initContainers"* ]]; then
          [[ "${MOCK_HAS_INIT_CONTAINER:-1}" == "1" ]] && printf 'data-recovery'
          exit 0
        elif [[ "$flags" == *"-o json"* || "$flags" == *"json"* ]]; then
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
          printf '%s' "${MOCK_WIPE_TARGETS:-}"
        else
          printf '{"data":{"wipe-targets":"","recovery-version":"0"}}\n'
        fi
        exit 0 ;;
      pods)
        printf 'mongodb-0\nmongodb-1\nmongodb-2\n'
        exit 0 ;;
      pod)
        if [[ "$flags" == *"phase"* ]]; then
          if [[ -n "${MOCK_ALL_PODS_PHASE:-}" ]]; then
            printf '%s' "${MOCK_ALL_PODS_PHASE}"
          else
            case "$name" in
              mongodb-0) printf '%s' "${MOCK_POD0_PHASE:-Running}" ;;
              *) printf 'Running' ;;
            esac
          fi
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
    elif [[ "$js" == *"p?p.name"* ]]; then
      # _recovery_primary_host: return RS PRIMARY host:port from full members list
      if [[ "${MOCK_CROSS_CLUSTER_PRIMARY:-0}" == "1" ]]; then
        printf '%s' "${MOCK_CROSS_CLUSTER_PRIMARY_HOST:-cluster-a-primary:27017}"
      elif [[ "${MOCK_PRIMARY_POD:-mongodb-0}" == "__none__" ]]; then
        printf ''
      else
        printf '%s.mongodb.mongo-1.svc.cluster.local:27017' "${MOCK_PRIMARY_POD:-mongodb-0}"
      fi
    elif [[ "$js" == *"members.some"* ]]; then
      # G3 new JS: returns any_primary_flag,self_stateStr,self_health
      local g3_has_primary="0"
      if [[ "${MOCK_CROSS_CLUSTER_PRIMARY:-0}" == "1" ]]; then
        g3_has_primary="1"
      elif [[ "${MOCK_PRIMARY_POD:-mongodb-0}" != "__none__" ]]; then
        g3_has_primary="1"
      fi
      if [[ "$pod" == "${MOCK_PRIMARY_POD:-mongodb-0}" && "${MOCK_CROSS_CLUSTER_PRIMARY:-0}" != "1" ]]; then
        printf '%s,PRIMARY,1' "$g3_has_primary"
      else
        printf '%s,%s' "$g3_has_primary" "${MOCK_NON_PRIMARY_STATE:-SECONDARY,1}"
      fi
    elif [[ "$js" == *"print(m.name)"* ]]; then
      printf '%s.mongodb.mongo-1.svc.cluster.local:27017\n' "$pod"
    elif [[ "$js" == *"replSetSyncFrom"* ]]; then
      [[ "${MOCK_SYNCFROM_FAIL:-0}" == "1" ]] && printf '{"ok":0,"errmsg":"syncFrom failed"}' || printf '{"ok":1}'
    elif [[ "$js" == *"stateStr"*"health"* ]]; then
      if [[ "$pod" == "${MOCK_PRIMARY_POD:-mongodb-0}" ]]; then
        printf 'PRIMARY,1'
      else
        printf '%s' "${MOCK_NON_PRIMARY_STATE:-SECONDARY,1}"
      fi
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
    elif [[ "$js" == *"rs.reconfig"* ]]; then
      # Must precede rs.conf: reconfig scripts also call rs.conf() internally,
      # but mongosh only outputs the final print (the reconfig result).
      printf '{"ok":1}'
    elif [[ "$js" == *"rs.add"* ]]; then
      printf '{"ok":1}'
    elif [[ "$js" == *"rs.conf"* ]]; then
      printf '{"_id":"rs0","version":5,"members":[{"_id":0,"host":"mongodb-0.mongodb.mongo-1.svc.cluster.local:27017","priority":1,"votes":1},{"_id":1,"host":"mongodb-1.mongodb.mongo-1.svc.cluster.local:27017","priority":1,"votes":1},{"_id":2,"host":"mongodb-2.mongodb.mongo-1.svc.cluster.local:27017","priority":1,"votes":1}]}'
    elif [[ "$js" == *"RECOVERING"* ]]; then
      printf '%s' "${MOCK_RECOVERING_MEMBER:-}"
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

# _d: unescape response_ok's double-encoded data field so grep can find inner keys
_d() { printf '%s' "$1" | sed 's/\\"/"/g'; }

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

@test "G4 does not resize when allow_resize=false (report mode is read-only)" {
  export MOCK_OPLOG_VERDICT=resize
  out=$(_recovery_gate_g4 "mongodb" "user" "pass" "10240" "false")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  warn=$(printf '%s' "$out" | grep -o '"warn":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "true" ]
  [ "$warn" = "true" ]
  [ "$code" = "OPLOG_RESIZE_NEEDED" ]
}

# ── G7 ────────────────────────────────────────────────────────────────────────

@test "G7 blocks when pod-0 is Running and is the current primary" {
  export MOCK_PRIMARY_POD=mongodb-0
  export MOCK_POD0_PHASE=Running
  out=$(_recovery_gate_g7 "mongodb" "mongodb-0" "user" "pass") || true
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "false" ]
  [ "$code" = "TARGET_IS_PRIMARY" ]
}

@test "G7 passes when pod-0 is not Running (CrashLoopBackOff)" {
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

@test "G7 blocks when pod-1 is Running and is primary (post-reconfig, any pod can be primary)" {
  export MOCK_PRIMARY_POD=mongodb-1
  out=$(_recovery_gate_g7 "mongodb" "mongodb-1" "user" "pass") || true
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "false" ]
  [ "$code" = "TARGET_IS_PRIMARY" ]
}

@test "G7 blocks when pod-2 is Running and is primary (post-reconfig)" {
  export MOCK_PRIMARY_POD=mongodb-2
  out=$(_recovery_gate_g7 "mongodb" "mongodb-2" "user" "pass") || true
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "false" ]
  [ "$code" = "TARGET_IS_PRIMARY" ]
}

@test "G7 passes when pod-1 is Running but is secondary" {
  export MOCK_PRIMARY_POD=mongodb-0
  out=$(_recovery_gate_g7 "mongodb" "mongodb-1" "user" "pass")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
}

@test "G7 passes when pod-2 is CrashLoopBackOff (pod-0 crashed, wipe pod-2 is safe)" {
  export MOCK_ALL_PODS_PHASE=CrashLoopBackOff
  out=$(_recovery_gate_g7 "mongodb" "mongodb-2" "user" "pass")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
}

@test "G7 error code is TARGET_IS_PRIMARY not POD0_IS_PRIMARY" {
  export MOCK_PRIMARY_POD=mongodb-1
  out=$(_recovery_gate_g7 "mongodb" "mongodb-1" "user" "pass") || true
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$code" = "TARGET_IS_PRIMARY" ]
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
  ordinal=$(printf '%s' "$(_d "$result")" | grep -o '"ordinal":[0-9]*' | cut -d':' -f2)
  [ "$ordinal" = "2" ]
}

@test "recovery_wipe_pod sets partition 0 for pod-0 target" {
  result=$(recovery_wipe_pod "mongodb" "mongodb-0" "mongodb-recovery-config")
  ordinal=$(printf '%s' "$(_d "$result")" | grep -o '"ordinal":[0-9]*' | cut -d':' -f2)
  [ "$ordinal" = "0" ]
}

# ── recovery_reset ────────────────────────────────────────────────────────────

@test "recovery_reset patches CM and STS with correct partition" {
  result=$(recovery_reset "mongodb" "mongodb-recovery-config" "3")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  partition=$(printf '%s' "$(_d "$result")" | grep -o '"partition":[0-9]*' | cut -d':' -f2)
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
  fail_count=$(printf '%s' "$(_d "$result")" | grep -o '"fail":[0-9]*' | head -1 | cut -d':' -f2)
  [ "$status_val" = "success" ]
  [ "${fail_count:-1}" = "0" ]
}

@test "recovery_run_gates report mode returns error status when G1 fails" {
  export MOCK_HAS_INIT_CONTAINER=0
  result=$(recovery_run_gates "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "report") || true
  fail_count=$(printf '%s' "$(_d "$result")" | grep -o '"fail":[0-9]*' | head -1 | cut -d':' -f2)
  [ "${fail_count:-0}" -ge "1" ]
}

@test "recovery_run_gates gate mode exits immediately on G1 failure" {
  export MOCK_HAS_INIT_CONTAINER=0
  result=$(recovery_run_gates "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "gate") || true
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "error" ]
  # In gate mode only 1 gate result is emitted (G1)
  gate_count=$(printf '%s' "$(_d "$result")" | grep -o '"gate":"G[0-9]"' | wc -l | tr -d ' ')
  [ "$gate_count" -eq "1" ]
}

@test "recovery_run_gates gate mode exits immediately on G2 failure" {
  export MOCK_HAS_CM=0
  result=$(recovery_run_gates "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "gate") || true
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "error" ]
}

@test "recovery_run_gates report mode emits valid gates JSON when data size is unknown" {
  # data_mb=0 takes the G4/G6 "skipped" path — a regression here used to
  # string-concatenate onto gate_results[0] and corrupt the gates array.
  export MOCK_DATA_MB=0
  result=$(recovery_run_gates "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "report")
  # data must survive as a real JSON object (corrupt JSON degrades to a string)
  echo "$result" | jq -e '.data | type == "object"' >/dev/null
  gate_count=$(echo "$result" | jq '.data.gates | length')
  [ "$gate_count" -eq 8 ]
  # the skipped G4/G6 entries must be separate, parseable array elements
  echo "$result" | jq -e '.data.gates[] | select(.gate=="G4") | .warn == true' >/dev/null
  echo "$result" | jq -e '.data.gates[] | select(.gate=="G6") | .warn == true' >/dev/null
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
  diagnosis=$(printf '%s' "$(_d "$result")" | grep -o '"diagnosis":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "success" ]
  [ "$diagnosis" = "PRIMARY_EXISTS" ]
}

@test "fix_diagnose primary_count is at least 1 in a healthy cluster" {
  result=$(recovery_fix_diagnose "mongodb" "user" "pass")
  primary_count=$(printf '%s' "$(_d "$result")" | grep -o '"primary_count":[0-9]*' | head -1 | cut -d':' -f2)
  [ "${primary_count:-0}" -ge "1" ]
}

# ── recovery_fix_unfreeze ─────────────────────────────────────────────────────

@test "fix_unfreeze succeeds on all Running pods" {
  result=$(recovery_fix_unfreeze "mongodb" "user" "pass")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  success_count=$(printf '%s' "$(_d "$result")" | grep -o '"success_count":[0-9]*' | head -1 | cut -d':' -f2)
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
  printf '%s' "$(_d "$result")" | grep -q '"reconfig_pod"'
}

# ── recovery_fix_force_primary ────────────────────────────────────────────────

@test "fix_force_primary completes with re_add_results" {
  result=$(recovery_fix_force_primary "mongodb" "mongodb-0" "user" "pass")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "success" ]
  printf '%s' "$(_d "$result")" | grep -q '"re_add_results"'
  printf '%s' "$(_d "$result")" | grep -q '"force_pod"'
}

@test "fix_force_primary rejects force_pod with single-quote (shell injection guard)" {
  result=$(recovery_fix_force_primary "mongodb" "mongo'db-0" "user" "pass") || true
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "error" ]
  printf '%s' "$result" | grep -q 'Invalid force_pod'
}

@test "fix_force_primary rejects force_pod starting with a hyphen" {
  result=$(recovery_fix_force_primary "mongodb" "-mongodb-0" "user" "pass") || true
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "error" ]
}

@test "fix_force_primary accepts a valid pod name" {
  result=$(recovery_fix_force_primary "mongodb" "mongodb-0" "user" "pass")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "success" ]
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
  printf '%s' "$(_d "$result")" | grep -q '"reached_running":true'
  printf '%s' "$(_d "$result")" | grep -q '"partition_restored":3'
}

@test "recovery_recover aborts at gates when init container is missing (no wipe applied)" {
  export MOCK_HAS_INIT_CONTAINER=0
  result=$(recovery_recover "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "3" "30") || true
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  phase=$(printf '%s' "$(_d "$result")" | grep -o '"phase":"[^"]*"' | head -1 | cut -d'"' -f4)
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
  printf '%s' "$(_d "$result")" | grep -q '"next_step"'
}

@test "recovery_recover result includes sync_source_set field" {
  result=$(recovery_recover "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "3" "30")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "success" ]
  printf '%s' "$(_d "$result")" | grep -q '"sync_source_set"'
}

@test "recovery_recover succeeds even when replSetSyncFrom fails (non-fatal)" {
  export MOCK_SYNCFROM_FAIL=1
  result=$(recovery_recover "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "3" "30")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "success" ]
  sync_set=$(printf '%s' "$(_d "$result")" | grep -o '"sync_source_set":[a-z]*' | cut -d':' -f2)
  [ "$sync_set" = "false" ]
}

# ── G3 ────────────────────────────────────────────────────────────────────────

@test "G3 passes when primary exists and healthy secondary is available" {
  out=$(_recovery_gate_g3 "mongodb" "mongodb-2" "user" "pass")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "true" ]
  [ -z "$code" ]
}

@test "G3 fails NO_PRIMARY when healthy secondary exists but no primary is elected" {
  export MOCK_PRIMARY_POD="__none__"
  out=$(_recovery_gate_g3 "mongodb" "mongodb-2" "user" "pass") || true
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "false" ]
  [ "$code" = "NO_PRIMARY" ]
}

@test "G3 fails NO_HEALTHY_SOURCE when all non-target pods are non-Running" {
  export MOCK_ALL_PODS_PHASE="Terminating"
  out=$(_recovery_gate_g3 "mongodb" "mongodb-2" "user" "pass") || true
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "false" ]
  [ "$code" = "NO_HEALTHY_SOURCE" ]
}

# ── G6 ────────────────────────────────────────────────────────────────────────

@test "G6 passes when PVC available space exceeds requirement (data x 1.2)" {
  export MOCK_DATA_MB=1024
  export MOCK_AVAIL_MB=2000   # 2000 >= 1024*1.2=1229
  out=$(_recovery_gate_g6 "mongodb" "mongodb-2" "1024")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
}

@test "G6 fails INSUFFICIENT_PVC_SPACE when available space is below requirement" {
  export MOCK_DATA_MB=1024
  export MOCK_AVAIL_MB=1000   # 1000 < 1024*1.2=1229
  out=$(_recovery_gate_g6 "mongodb" "mongodb-2" "1024") || true
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "false" ]
  [ "$code" = "INSUFFICIENT_PVC_SPACE" ]
}

@test "G6 passes with warn when available space cannot be determined" {
  export MOCK_AVAIL_MB=0
  out=$(_recovery_gate_g6 "mongodb" "mongodb-2" "1024")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  warn=$(printf '%s' "$out" | grep -o '"warn":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
  [ "$warn" = "true" ]
}

# ── Standard mongo:N paths (non-Bitnami) ─────────────────────────────────────
#
# The recovery library defaults to Bitnami paths (/bitnami/mongodb/data/db).
# These tests verify the gates work correctly when the env-var overrides are
# set to the standard mongo:N paths (/data/db) used by this repo's manifests.

@test "G5 passes with standard /data/db data path override" {
  _RECOVERY_DATA_PATH="/data/db"
  export MOCK_DATA_MB=20480
  out=$(_recovery_gate_g5 "mongodb" "mongodb-2")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  data_mb=$(printf '%s' "$out" | grep -o '"data_mb":[0-9]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
  [ "$data_mb" = "20480" ]
}

@test "G5 blocks DATA_TOO_LARGE with /data/db path when size exceeds 100GB" {
  _RECOVERY_DATA_PATH="/data/db"
  export MOCK_DATA_MB=110000
  export FORCE_WIPE=false
  out=$(_recovery_gate_g5 "mongodb" "mongodb-2") || true
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "false" ]
  [ "$code" = "DATA_TOO_LARGE" ]
}

@test "G5 degrades with warn when du returns 0 (wrong path silently empty)" {
  _RECOVERY_DATA_PATH="/data/db"
  export MOCK_DATA_MB=0
  out=$(_recovery_gate_g5 "mongodb" "mongodb-2")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  warn=$(printf '%s' "$out" | grep -o '"warn":[a-z]*' | cut -d':' -f2)
  data_mb=$(printf '%s' "$out" | grep -o '"data_mb":[0-9]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
  [ "$warn" = "true" ]
  [ "$data_mb" = "0" ]
}

@test "G6 passes with standard /data/db mount path override" {
  _RECOVERY_MOUNT_PATH="/data/db"
  export MOCK_AVAIL_MB=5000
  out=$(_recovery_gate_g6 "mongodb" "mongodb-2" "1024")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
}

@test "G6 blocks INSUFFICIENT_PVC_SPACE with /data/db mount path override" {
  _RECOVERY_MOUNT_PATH="/data/db"
  export MOCK_AVAIL_MB=500   # 500 < 1024*1.2=1229
  out=$(_recovery_gate_g6 "mongodb" "mongodb-2" "1024") || true
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "false" ]
  [ "$code" = "INSUFFICIENT_PVC_SPACE" ]
}

@test "G5 warns with data_mb=0 when Bitnami patch applied but task uses /data/db (path mismatch)" {
  # Scenario: operator applied the Bitnami One-Time Setup patch (init container
  # wipes /bitnami/mongodb/data/db) but calls recovery with data_path=/data/db.
  # du /data/db hits an empty or absent directory → returns 0 → G5 silently
  # degrades to warn instead of blocking.  This documents the failure mode so
  # callers know to match data_path to the init container wipe path.
  _RECOVERY_DATA_PATH="/data/db"
  export MOCK_DATA_MB=0
  out=$(_recovery_gate_g5 "mongodb" "mongodb-2")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  warn=$(printf '%s' "$out" | grep -o '"warn":[a-z]*' | cut -d':' -f2)
  data_mb=$(printf '%s' "$out" | grep -o '"data_mb":[0-9]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
  [ "$warn" = "true" ]
  [ "$data_mb" = "0" ]
}

@test "recovery_run_gates passes in report mode with non-Bitnami path overrides" {
  _RECOVERY_DATA_PATH="/data/db"
  _RECOVERY_MOUNT_PATH="/data/db"
  result=$(recovery_run_gates "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "report")
  fail_count=$(printf '%s' "$(_d "$result")" | grep -o '"fail":[0-9]*' | head -1 | cut -d':' -f2)
  g1_pass=$(printf '%s' "$(_d "$result")" | grep -o '"gate":"G1"[^}]*"pass":[a-z]*' | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  g2_pass=$(printf '%s' "$(_d "$result")" | grep -o '"gate":"G2"[^}]*"pass":[a-z]*' | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  [ "${fail_count:-1}" = "0" ]
  [ "$g1_pass" = "true" ]
  [ "$g2_pass" = "true" ]
}

# ── G8 ────────────────────────────────────────────────────────────────────────

@test "G8 passes with no warn when no members are in RECOVERING state" {
  export MOCK_RECOVERING_MEMBER=""
  out=$(_recovery_gate_g8 "mongodb" "user" "pass")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  warn=$(printf '%s' "$out" | grep -o '"warn":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
  [ -z "$warn" ]
}

@test "G8 passes with warn when another member is in RECOVERING state" {
  export MOCK_RECOVERING_MEMBER="mongodb-2.mongodb.mongo-1.svc.cluster.local:27017"
  out=$(_recovery_gate_g8 "mongodb" "user" "pass")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  warn=$(printf '%s' "$out" | grep -o '"warn":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
  [ "$warn" = "true" ]
}

# ── recovery_set_sync_source ──────────────────────────────────────────────────

@test "set_sync_source picks secondary when primary and secondary both available" {
  # Default: mongodb-0=PRIMARY, mongodb-1/2=SECONDARY; target=mongodb-2
  result=$(recovery_set_sync_source "mongodb" "mongodb-2" "user" "pass")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  sync_type=$(printf '%s' "$(_d "$result")" | grep -o '"sync_source_type":"[^"]*"' | cut -d'"' -f4)
  [ "$status_val" = "success" ]
  [ "$sync_type" = "SECONDARY" ]
}

@test "set_sync_source falls back to primary when no secondary is available" {
  # Non-primary pods return UNKNOWN,0 so no secondary is found
  export MOCK_NON_PRIMARY_STATE="UNKNOWN,0"
  # target=mongodb-1 so mongodb-0(PRIMARY) and mongodb-2(UNKNOWN) are candidates
  result=$(recovery_set_sync_source "mongodb" "mongodb-1" "user" "pass")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  sync_type=$(printf '%s' "$(_d "$result")" | grep -o '"sync_source_type":"[^"]*"' | cut -d'"' -f4)
  [ "$status_val" = "success" ]
  [ "$sync_type" = "PRIMARY" ]
}

@test "set_sync_source returns error when no healthy source exists" {
  export MOCK_ALL_PODS_PHASE="Terminating"
  result=$(recovery_set_sync_source "mongodb" "mongodb-2" "user" "pass") || true
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "error" ]
}

@test "set_sync_source result includes sync_source_type and sync_host fields" {
  result=$(recovery_set_sync_source "mongodb" "mongodb-2" "user" "pass")
  printf '%s' "$(_d "$result")" | grep -q '"sync_source_type"'
  printf '%s' "$(_d "$result")" | grep -q '"sync_host"'
  sync_host=$(printf '%s' "$(_d "$result")" | grep -o '"sync_host":"[^"]*"' | cut -d'"' -f4)
  # host must contain a port
  printf '%s' "$sync_host" | grep -q ':27017'
}

@test "set_sync_source returns error when replSetSyncFrom fails after retries" {
  export MOCK_SYNCFROM_FAIL=1
  result=$(recovery_set_sync_source "mongodb" "mongodb-2" "user" "pass") || true
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "error" ]
}

# ── recovery_fix_diagnose (additional scenarios) ──────────────────────────────

@test "fix_diagnose reports ALL_SECONDARY_NO_PRIMARY when no primary is elected" {
  export MOCK_PRIMARY_POD="__none__"
  result=$(recovery_fix_diagnose "mongodb" "user" "pass")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  diagnosis=$(printf '%s' "$(_d "$result")" | grep -o '"diagnosis":"[^"]*"' | head -1 | cut -d'"' -f4)
  primary_count=$(printf '%s' "$(_d "$result")" | grep -o '"primary_count":[0-9]*' | head -1 | cut -d':' -f2)
  secondary_count=$(printf '%s' "$(_d "$result")" | grep -o '"secondary_count":[0-9]*' | head -1 | cut -d':' -f2)
  [ "$status_val" = "success" ]
  [ "$diagnosis" = "ALL_SECONDARY_NO_PRIMARY" ]
  [ "${primary_count:-1}" = "0" ]
  [ "${secondary_count:-0}" -ge "1" ]
}

@test "fix_diagnose reports NO_HEALTHY_MEMBERS when all pods are non-Running" {
  export MOCK_ALL_PODS_PHASE="CrashLoopBackOff"
  result=$(recovery_fix_diagnose "mongodb" "user" "pass")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  diagnosis=$(printf '%s' "$(_d "$result")" | grep -o '"diagnosis":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "success" ]
  [ "$diagnosis" = "NO_HEALTHY_MEMBERS" ]
}

# ── recovery_get_status ───────────────────────────────────────────────────────

@test "recovery_get_status returns sts and configmap_found fields" {
  result=$(recovery_get_status "mongodb" "mongodb-recovery-config")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  sts=$(printf '%s' "$(_d "$result")" | grep -o '"sts":"[^"]*"' | head -1 | cut -d'"' -f4)
  cm_found=$(printf '%s' "$(_d "$result")" | grep -o '"configmap_found":[a-z]*' | cut -d':' -f2)
  [ "$status_val" = "success" ]
  [ "$sts" = "mongodb" ]
  [ "$cm_found" = "true" ]
}

@test "recovery_get_status returns active_recovery false when wipe-targets is empty" {
  export MOCK_WIPE_TARGETS=""
  result=$(recovery_get_status "mongodb" "mongodb-recovery-config")
  active=$(printf '%s' "$(_d "$result")" | grep -o '"active_recovery":[a-z]*' | cut -d':' -f2)
  [ "$active" = "false" ]
}

@test "recovery_get_status returns active_recovery true when wipe-targets is set" {
  export MOCK_WIPE_TARGETS="mongodb-2"
  result=$(recovery_get_status "mongodb" "mongodb-recovery-config")
  active=$(printf '%s' "$(_d "$result")" | grep -o '"active_recovery":[a-z]*' | cut -d':' -f2)
  [ "$active" = "true" ]
}

@test "recovery_get_status returns pods array with phase info" {
  result=$(recovery_get_status "mongodb" "mongodb-recovery-config")
  pods=$(printf '%s' "$(_d "$result")" | grep -o '"pods":\[.*\]' | head -1)
  [ -n "$pods" ]
  # should include at least one pod entry with phase
  printf '%s' "$pods" | grep -q '"phase"'
}

# ── Cross-cluster RS: primary in cluster A, all local pods SECONDARY (SSS) ───
#
# These tests cover the real-world topology: cluster A = PSS, cluster B = SSS.
# When a secondary in cluster B breaks, G3/G4 must NOT block recovery — the RS
# primary is reachable across clusters even though no local pod is PRIMARY.

@test "G3 passes in cross-cluster RS: primary in cluster A, local pods all SECONDARY" {
  export MOCK_CROSS_CLUSTER_PRIMARY=1
  out=$(_recovery_gate_g3 "mongodb" "mongodb-2" "user" "pass")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "true" ]
  [ -z "$code" ]
}

@test "G3 still fails NO_PRIMARY when no primary exists anywhere (cross-cluster aware)" {
  export MOCK_CROSS_CLUSTER_PRIMARY=0
  export MOCK_PRIMARY_POD="__none__"
  out=$(_recovery_gate_g3 "mongodb" "mongodb-2" "user" "pass") || true
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "false" ]
  [ "$code" = "NO_PRIMARY" ]
}

@test "G4 passes in cross-cluster RS: oplog queried via probe pod to cluster A primary" {
  export MOCK_CROSS_CLUSTER_PRIMARY=1
  export MOCK_OPLOG_VERDICT=ok
  out=$(_recovery_gate_g4 "mongodb" "user" "pass" "1024")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
}

@test "G4 auto-resizes via cross-cluster primary when oplog is too small" {
  export MOCK_CROSS_CLUSTER_PRIMARY=1
  export MOCK_OPLOG_VERDICT=resize
  out=$(_recovery_gate_g4 "mongodb" "user" "pass" "10240")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  warn=$(printf '%s' "$out" | grep -o '"warn":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
  [ "$warn" = "true" ]
}

@test "G4 fails NO_PRIMARY_FOR_OPLOG when no primary in RS (cross-cluster aware)" {
  export MOCK_CROSS_CLUSTER_PRIMARY=0
  export MOCK_PRIMARY_POD="__none__"
  out=$(_recovery_gate_g4 "mongodb" "user" "pass" "1024") || true
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  code=$(printf '%s' "$out" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
  [ "$pass" = "false" ]
  [ "$code" = "NO_PRIMARY_FOR_OPLOG" ]
}

@test "G8 passes in cross-cluster RS: RECOVERING check goes via cluster A primary" {
  export MOCK_CROSS_CLUSTER_PRIMARY=1
  export MOCK_RECOVERING_MEMBER=""
  out=$(_recovery_gate_g8 "mongodb" "user" "pass")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
}

@test "G8 warns in cross-cluster RS when another member is RECOVERING" {
  export MOCK_CROSS_CLUSTER_PRIMARY=1
  export MOCK_RECOVERING_MEMBER="cluster-a-secondary-1:27017"
  out=$(_recovery_gate_g8 "mongodb" "user" "pass")
  pass=$(printf '%s' "$out" | grep -o '"pass":[a-z]*' | cut -d':' -f2)
  warn=$(printf '%s' "$out" | grep -o '"warn":[a-z]*' | cut -d':' -f2)
  [ "$pass" = "true" ]
  [ "$warn" = "true" ]
}

@test "recovery_run_gates passes in gate mode for cross-cluster RS (primary in A, secondary target in B)" {
  export MOCK_CROSS_CLUSTER_PRIMARY=1
  result=$(recovery_run_gates "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "gate")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  fail_count=$(printf '%s' "$(_d "$result")" | grep -o '"fail":[0-9]*' | head -1 | cut -d':' -f2)
  [ "$status_val" = "success" ]
  [ "${fail_count:-1}" = "0" ]
}

@test "recovery_recover completes full flow in cross-cluster RS (primary in cluster A)" {
  export MOCK_CROSS_CLUSTER_PRIMARY=1
  result=$(recovery_recover "mongodb" "mongodb-2" "mongodb-recovery-config" "user" "pass" "3" "30")
  status_val=$(printf '%s' "$result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$status_val" = "success" ]
  printf '%s' "$(_d "$result")" | grep -q '"reached_running":true'
  printf '%s' "$(_d "$result")" | grep -q '"partition_restored":3'
}
