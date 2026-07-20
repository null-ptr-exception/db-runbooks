#!/usr/bin/env bats
#
# Contract tests for mariadb/switch-primary.sh against a stateful mock kubectl
# (no cluster). Lock down the guards (capability probe, replication/replicas,
# target validation, bounded lag pre-check), dry_run/confirm, fence + GTID drain,
# the happy switch, and the stuck -> rollback/recover ladder.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/switch-primary.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"
  MOCK_DIR="$(mktemp -d)"
  RESULT="${MOCK_DIR}/result.json"
  STATE="${MOCK_DIR}/primary_index"        # the "effective" current primary index
  DESIRED_STATE="${MOCK_DIR}/desired_primary_index"
  READ_ONLY_STATE="${MOCK_DIR}/read_only"
  OP_LOG="${MOCK_DIR}/operations.log"

  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
# stateful mock: STATE file holds the current primary podIndex.
args="$*"; verb=""
for a in "$@"; do case "$a" in explain|get|patch|delete|exec) verb="$a"; break;; esac; done
state() { cat "$MOCK_STATE" 2>/dev/null || printf '%s' "${MOCK_PRIMARY_INDEX:-0}"; }
printf '%s\n' "$verb $args" >> "$MOCK_OP_LOG"
case "$verb" in
  explain) [[ "${MOCK_NO_SWITCH_FIELD:-0}" == "1" ]] && exit 1 || exit 0 ;;
  get)
    case "$args" in
      *metadata.name*) printf '%s' "${MOCK_SOURCES:-mariadb}"; exit 0 ;;   # autodetect list
      *"jsonpath="*currentPrimary*) s="$(state)"; [[ "$s" == "stuck" ]] && s="${MOCK_PRIMARY_INDEX:-0}"; printf 'mariadb-%s' "$s"; exit 0 ;;
      *"-o json"*)
        s="$(state)"; ready="True"; idx="$s"
        if [[ "$s" == "stuck" ]]; then idx="${MOCK_PRIMARY_INDEX:-0}"; ready="False"; fi
        # MOCK_LEGACY=1 emulates the mmontes-era operator: it publishes
        # currentPrimary/currentPrimaryPodIndex but NEVER status.replication, so
        # the script must fall back to SHOW ALL SLAVES STATUS over `exec` (below).
        if [[ "${MOCK_LEGACY:-0}" == "1" ]]; then
          desired="$(cat "$MOCK_DESIRED_STATE" 2>/dev/null || printf '%s' "$idx")"
          jq -n --argjson idx "$idx" --argjson desired "$desired" \
            --arg enabled "${MOCK_REPL_ENABLED:-true}" \
            --argjson replicas "${MOCK_REPLICAS:-3}" \
            --arg ready "$ready" \
            '{
              metadata: {resourceVersion: "1"},
              spec: {replicas: $replicas, replication: {enabled: ($enabled=="true"), primary: {podIndex: $desired}}},
              status: {
                currentPrimary: ("mariadb-" + ($idx|tostring)),
                currentPrimaryPodIndex: $idx,
                conditions: [{type:"Ready", status:$ready}]
              }
            }'; exit 0
        fi
        desired="$(cat "$MOCK_DESIRED_STATE" 2>/dev/null || printf '%s' "$idx")"
        jq -n --argjson idx "$idx" --argjson desired "$desired" \
          --arg enabled "${MOCK_REPL_ENABLED:-true}" \
          --argjson replicas "${MOCK_REPLICAS:-3}" \
          --argjson lag "${MOCK_LAG:-0}" \
          --arg ready "$ready" \
          '{
            metadata: {resourceVersion: "1"},
            spec: {replicas: $replicas, replication: {enabled: ($enabled=="true"), primary: {podIndex: $desired}}},
            status: {
              currentPrimary: ("mariadb-" + ($idx|tostring)),
              currentPrimaryPodIndex: $idx,
              conditions: [{type:"Ready", status:$ready}],
              replication: {replicas: {"mariadb-1": {slaveIORunning:true, slaveSQLRunning:true, secondsBehindMaster:$lag}}}
            }
          }'; exit 0 ;;
      *) echo "mock: unhandled get: $args" >&2; exit 1 ;;
    esac ;;
  exec)
    # kubectl exec <pod> -c <container> -- <cmd...>
    case "$args" in
      *"printenv MARIADB_ROOT_PASSWORD"*) printf '%s' "${MOCK_ROOT_PW:-test-pass}"; exit 0 ;;
      *"SET GLOBAL read_only = 1"*)
        [[ "${MOCK_FENCE_SET_FAIL:-0}" == "1" ]] && exit 1
        printf '1' > "$MOCK_READ_ONLY_STATE"; exit 0 ;;
      *"SET GLOBAL read_only = 0"*)
        [[ "${MOCK_FENCE_RELEASE_FAIL:-0}" == "1" ]] && exit 1
        printf '0' > "$MOCK_READ_ONLY_STATE"; exit 0 ;;
      *"SELECT @@global.read_only"*)
        cat "$MOCK_READ_ONLY_STATE" 2>/dev/null || printf '%s' "${MOCK_INITIAL_READ_ONLY:-0}"
        exit 0 ;;
      *"SELECT @@global.gtid_binlog_pos"*)
        [[ "${MOCK_GTID_QUERY_FAIL:-0}" == "1" ]] && exit 1
        printf '%s' "${MOCK_PRIMARY_GTID:-0-1-100}"; exit 0 ;;
      *"MASTER_GTID_WAIT"*)
        [[ -n "${MOCK_GTID_WAIT_SLEEP:-}" ]] && sleep "$MOCK_GTID_WAIT_SLEEP"
        result="${MOCK_GTID_WAIT_RESULT:-0}"
        case "$args" in
          *"exec mariadb-1 "*) result="${MOCK_GTID_WAIT_RESULT_1:-$result}" ;;
          *"exec mariadb-2 "*) result="${MOCK_GTID_WAIT_RESULT_2:-$result}" ;;
        esac
        [[ "$result" == "query-failed" ]] && exit 1
        printf '%s' "$result"; exit 0 ;;
      *"SHOW ALL SLAVES STATUS"*)
        [[ "${MOCK_LEGACY_QUERY_FAIL:-0}" == "1" ]] && exit 1
        [[ "${MOCK_LEGACY_EMPTY:-0}" == "1" ]] && exit 0
        # A caught-up replica by default. Per-pod knobs exercise mixed-health
        # fallback maps; the unnumbered knobs remain the default for every pod.
        io="${MOCK_LEGACY_IO:-Yes}"
        sql="${MOCK_LEGACY_SQL:-Yes}"
        lag="${MOCK_LEGACY_LAG:-0}"
        connection_name="${MOCK_LEGACY_CONNECTION_NAME:-legacy-primary}"
        case "$args" in
          *"exec mariadb-1 "*)
            io="${MOCK_LEGACY_IO_1:-$io}"
            sql="${MOCK_LEGACY_SQL_1:-$sql}"
            lag="${MOCK_LEGACY_LAG_1:-$lag}"
            ;;
          *"exec mariadb-2 "*)
            io="${MOCK_LEGACY_IO_2:-$io}"
            sql="${MOCK_LEGACY_SQL_2:-$sql}"
            lag="${MOCK_LEGACY_LAG_2:-$lag}"
            ;;
        esac
        printf '*************************** 1. row ***************************\n'
        printf '               Connection_name: %s\n' "$connection_name"
        printf '             Slave_IO_Running: %s\n' "$io"
        printf '            Slave_SQL_Running: %s\n' "$sql"
        printf '        Seconds_Behind_Master: %s\n' "$lag"
        if [[ "${MOCK_LEGACY_MULTIPLE:-0}" == "1" ]]; then
          printf '*************************** 2. row ***************************\n'
          printf '               Connection_name: legacy-secondary\n'
          printf '             Slave_IO_Running: Yes\n'
          printf '            Slave_SQL_Running: Yes\n'
          printf '        Seconds_Behind_Master: 0\n'
        fi
        exit 0 ;;
      *) echo "mock: unhandled exec: $args" >&2; exit 1 ;;
    esac ;;
  patch)
    [[ "${MOCK_PATCH_FAIL:-0}" == "1" ]] && exit 1
    n="$(printf '%s' "$args" | grep -oE '"value":[0-9]+' | grep -oE '[0-9]+' | tail -1)"
    orig="${MOCK_PRIMARY_INDEX:-0}"
    if [[ "$n" != "$orig" && -n "${MOCK_CONCURRENT_TARGET:-}" ]]; then
      printf '%s' "$MOCK_CONCURRENT_TARGET" > "$MOCK_DESIRED_STATE"
      exit 1
    fi
    [[ "$n" == "$orig" && "${MOCK_ROLLBACK_PATCH_FAIL:-0}" == "1" ]] && exit 1
    printf '%s' "$n" > "$MOCK_DESIRED_STATE"
    if [[ "$n" == "$orig" ]]; then                 # rollback to original
      [[ "${MOCK_ROLLBACK_RECOVERS:-1}" == "1" ]] && printf '%s' "$n" > "$MOCK_STATE"
    elif [[ "${MOCK_SWITCH_STUCK:-0}" == "1" ]]; then  # forward switch hangs (limbo)
      printf 'stuck' > "$MOCK_STATE"
    else                                           # forward switch succeeds
      printf '%s' "$n" > "$MOCK_STATE"
    fi
    exit 0 ;;
  delete) exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/kubectl"

  export DB_NAMESPACE="mariadb-1" MARIADB_NAME="mariadb"
  export MOCK_STATE="$STATE" MOCK_DESIRED_STATE="$DESIRED_STATE"
  export MOCK_READ_ONLY_STATE="$READ_ONLY_STATE" MOCK_OP_LOG="$OP_LOG"
  export SWITCH_POLL_INTERVAL="0.05"
}

