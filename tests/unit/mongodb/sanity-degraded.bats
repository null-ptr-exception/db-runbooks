#!/usr/bin/env bats
# =============================================================================
# Degraded-cluster branch coverage for the MongoDB sanity-check layers.
#
# The e2e suite only exercises the healthy path (every sub-check passes), so
# the warn/fail branches — exactly where the log_warn regression hid — had no
# coverage. These tests source the real check functions and stub the
# data-source wrappers (mongo_*, k8s_*, _kubectl, _mongosh_eval) to simulate
# specific degradations, then assert the SC_PASS/SC_WARN/SC_FAIL counters.
#
# Strategy: a fully-healthy baseline (test 1 pins SC_WARN=0 SC_FAIL=0), then
# each test perturbs exactly ONE signal and asserts the delta.
# =============================================================================

setup() {
  LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../../../aqsh-tasks/lib" && pwd)"
  export _LOG_CURRENT_LEVEL=4
  # shellcheck disable=SC1091
  source "$LIB_DIR/logging.sh"
  # shellcheck disable=SC1091
  source "$LIB_DIR/response.sh"
  # shellcheck disable=SC1091
  source "$LIB_DIR/k8s.sh"
  # shellcheck disable=SC1091
  source "$LIB_DIR/mongodb.sh"
  # shellcheck disable=SC1091
  source "$LIB_DIR/mongodb_constant.sh"
  # shellcheck disable=SC1091
  source "$LIB_DIR/custom.sh"

  export K8S_NAMESPACE="mongo-1"
  export STS_NAME="mongodb"

  # ── healthy baseline stubs (each test overrides one) ─────────────────────

  # Layer 2
  mongo_check() { response_ok "mongo_check" "MongoDB connection successful" '{}'; }

  # Layer 3 — connections 5% used, empty lock queue
  mongo_server_status() {
    response_ok "mongo_server_status" "ok" \
      '{"connections":{"current":5,"available":95},"globalLock":{"currentQueue":{"total":0,"readers":0,"writers":0}}}'
  }
  mongo_rs_status() {
    response_ok "mongo_rs_status" "ok" \
      '{"set":"rs0","members":[{"name":"mongodb-0:27017","stateStr":"PRIMARY"},{"name":"mongodb-1:27017","stateStr":"SECONDARY"},{"name":"mongodb-2:27017","stateStr":"SECONDARY"}],"ok":1}'
  }
  mongo_rs_lag() {
    response_ok "mongo_rs_lag" "ok" \
      '{"members":[{"member":"mongodb-0:27017","stateStr":"PRIMARY","lagSeconds":null},{"member":"mongodb-1:27017","stateStr":"SECONDARY","lagSeconds":0},{"member":"mongodb-2:27017","stateStr":"SECONDARY","lagSeconds":1}]}'
  }
  mongo_oplog_status() {
    response_ok "mongo_oplog_status" "ok" \
      '{"sizeMB":990,"usedMB":10,"windowSeconds":432000,"windowHours":120,"windowDays":5}'
  }
  mongo_current_op() {
    response_ok "mongo_current_op" "ok" '{"inprog":[]}'
  }
  # only caller inside check_mongo_internals is the WiredTiger probe
  _mongosh_eval() {
    printf '{"maxMB":1024,"inUseMB":100,"dirtyMB":20,"usePct":10,"dirtyPct":2}\n'
  }

  # Layer 1
  k8s_check() { response_ok "k8s_check" "Cluster is reachable" '{}'; }
  k8s_get_nodes() {
    response_ok "k8s_get_nodes" "ok" '{"raw":{"items":[{"name":"node-1"}]}}'
  }
  k8s_sts_all_pods_ready() {
    response_ok "k8s_sts_all_pods_ready" "ok" '{"desired":3,"ready":3,"allReady":true}'
  }
  k8s_sts_pod_names() {
    response_ok "k8s_sts_pod_names" "ok" '{"pods":["mongodb-0"]}'
  }
  k8s_check_pvc_usage() {
    response_ok "k8s_check_pvc_usage" "ok" '{"used_percent":40,"warn":false}'
  }
  _kubectl() {
    case "$*" in
      "get node node-1 -o json")
        printf '{"status":{"conditions":[{"type":"Ready","status":"True"},{"type":"MemoryPressure","status":"False"},{"type":"DiskPressure","status":"False"},{"type":"PIDPressure","status":"False"}]}}\n'
        ;;
      "get pods -o json")
        printf '{"items":[{"metadata":{"name":"mongodb-0","ownerReferences":[{"kind":"StatefulSet","name":"mongodb"}]}}]}\n'
        ;;
      "get pod mongodb-0 -o json")
        printf '{"status":{"conditions":[{"type":"PodScheduled","status":"True"},{"type":"ContainersReady","status":"True"}],"containerStatuses":[{"restartCount":%s}]}}\n' \
          "${MOCK_RESTART_COUNT:-0}"
        ;;
      "get events --field-selector type=Warning"*)
        printf '%s' "${MOCK_WARNING_EVENTS:-}"
        ;;
      *)
        return 1
        ;;
    esac
  }
}

