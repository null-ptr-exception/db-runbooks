#!/usr/bin/env bats
#
# Contract tests for mariadb/switch-primary.sh against a stateful mock kubectl
# (no cluster). Lock down the guards (capability probe, replication/replicas,
# target validation, strict lag pre-check), dry_run/confirm, the happy switch,
# and the stuck -> rollback/recover ladder.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/switch-primary.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"
  MOCK_DIR="$(mktemp -d)"
  RESULT="${MOCK_DIR}/result.json"
  STATE="${MOCK_DIR}/primary_index"        # the "effective" current primary index

  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
# stateful mock: STATE file holds the current primary podIndex.
args="$*"; verb=""
for a in "$@"; do case "$a" in explain|get|patch|delete) verb="$a"; break;; esac; done
state() { cat "$MOCK_STATE" 2>/dev/null || printf '%s' "${MOCK_PRIMARY_INDEX:-0}"; }
case "$verb" in
  explain) [[ "${MOCK_NO_SWITCH_FIELD:-0}" == "1" ]] && exit 1 || exit 0 ;;
  get)
    case "$args" in
      *metadata.name*) printf '%s' "${MOCK_SOURCES:-mariadb}"; exit 0 ;;   # autodetect list
      *"jsonpath="*currentPrimary*) s="$(state)"; [[ "$s" == "stuck" ]] && s="${MOCK_PRIMARY_INDEX:-0}"; printf 'mariadb-%s' "$s"; exit 0 ;;
      *"-o json"*)
        s="$(state)"; ready="True"; idx="$s"
        if [[ "$s" == "stuck" ]]; then idx="${MOCK_PRIMARY_INDEX:-0}"; ready="False"; fi
        jq -n --argjson idx "$idx" \
          --arg enabled "${MOCK_REPL_ENABLED:-true}" \
          --argjson replicas "${MOCK_REPLICAS:-3}" \
          --argjson lag "${MOCK_LAG:-0}" \
          --arg ready "$ready" \
          '{
            spec: {replicas: $replicas, replication: {enabled: ($enabled=="true")}},
            status: {
              currentPrimary: ("mariadb-" + ($idx|tostring)),
              currentPrimaryPodIndex: $idx,
              conditions: [{type:"Ready", status:$ready}],
              replication: {replicas: {"mariadb-1": {slaveIORunning:true, slaveSQLRunning:true, secondsBehindMaster:$lag}}}
            }
          }'; exit 0 ;;
      *) echo "mock: unhandled get: $args" >&2; exit 1 ;;
    esac ;;
  patch)
    n="$(printf '%s' "$args" | grep -oE 'podIndex":[0-9]+' | grep -oE '[0-9]+' | tail -1)"
    orig="${MOCK_PRIMARY_INDEX:-0}"
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
  export MOCK_STATE="$STATE"
  export SWITCH_POLL_INTERVAL="0.05"
}

teardown() { rm -rf "${MOCK_DIR}"; }

run_switch() {
  printf '%s' "${MOCK_PRIMARY_INDEX:-0}" > "$STATE"
  run env "PATH=${MOCK_DIR}:${PATH}" "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" "$@" bash "${SCRIPT}"
}
field() { jq -r "$1" "${RESULT}"; }

@test "switch-primary requires a target" {
  run_switch DRY_RUN=true
  [ "$(field '.reason_code')" = "TARGET_REQUIRED" ]
}

@test "switch-primary rejects a non-integer target" {
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
  [ "$(field '.reason_code')" = "REPLICAS_NOT_IN_SYNC" ]
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
}

@test "switch-primary reports SWITCH_STUCK when rollback cannot recover and eviction is gated" {
  run_switch DRY_RUN=false CONFIRM=true TARGET_POD_INDEX=1 MOCK_PRIMARY_INDEX=0 \
    WAIT_TIMEOUT=1 SWITCH_RECOVERY_TIMEOUT=1 MOCK_SWITCH_STUCK=1 MOCK_ROLLBACK_RECOVERS=0
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = "SWITCH_STUCK" ]
  [ "$(field '.recovered')" = "false" ]
}