teardown() { rm -rf "${MOCK_DIR}"; }

run_switch() {
  printf '%s' "${MOCK_PRIMARY_INDEX:-0}" > "$STATE"
  printf '%s' "${MOCK_PRIMARY_INDEX:-0}" > "$DESIRED_STATE"
  printf '%s' "${MOCK_INITIAL_READ_ONLY:-0}" > "$READ_ONLY_STATE"
  : > "$OP_LOG"
  run env "PATH=${MOCK_DIR}:${PATH}" "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" "$@" bash "${SCRIPT}"
}
field() { jq -r "$1" "${RESULT}"; }

@test "switch-primary auto-selects a caught-up replica when target is omitted" {
  run_switch DRY_RUN=true    # no TARGET_POD_INDEX
  [ "$(field '.reason_code')" = "SWITCH_DRY_RUN" ]
  [ "$(field '.to_pod_index')" = "1" ]
  [ "$(field '.target_auto_selected')" = "true" ]
}

@test "switch-primary blocks when no eligible replica exists to auto-select" {
  run_switch DRY_RUN=true MOCK_LAG=30   # only replica is beyond the pre-fence limit
  [ "$(field '.reason_code')" = "NO_ELIGIBLE_REPLICA" ]
}

@test "switch-primary allows bounded non-zero lag before the authoritative GTID drain" {
  run_switch DRY_RUN=true MOCK_LAG=3
  [ "$(field '.reason_code')" = "SWITCH_DRY_RUN" ]
  [ "$(field '.to_pod_index')" = "1" ]
}