# ── baseline sanity of the harness itself ────────────────────────────────────

@test "healthy baseline: all three layers produce zero warn and zero fail" {
  check_k8s_layer || true
  check_mongo_connectivity || true
  check_mongo_internals || true
  echo "pass=$SC_PASS warn=$SC_WARN fail=$SC_FAIL" >&2
  [ "$SC_FAIL" -eq 0 ]
  [ "$SC_WARN" -eq 0 ]
  [ "$SC_PASS" -gt 0 ]
}

# ── Layer 2: connectivity ────────────────────────────────────────────────────

@test "L2 fail: mongo_check error makes connectivity a critical finding" {
  mongo_check() { response_err "mongo_check" "Cannot connect to MongoDB" '{}' 1; }
  run_rc=0; check_mongo_connectivity || run_rc=$?
  [ "$run_rc" -ne 0 ]
  [ "$SC_FAIL" -eq 1 ]
}

# ── Layer 3: replica-set member states ───────────────────────────────────────

@test "L3 warn: RECOVERING member is transitional, not critical" {
  mongo_rs_status() {
    response_ok "mongo_rs_status" "ok" \
      '{"set":"rs0","members":[{"name":"mongodb-0:27017","stateStr":"PRIMARY"},{"name":"mongodb-1:27017","stateStr":"SECONDARY"},{"name":"mongodb-2:27017","stateStr":"RECOVERING"}],"ok":1}'
  }
  check_mongo_internals || true
  [ "$SC_FAIL" -eq 0 ]
  [ "$SC_WARN" -eq 1 ]
}

@test "L3 fail: unreachable member (DOWN / not reachable) is critical" {
  mongo_rs_status() {
    response_ok "mongo_rs_status" "ok" \
      '{"set":"rs0","members":[{"name":"mongodb-0:27017","stateStr":"PRIMARY"},{"name":"mongodb-1:27017","stateStr":"SECONDARY"},{"name":"mongodb-2:27017","stateStr":"(not reachable/healthy)"}],"ok":1}'
  }
  check_mongo_internals || true
  [ "$SC_FAIL" -eq 1 ]
}

# ── Layer 3: replication lag ─────────────────────────────────────────────────

@test "L3 warn: lag between warn and crit thresholds" {
  mongo_rs_lag() {
    response_ok "mongo_rs_lag" "ok" \
      '{"members":[{"member":"mongodb-0:27017","stateStr":"PRIMARY","lagSeconds":null},{"member":"mongodb-1:27017","stateStr":"SECONDARY","lagSeconds":30}]}'
  }
  check_mongo_internals || true
  [ "$SC_FAIL" -eq 0 ]
  [ "$SC_WARN" -eq 1 ]
}

@test "L3 fail: lag at or above the critical threshold" {
  mongo_rs_lag() {
    response_ok "mongo_rs_lag" "ok" \
      '{"members":[{"member":"mongodb-0:27017","stateStr":"PRIMARY","lagSeconds":null},{"member":"mongodb-1:27017","stateStr":"SECONDARY","lagSeconds":75}]}'
  }
  check_mongo_internals || true
  [ "$SC_FAIL" -eq 1 ]
}

# ── Layer 3: oplog window ────────────────────────────────────────────────────

@test "L3 fail: oplog window below the critical minimum" {
  mongo_oplog_status() {
    response_ok "mongo_oplog_status" "ok" \
      '{"sizeMB":100,"usedMB":99,"windowSeconds":3600,"windowHours":1,"windowDays":0.04}'
  }
  check_mongo_internals || true
  [ "$SC_FAIL" -eq 1 ]
}