@test "switch-primary rejects a non-integer explicit target" {
  run_switch DRY_RUN=true TARGET_POD_INDEX=abc
  [ "$(field '.reason_code')" = "TARGET_INVALID" ]
}

@test "switch-primary blocks when the CRD lacks replication.primary.podIndex" {
  run_switch DRY_RUN=true TARGET_POD_INDEX=1 MOCK_NO_SWITCH_FIELD=1
  [ "$(field '.reason_code')" = "SWITCH_UNSUPPORTED" ]
}

@test "switch-primary blocks a non-replicated instance" {
  run_switch DRY_RUN=true TARGET_POD_INDEX=1 MOCK_REPL_ENABLED=false MOCK_REPLICAS=1
  [ "$(field '.reason_code')" = "NOT_REPLICATED" ]
}

@test "switch-primary rejects an out-of-range target" {
  run_switch DRY_RUN=true TARGET_POD_INDEX=9 MOCK_REPLICAS=3 MOCK_PRIMARY_INDEX=0
  [ "$(field '.reason_code')" = "TARGET_OUT_OF_RANGE" ]
}

@test "switch-primary is a no-op when target is already primary" {
  run_switch DRY_RUN=true TARGET_POD_INDEX=0 MOCK_PRIMARY_INDEX=0
  [ "$(field '.reason_code')" = "ALREADY_PRIMARY" ]
  [ "$(field '.status')" = "UNCHANGED" ]
}

@test "switch-primary blocks when replicas are lagging" {
  run_switch DRY_RUN=false CONFIRM=true TARGET_POD_INDEX=1 MOCK_PRIMARY_INDEX=0 MOCK_LAG=30
  [ "$(field '.reason_code')" = "REPLICAS_NOT_READY_TO_DRAIN" ]
}

@test "switch-primary dry_run shows the plan without patching" {
  run_switch DRY_RUN=true TARGET_POD_INDEX=1 MOCK_PRIMARY_INDEX=0
  [ "$(field '.reason_code')" = "SWITCH_DRY_RUN" ]
  [ "$(field '.from_pod_index')" = "0" ]
  [ "$(field '.to_pod_index')" = "1" ]
}

@test "switch-primary requires confirm to apply" {
  run_switch DRY_RUN=false CONFIRM=false TARGET_POD_INDEX=1 MOCK_PRIMARY_INDEX=0
  [ "$(field '.reason_code')" = "SWITCH_CONFIRM_REQUIRED" ]
}

@test "switch-primary completes the switch on confirm" {
  run_switch DRY_RUN=false CONFIRM=true TARGET_POD_INDEX=1 MOCK_PRIMARY_INDEX=0
  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "CHANGED" ]
  [ "$(field '.reason_code')" = "PRIMARY_SWITCHED" ]
  [ "$(field '.to_pod_index')" = "1" ]
  [ "$(field '.fenced_gtid')" = "0-1-100" ]
  [ "$(field '.drain_results | length')" = "2" ]
  [ "$(cat "$READ_ONLY_STATE")" = "1" ] # operator owns the fence after patch
}

@test "switch-primary fences and drains every replica before patching desired state" {
  run_switch DRY_RUN=false CONFIRM=true TARGET_POD_INDEX=1 MOCK_PRIMARY_INDEX=0 MOCK_LAG=2
  [ "$status" -eq 0 ]
  fence_line="$(grep -n 'SET GLOBAL read_only = 1' "$OP_LOG" | head -1 | cut -d: -f1)"
  lock_line="$(grep -n 'FLUSH TABLES WITH READ LOCK' "$OP_LOG" | head -1 | cut -d: -f1)"
  gtid_line="$(grep -n 'SELECT @@global.gtid_binlog_pos' "$OP_LOG" | head -1 | cut -d: -f1)"
  wait1_line="$(grep -n 'exec mariadb-1 .*MASTER_GTID_WAIT' "$OP_LOG" | head -1 | cut -d: -f1)"
  wait2_line="$(grep -n 'exec mariadb-2 .*MASTER_GTID_WAIT' "$OP_LOG" | head -1 | cut -d: -f1)"
  patch_line="$(grep -n 'patch .*podIndex.*"value":1' "$OP_LOG" | head -1 | cut -d: -f1)"
  [ "$fence_line" -lt "$gtid_line" ]
  [ "$lock_line" -eq "$gtid_line" ]
  [ "$gtid_line" -lt "$wait1_line" ]
  [ "$wait1_line" -lt "$wait2_line" ]
  [ "$wait2_line" -lt "$patch_line" ]
}

@test "switch-primary restores writes and does not patch when a replica cannot drain" {
  run_switch DRY_RUN=false CONFIRM=true TARGET_POD_INDEX=1 MOCK_PRIMARY_INDEX=0 \
    MOCK_GTID_WAIT_RESULT_2=-1
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = "REPLICA_DRAIN_FAILED" ]
  [ "$(field '.fence_released')" = "true" ]
  [ "$(cat "$READ_ONLY_STATE")" = "0" ]
  ! grep -q 'patch .*podIndex' "$OP_LOG"
}