@test "L3 warn: oplog window below recommended but above critical" {
  mongo_oplog_status() {
    response_ok "mongo_oplog_status" "ok" \
      '{"sizeMB":100,"usedMB":50,"windowSeconds":172800,"windowHours":48,"windowDays":2}'
  }
  check_mongo_internals || true
  [ "$SC_FAIL" -eq 0 ]
  [ "$SC_WARN" -eq 1 ]
}

# ── Layer 3: server resources ────────────────────────────────────────────────

@test "L3 fail: connection utilisation at critical threshold" {
  mongo_server_status() {
    response_ok "mongo_server_status" "ok" \
      '{"connections":{"current":95,"available":5},"globalLock":{"currentQueue":{"total":0,"readers":0,"writers":0}}}'
  }
  check_mongo_internals || true
  [ "$SC_FAIL" -eq 1 ]
}

@test "L3 fail: WiredTiger dirty cache at critical threshold" {
  _mongosh_eval() {
    printf '{"maxMB":1024,"inUseMB":1000,"dirtyMB":983,"usePct":98,"dirtyPct":96}\n'
  }
  check_mongo_internals || true
  [ "$SC_FAIL" -eq 1 ]
}

@test "L3 fail: global lock queue above the fail threshold" {
  mongo_server_status() {
    response_ok "mongo_server_status" "ok" \
      '{"connections":{"current":5,"available":95},"globalLock":{"currentQueue":{"total":15,"readers":7,"writers":8}}}'
  }
  check_mongo_internals || true
  [ "$SC_FAIL" -eq 1 ]
}

@test "L3 warn: long-running operations present" {
  mongo_current_op() {
    response_ok "mongo_current_op" "ok" '{"inprog":[{"opid":101},{"opid":102}]}'
  }
  check_mongo_internals || true
  [ "$SC_FAIL" -eq 0 ]
  [ "$SC_WARN" -eq 1 ]
}

@test "L3 warn: standalone node (no replica set) is flagged, not failed" {
  mongo_rs_status() {
    response_ok "mongo_rs_status" "not a replica set" '{"ok":0,"errmsg":"not running with --replSet"}'
  }
  check_mongo_internals || true
  [ "$SC_FAIL" -eq 0 ]
  # standalone warn replaces the three RS sub-checks (health/lag/oplog)
  [ "$SC_WARN" -eq 1 ]
}

# ── Layer 1: kubernetes infrastructure ───────────────────────────────────────

@test "L1 fail: StatefulSet with unready pods is critical" {
  k8s_sts_all_pods_ready() {
    response_ok "k8s_sts_all_pods_ready" "ok" '{"desired":3,"ready":2,"allReady":false}'
  }
  check_k8s_layer || true
  [ "$SC_FAIL" -eq 1 ]
}

@test "L1 fail: NotReady node is critical" {
  # keep the healthy stub for everything except the node query
  eval "$(declare -f _kubectl | sed 's/^_kubectl/_kubectl_healthy/')"
  _kubectl() {
    if [[ "$*" == "get node node-1 -o json" ]]; then
      printf '{"status":{"conditions":[{"type":"Ready","status":"False"},{"type":"MemoryPressure","status":"False"},{"type":"DiskPressure","status":"False"},{"type":"PIDPressure","status":"False"}]}}\n'
      return 0
    fi
    _kubectl_healthy "$@"
  }
  check_k8s_layer || true
  [ "$SC_FAIL" -eq 1 ]
}

@test "L1 warn: high pod restart count" {
  export MOCK_RESTART_COUNT=7
  check_k8s_layer || true
  [ "$SC_FAIL" -eq 0 ]
  [ "$SC_WARN" -eq 1 ]
}

@test "L1 fail: PVC usage at critical threshold" {
  k8s_check_pvc_usage() {
    response_ok "k8s_check_pvc_usage" "ok" '{"used_percent":93,"warn":true}'
  }
  check_k8s_layer || true
  [ "$SC_FAIL" -eq 1 ]
}

@test "L1 warn: namespace has Warning events" {
  export MOCK_WARNING_EVENTS=$'BackOff: restarting failed container [3x] (mongodb-2)\nFailedScheduling: insufficient memory [1x] (mongodb-1)\n'
  check_k8s_layer || true
  [ "$SC_FAIL" -eq 0 ]
  [ "$SC_WARN" -eq 1 ]
}