@test "switch-primary TERM trap restores writes before the CR handoff" {
  printf '%s' "0" > "$STATE"
  printf '%s' "0" > "$DESIRED_STATE"
  printf '%s' "0" > "$READ_ONLY_STATE"
  : > "$OP_LOG"
  env "PATH=${MOCK_DIR}:${PATH}" "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" DRY_RUN=false CONFIRM=true TARGET_POD_INDEX=1 \
    MOCK_GTID_WAIT_SLEEP=2 bash "$SCRIPT" >/dev/null 2>&1 &
  task_pid=$!
  deadline=$((SECONDS + 5))
  until grep -q 'MASTER_GTID_WAIT' "$OP_LOG" 2>/dev/null; do
    (( SECONDS < deadline )) || { kill "$task_pid" >/dev/null 2>&1 || true; false; }
    sleep 0.05
  done
  kill -TERM "$task_pid"
  rc=0
  wait "$task_pid" || rc=$?
  [ "$rc" -eq 143 ]
  [ "$(cat "$READ_ONLY_STATE")" = "0" ]
  ! grep -q 'patch .*podIndex' "$OP_LOG"
}

@test "switch-primary restores writes when the CR patch fails after drain" {
  run_switch DRY_RUN=false CONFIRM=true TARGET_POD_INDEX=1 MOCK_PRIMARY_INDEX=0 MOCK_PATCH_FAIL=1
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = "PATCH_FAILED" ]
  [ "$(field '.fence_released')" = "true" ]
  [ "$(cat "$READ_ONLY_STATE")" = "0" ]
}

@test "switch-primary does not overwrite a different concurrent target or release its fence" {
  run_switch DRY_RUN=false CONFIRM=true TARGET_POD_INDEX=1 MOCK_PRIMARY_INDEX=0 \
    MOCK_CONCURRENT_TARGET=2
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = "CONCURRENT_SWITCH_DETECTED" ]
  [ "$(field '.observed_desired_pod_index')" = "2" ]
  [ "$(field '.fence_released')" = "false" ]
  [ "$(cat "$READ_ONLY_STATE")" = "1" ]
  [ "$(cat "$DESIRED_STATE")" = "2" ]
}

@test "switch-primary reports a stuck fence when drain fails and writes cannot be restored" {
  run_switch DRY_RUN=false CONFIRM=true TARGET_POD_INDEX=1 MOCK_PRIMARY_INDEX=0 \
    MOCK_GTID_WAIT_RESULT_1=-1 MOCK_FENCE_RELEASE_FAIL=1
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = "PRIMARY_FENCE_STUCK" ]
  [ "$(field '.fence_released')" = "false" ]
  [ "$(cat "$READ_ONLY_STATE")" = "1" ]
}

@test "switch-primary blocks when the target is not a known replica" {
  # mock exposes only replica 'mariadb-1'; target 2 (in range for 3 replicas) is absent
  run_switch DRY_RUN=false CONFIRM=true TARGET_POD_INDEX=2 MOCK_PRIMARY_INDEX=0 MOCK_REPLICAS=3
  [ "$(field '.reason_code')" = "TARGET_NOT_A_REPLICA" ]
}

@test "switch-primary auto-rolls-back when the switch gets stuck" {
  run_switch DRY_RUN=false CONFIRM=true TARGET_POD_INDEX=1 MOCK_PRIMARY_INDEX=0 \
    WAIT_TIMEOUT=1 SWITCH_RECOVERY_TIMEOUT=1 MOCK_SWITCH_STUCK=1 MOCK_ROLLBACK_RECOVERS=1
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = "SWITCH_TIMEOUT_ROLLED_BACK" ]
  [ "$(field '.recovered')" = "true" ]
  [ "$(field '.fence_released')" = "true" ]
  [ "$(cat "$READ_ONLY_STATE")" = "0" ]
}

@test "switch-primary reports SWITCH_STUCK when rollback cannot recover and eviction is gated" {
  run_switch DRY_RUN=false CONFIRM=true TARGET_POD_INDEX=1 MOCK_PRIMARY_INDEX=0 \
    WAIT_TIMEOUT=1 SWITCH_RECOVERY_TIMEOUT=1 MOCK_SWITCH_STUCK=1 MOCK_ROLLBACK_RECOVERS=0 \
    MOCK_FENCE_RELEASE_FAIL=1
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = "SWITCH_STUCK" ]
  [ "$(field '.recovered')" = "false" ]
}

@test "switch-primary keeps operator fence ownership when rollback patch is unconfirmed" {
  run_switch DRY_RUN=false CONFIRM=true TARGET_POD_INDEX=1 MOCK_PRIMARY_INDEX=0 \
    WAIT_TIMEOUT=1 SWITCH_RECOVERY_TIMEOUT=1 MOCK_SWITCH_STUCK=1 MOCK_ROLLBACK_PATCH_FAIL=1
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = "SWITCH_STUCK" ]
  [ "$(field '.attempted | index("rollback-patch-unconfirmed") != null')" = "true" ]
  [ "$(cat "$READ_ONLY_STATE")" = "1" ]
}

# --- legacy operator (mmontes): no status.replication.replicas ---------------
# It publishes currentPrimaryPodIndex but not the per-replica health map, so the
# script falls back to live SHOW ALL SLAVES STATUS. These lock down that both the
# auto-select and Guard 4 paths keep working (and stay safe) on legacy.

@test "switch-primary (legacy) auto-selects a healthy named replication connection" {
  run_switch DRY_RUN=true MOCK_LEGACY=1 MOCK_PRIMARY_INDEX=0    # no target
  [ "$(field '.reason_code')" = "SWITCH_DRY_RUN" ]
  [ "$(field '.to_pod_index')" = "1" ]
  [ "$(field '.target_auto_selected')" = "true" ]
  [ "$(field '.replicas_source')" = "show_all_slaves_status" ]
}

@test "switch-primary (legacy) accepts an explicit healthy named target in dry-run" {
  run_switch DRY_RUN=true TARGET_POD_INDEX=1 MOCK_LEGACY=1 MOCK_PRIMARY_INDEX=0
  [ "$(field '.reason_code')" = "SWITCH_DRY_RUN" ]
  [ "$(field '.to_pod_index')" = "1" ]
  [ "$(field '.replicas_source')" = "show_all_slaves_status" ]
}

@test "switch-primary (legacy) picks the healthy replica before the strict mixed-health guard" {
  run_switch DRY_RUN=true MOCK_LEGACY=1 MOCK_PRIMARY_INDEX=0 \
    MOCK_LEGACY_LAG_1=0 MOCK_LEGACY_LAG_2=30
  # Auto-selection correctly ignores replica-2, but Guard 4 deliberately still
  # blocks the switch because the operator requires every replica caught up.
  [ "$(field '.reason_code')" = "REPLICAS_NOT_READY_TO_DRAIN" ]
  [ "$(field '.to_pod_index')" = "1" ]
  [ "$(field '.target_auto_selected')" = "true" ]
  [ "$(field '.replicas_source')" = "show_all_slaves_status" ]
  [ "$(field '.replicas["mariadb-1"].secondsBehindMaster')" = "0" ]
  [ "$(field '.replicas["mariadb-2"].secondsBehindMaster')" = "30" ]
}

@test "switch-primary (legacy) blocks auto-select when replicas lag" {
  run_switch DRY_RUN=true MOCK_LEGACY=1 MOCK_PRIMARY_INDEX=0 MOCK_LEGACY_LAG=30
  [ "$(field '.reason_code')" = "NO_ELIGIBLE_REPLICA" ]
  [ "$(field '.replicas["mariadb-1"].healthQuery.status')" = "ok" ]
}

@test "switch-primary (legacy) blocks auto-select when replication is broken" {
  run_switch DRY_RUN=true MOCK_LEGACY=1 MOCK_PRIMARY_INDEX=0 MOCK_LEGACY_IO=No
  [ "$(field '.reason_code')" = "NO_ELIGIBLE_REPLICA" ]
  [ "$(field '.replicas["mariadb-1"].slaveIORunning')" = "false" ]
  [ "$(field '.replicas["mariadb-1"].healthQuery.status')" = "ok" ]
}

@test "switch-primary (legacy) blocks when the SQL replication thread is stopped" {
  run_switch DRY_RUN=true MOCK_LEGACY=1 MOCK_PRIMARY_INDEX=0 MOCK_LEGACY_SQL=No
  [ "$(field '.reason_code')" = "NO_ELIGIBLE_REPLICA" ]
  [ "$(field '.replicas["mariadb-1"].slaveSQLRunning')" = "false" ]
  [ "$(field '.replicas["mariadb-1"].healthQuery.status')" = "ok" ]
}

@test "switch-primary (legacy) blocks and diagnoses an empty status result" {
  run_switch DRY_RUN=true MOCK_LEGACY=1 MOCK_PRIMARY_INDEX=0 MOCK_LEGACY_EMPTY=1
  [ "$(field '.reason_code')" = "NO_ELIGIBLE_REPLICA" ]
  [ "$(field '.replicas["mariadb-1"].slaveIORunning')" = "null" ]
  [ "$(field '.replicas["mariadb-1"].healthQuery.status')" = "query_empty" ]
}

@test "switch-primary (legacy) blocks and diagnoses a failed status query" {
  run_switch DRY_RUN=true MOCK_LEGACY=1 MOCK_PRIMARY_INDEX=0 MOCK_LEGACY_QUERY_FAIL=1
  [ "$(field '.reason_code')" = "NO_ELIGIBLE_REPLICA" ]
  [ "$(field '.replicas["mariadb-1"].slaveIORunning')" = "null" ]
  [ "$(field '.replicas["mariadb-1"].healthQuery.status')" = "query_failed" ]
}

@test "switch-primary (legacy) blocks instead of choosing the first of multiple connections" {
  run_switch DRY_RUN=true MOCK_LEGACY=1 MOCK_PRIMARY_INDEX=0 MOCK_LEGACY_MULTIPLE=1
  [ "$(field '.reason_code')" = "NO_ELIGIBLE_REPLICA" ]
  [ "$(field '.replicas["mariadb-1"].healthQuery.status')" = "multiple_connections" ]
  [ "$(field '.replicas["mariadb-1"].healthQuery.rowCount')" = "2" ]
}

@test "switch-primary (legacy) blocks when replication lag is unknown" {
  run_switch DRY_RUN=true MOCK_LEGACY=1 MOCK_PRIMARY_INDEX=0 MOCK_LEGACY_LAG=NULL
  [ "$(field '.reason_code')" = "NO_ELIGIBLE_REPLICA" ]
  [ "$(field '.replicas["mariadb-1"].secondsBehindMaster')" = "null" ]
}

@test "switch-primary (legacy) blocks an explicit target that is lagging" {
  run_switch DRY_RUN=false CONFIRM=true TARGET_POD_INDEX=1 MOCK_LEGACY=1 \
    MOCK_PRIMARY_INDEX=0 MOCK_LEGACY_LAG=30
  [ "$(field '.reason_code')" = "REPLICAS_NOT_READY_TO_DRAIN" ]
  [ "$(field '.replicas_source')" = "show_all_slaves_status" ]
}

@test "switch-primary (legacy) completes the switch on confirm" {
  run_switch DRY_RUN=false CONFIRM=true TARGET_POD_INDEX=1 MOCK_LEGACY=1 MOCK_PRIMARY_INDEX=0
  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "CHANGED" ]
  [ "$(field '.reason_code')" = "PRIMARY_SWITCHED" ]
  [ "$(field '.to_pod_index')" = "1" ]
}

@test "switch-primary (current gen) reports replicas_source=cr_status" {
  run_switch DRY_RUN=true TARGET_POD_INDEX=1 MOCK_PRIMARY_INDEX=0
  [ "$(field '.reason_code')" = "SWITCH_DRY_RUN" ]
  [ "$(field '.replicas_source')" = "cr_status" ]
}
