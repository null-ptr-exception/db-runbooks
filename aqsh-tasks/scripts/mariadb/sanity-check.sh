#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/sanity-check.sh
# Read-only MariaDB sanity check for AQSH, Rundeck, and local use.
#
# AQSH injects inputs as environment variables and reads $AQSH_RESULT_FILE.
# Rundeck/local users can pass the same values as CLI flags.
# =============================================================================

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi

# shellcheck source=../../lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=../../lib/response.sh
source "${LIB_DIR}/response.sh"
# shellcheck source=../../lib/k8s.sh
source "${LIB_DIR}/k8s.sh"
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  sanity-check.sh --namespace <namespace> [options]

Required:
  --namespace <namespace>          Kubernetes namespace.

Target options:
  --context <context>              Kubernetes context. Optional for in-cluster AQSH.
  --resource <kind>                MariaDB CR kind. Default: mariadb
  --mdb <name>                     MariaDB CR / StatefulSet name. Default: mariadb
  --container <name>               MariaDB container name. Default: mariadb

Thresholds:
  --lag-threshold <sec>            Replica lag BLOCK threshold. Default: 1
  --conn-warn-pct <pct>            Connection utilization WARN threshold. Default: 80
  --long-tx-threshold <sec>        Long transaction WARN threshold. Default: 10
  --expected-version <substring>   Optional @@version substring check.

Check toggles:
  --skip-operator                  Skip CR readiness / current primary checks.
  --skip-pods                      Skip pod Running / container ready checks.
  --skip-service                   Skip primary Service selector check.
  --skip-sql                       Skip primary SQL checks.
  --skip-replication               Skip replica replication checks.
  --skip-semi-sync                 Skip semi-sync checks.

Output:
  --json                           Print only JSON result to stdout.
  --result-file <path>             Write JSON result to this file.
  --strict-exit                    Exit 1 on BLOCK and 2 on ERROR.

Environment equivalents:
  DB_NAMESPACE, K8S_CONTEXT, MARIADB_RESOURCE, MARIADB_NAME,
  MARIADB_CONTAINER, LAG_THRESHOLD, CONN_WARN_PCT, LONG_TX_THRESHOLD,
  EXPECTED_VERSION, AQSH_RESULT_FILE.
EOF
}

is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

require_value() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo "error: $1 requires a value" >&2
    exit 2
  fi
}

bool_enabled() {
  case "${1:-true}" in
    1 | true | TRUE | yes | YES | on | ON) return 0 ;;
    *) return 1 ;;
  esac
}

CONTEXT="${K8S_CONTEXT:-${CONTEXT:-}}"
NAMESPACE="${DB_NAMESPACE:-${K8S_NAMESPACE:-}}"
RESOURCE="${MARIADB_RESOURCE:-mariadb}"
MDB="${MARIADB_NAME:-${MARIADB_STS_NAME:-mariadb}}"
CONTAINER="${MARIADB_CONTAINER:-mariadb}"
LAG_THRESHOLD="${LAG_THRESHOLD:-1}"
CONN_WARN_PCT="${CONN_WARN_PCT:-80}"
LONG_TX_THRESHOLD="${LONG_TX_THRESHOLD:-${TX_THRESHOLD:-10}}"
EXPECTED_VERSION="${EXPECTED_VERSION:-}"
JSON_ONLY=0
STRICT_EXIT=0
RESULT_FILE="${AQSH_RESULT_FILE:-}"

CHECK_OPERATOR="${CHECK_OPERATOR:-true}"
CHECK_PODS="${CHECK_PODS:-true}"
CHECK_SERVICE="${CHECK_SERVICE:-true}"
CHECK_SQL="${CHECK_SQL:-true}"
CHECK_REPLICATION="${CHECK_REPLICATION:-true}"
CHECK_SEMI_SYNC="${CHECK_SEMI_SYNC:-true}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) require_value "$1" "${2:-}"; CONTEXT="$2"; shift 2 ;;
    --namespace) require_value "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
    --resource) require_value "$1" "${2:-}"; RESOURCE="$2"; shift 2 ;;
    --mdb | --name) require_value "$1" "${2:-}"; MDB="$2"; shift 2 ;;
    --container) require_value "$1" "${2:-}"; CONTAINER="$2"; shift 2 ;;
    --lag-threshold) require_value "$1" "${2:-}"; LAG_THRESHOLD="$2"; shift 2 ;;
    --conn-warn-pct) require_value "$1" "${2:-}"; CONN_WARN_PCT="$2"; shift 2 ;;
    --long-tx-threshold | --tx-threshold) require_value "$1" "${2:-}"; LONG_TX_THRESHOLD="$2"; shift 2 ;;
    --expected-version) require_value "$1" "${2:-}"; EXPECTED_VERSION="$2"; shift 2 ;;
    --skip-operator) CHECK_OPERATOR=false; shift ;;
    --skip-pods) CHECK_PODS=false; shift ;;
    --skip-service) CHECK_SERVICE=false; shift ;;
    --skip-sql) CHECK_SQL=false; shift ;;
    --skip-replication) CHECK_REPLICATION=false; shift ;;
    --skip-semi-sync) CHECK_SEMI_SYNC=false; shift ;;
    --json) JSON_ONLY=1; shift ;;
    --result-file) require_value "$1" "${2:-}"; RESULT_FILE="$2"; shift 2 ;;
    --strict-exit) STRICT_EXIT=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$NAMESPACE" ]]; then
  usage
  exit 2
fi

for numeric_arg in LAG_THRESHOLD CONN_WARN_PCT LONG_TX_THRESHOLD; do
  numeric_value="${!numeric_arg}"
  if ! is_uint "$numeric_value"; then
    echo "error: ${numeric_arg} must be an unsigned integer (got: ${numeric_value})" >&2
    exit 2
  fi
done

mariadb_set_target "$CONTEXT" "$NAMESPACE" "$RESOURCE" "$MDB" "$CONTAINER"

PASS_COUNT=0
WARN_COUNT=0
BLOCK_COUNT=0
ERROR_COUNT=0
CHECKS_JSON=""
FIRST_WARN_REASON=""
FIRST_BLOCK_REASON=""
FIRST_ERROR_REASON=""

json_escape() {
  _escape_json_string "$1"
}

append_check_json() {
  local name="$1"
  local status="$2"
  local reason_code="$3"
  local detail="$4"
  local pod="${5:-}"
  local sep=""

  [[ -n "$CHECKS_JSON" ]] && sep=","
  CHECKS_JSON="${CHECKS_JSON}${sep}{\"name\":\"$(json_escape "$name")\",\"status\":\"${status}\",\"reason_code\":\"$(json_escape "$reason_code")\",\"detail\":\"$(json_escape "$detail")\""
  if [[ -n "$pod" ]]; then
    CHECKS_JSON="${CHECKS_JSON},\"pod\":\"$(json_escape "$pod")\""
  fi
  CHECKS_JSON="${CHECKS_JSON}}"
}

emit_check() {
  local name="$1"
  local status="$2"
  local reason_code="$3"
  local detail="$4"
  local pod="${5:-}"

  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    WARN)
      WARN_COUNT=$((WARN_COUNT + 1))
      [[ -z "$FIRST_WARN_REASON" ]] && FIRST_WARN_REASON="$reason_code"
      ;;
    BLOCK)
      BLOCK_COUNT=$((BLOCK_COUNT + 1))
      [[ -z "$FIRST_BLOCK_REASON" ]] && FIRST_BLOCK_REASON="$reason_code"
      ;;
    ERROR)
      ERROR_COUNT=$((ERROR_COUNT + 1))
      [[ -z "$FIRST_ERROR_REASON" ]] && FIRST_ERROR_REASON="$reason_code"
      ;;
  esac
  append_check_json "$name" "$status" "$reason_code" "$detail" "$pod"

  if [[ "$JSON_ONLY" -ne 1 ]]; then
    printf '[%-5s] %-34s %s\n' "$status" "$reason_code" "$detail"
  fi
}

if [[ "$JSON_ONLY" -ne 1 ]]; then
  echo "=== MariaDB Operator Sanity Check ==="
  echo "context=${CONTEXT:-<current>} namespace=${NAMESPACE} resource=${RESOURCE} mdb=${MDB}"
  echo "thresholds: lag<=${LAG_THRESHOLD}s conn_warn>=${CONN_WARN_PCT}% long_tx>${LONG_TX_THRESHOLD}s"
  echo
fi

if ! k8s_check >/dev/null; then
  emit_check kubectl ERROR KUBECTL_UNAVAILABLE "kubectl is not available or cannot reach the cluster"
fi

REPLICAS=""
CURRENT_PRIMARY=""
CURRENT_PRIMARY_INDEX=""
PODS=()
ROOT_PASSWORD=""
PRIMARY_GTID=""

if bool_enabled "$CHECK_OPERATOR"; then
  [[ "$JSON_ONLY" -ne 1 ]] && echo "=== Operator / CR ==="
  if _kubectl get "$RESOURCE" "$MDB" >/dev/null 2>&1; then
    emit_check cr_exists PASS CR_EXISTS "${RESOURCE}/${MDB} exists"
    CR_READY=$(mariadb_jsonpath "$RESOURCE" "$MDB" '{.status.conditions[?(@.type=="Ready")].status}' || true)
    CURRENT_PRIMARY=$(mariadb_jsonpath "$RESOURCE" "$MDB" '{.status.currentPrimary}' || true)
    CURRENT_PRIMARY_INDEX=$(mariadb_jsonpath "$RESOURCE" "$MDB" '{.status.currentPrimaryPodIndex}' || true)
    REPLICAS=$(mariadb_cr_replicas || true)

    if [[ "$CR_READY" == "True" ]]; then
      emit_check cr_ready PASS CR_READY "Ready=True"
    else
      emit_check cr_ready BLOCK CR_NOT_READY "Ready=${CR_READY:-<empty>}"
    fi

    if [[ -n "$CURRENT_PRIMARY" ]]; then
      emit_check current_primary PASS CURRENT_PRIMARY_PRESENT "currentPrimary=${CURRENT_PRIMARY}"
    else
      emit_check current_primary BLOCK CURRENT_PRIMARY_EMPTY "currentPrimary=<empty>"
    fi

    if [[ -n "$CURRENT_PRIMARY_INDEX" ]]; then
      emit_check current_primary_pod_index PASS CURRENT_PRIMARY_POD_INDEX_PRESENT "currentPrimaryPodIndex=${CURRENT_PRIMARY_INDEX}"
    else
      emit_check current_primary_pod_index BLOCK CURRENT_PRIMARY_POD_INDEX_EMPTY "currentPrimaryPodIndex=<empty>"
    fi
  else
    emit_check cr_exists ERROR CR_NOT_FOUND "${RESOURCE}/${MDB} not found"
  fi
  [[ "$JSON_ONLY" -ne 1 ]] && echo
fi

if [[ -z "$REPLICAS" ]]; then
  REPLICAS=$(mariadb_sts_replicas || true)
fi
if [[ -z "$CURRENT_PRIMARY" && -n "$CURRENT_PRIMARY_INDEX" ]]; then
  CURRENT_PRIMARY=$(mariadb_pod_name "$CURRENT_PRIMARY_INDEX")
fi
mapfile -t PODS < <(mariadb_list_pods "$REPLICAS")

if bool_enabled "$CHECK_PODS"; then
  [[ "$JSON_ONLY" -ne 1 ]] && echo "=== Pods ==="
  if [[ "${#PODS[@]}" -eq 0 ]]; then
    emit_check pods_present BLOCK POD_NOT_READY "no MariaDB pods found for ${MDB}"
  else
    for pod in "${PODS[@]}"; do
      phase=$(mariadb_pod_jsonpath "$pod" '{.status.phase}' || true)
      ready=$(mariadb_pod_jsonpath "$pod" "{.status.containerStatuses[?(@.name==\"${CONTAINER}\")].ready}" || true)
      restarts=$(mariadb_pod_jsonpath "$pod" "{.status.containerStatuses[?(@.name==\"${CONTAINER}\")].restartCount}" || true)
      waiting_reason=$(mariadb_pod_jsonpath "$pod" "{.status.containerStatuses[?(@.name==\"${CONTAINER}\")].state.waiting.reason}" || true)
      if [[ "$phase" == "Running" && "$ready" == "true" ]]; then
        emit_check pod_ready PASS POD_READY "pod=${pod} phase=Running ${CONTAINER}.ready=true restarts=${restarts:-0}" "$pod"
      else
        emit_check pod_ready BLOCK POD_NOT_READY "pod=${pod} phase=${phase:-<empty>} ${CONTAINER}.ready=${ready:-<empty>} restarts=${restarts:-?} waiting=${waiting_reason:-<none>}" "$pod"
      fi
    done
  fi
  [[ "$JSON_ONLY" -ne 1 ]] && echo
fi

if bool_enabled "$CHECK_SERVICE"; then
  [[ "$JSON_ONLY" -ne 1 ]] && echo "=== Primary Service ==="
  PRIMARY_SERVICE=$(mariadb_primary_service_name)
  if _kubectl get service "$PRIMARY_SERVICE" >/dev/null 2>&1; then
    emit_check primary_service PASS PRIMARY_SERVICE_PRESENT "service/${PRIMARY_SERVICE} exists"
    selector=$(mariadb_service_jsonpath "$PRIMARY_SERVICE" '{.spec.selector.statefulset\.kubernetes\.io/pod-name}' || true)
    if [[ -z "$selector" ]]; then
      selector=$(mariadb_service_jsonpath "$PRIMARY_SERVICE" '{.spec.selector.pod-name}' || true)
    fi
    if [[ -z "$CURRENT_PRIMARY" ]]; then
      emit_check primary_service_selector BLOCK CURRENT_PRIMARY_EMPTY "cannot verify selector because currentPrimary is empty"
    elif [[ "$selector" == "$CURRENT_PRIMARY" ]]; then
      emit_check primary_service_selector PASS PRIMARY_SERVICE_SELECTOR_OK "selector pod=${selector}"
    else
      emit_check primary_service_selector BLOCK PRIMARY_SERVICE_SELECTOR_DRIFT "selector=${selector:-<empty>} currentPrimary=${CURRENT_PRIMARY}"
    fi
  else
    if [[ "${REPLICAS:-0}" -le 1 ]] 2>/dev/null; then
      emit_check primary_service PASS PRIMARY_SERVICE_NOT_APPLICABLE "single-replica deployment has no service/${PRIMARY_SERVICE}"
    else
      emit_check primary_service BLOCK PRIMARY_SERVICE_MISSING "service/${PRIMARY_SERVICE} not found"
    fi
  fi
  [[ "$JSON_ONLY" -ne 1 ]] && echo
fi

ROOT_PASSWORD=""
ROOT_PASSWORD_CHECKED=0
if bool_enabled "$CHECK_SQL" || bool_enabled "$CHECK_REPLICATION" || bool_enabled "$CHECK_SEMI_SYNC"; then
  if [[ -n "$CURRENT_PRIMARY" ]]; then
    ROOT_PASSWORD_CHECKED=1
    if ! ROOT_PASSWORD=$(mariadb_read_root_password "$CURRENT_PRIMARY" "${PODS[@]}"); then
      emit_check root_password BLOCK ROOT_PASSWORD_UNAVAILABLE "cannot read MARIADB_ROOT_PASSWORD from ready MariaDB pods"
    fi
  fi
fi

if bool_enabled "$CHECK_SQL"; then
  [[ "$JSON_ONLY" -ne 1 ]] && echo "=== Primary SQL ==="
  if [[ -z "$CURRENT_PRIMARY" ]]; then
    emit_check primary_sql BLOCK CURRENT_PRIMARY_EMPTY "cannot run SQL because currentPrimary is empty"
  elif [[ -n "$ROOT_PASSWORD" ]]; then
    if mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" 'SELECT 1' >/dev/null; then
      emit_check primary_sql PASS PRIMARY_SQL_READY "SELECT 1 succeeded on current primary" "$CURRENT_PRIMARY"
    else
      emit_check primary_sql BLOCK PRIMARY_SQL_UNREACHABLE "SELECT 1 failed on current primary" "$CURRENT_PRIMARY"
    fi

    read_only=$(mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" 'SELECT @@read_only' || true)
    if [[ "$read_only" == "0" ]]; then
      emit_check primary_read_only PASS PRIMARY_READ_WRITE_OK "@@read_only=0" "$CURRENT_PRIMARY"
    else
      emit_check primary_read_only BLOCK PRIMARY_READ_ONLY_UNEXPECTED "@@read_only=${read_only:-<empty>}" "$CURRENT_PRIMARY"
    fi

    PRIMARY_GTID=$(mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" 'SELECT @@gtid_binlog_pos' || true)
    if [[ -n "$PRIMARY_GTID" ]]; then
      emit_check primary_gtid PASS PRIMARY_GTID_READ "@@gtid_binlog_pos=${PRIMARY_GTID}" "$CURRENT_PRIMARY"
    else
      emit_check primary_gtid WARN PRIMARY_GTID_EMPTY "@@gtid_binlog_pos is empty" "$CURRENT_PRIMARY"
    fi

    threads_connected=$(mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "SHOW STATUS LIKE 'Threads_connected'" | awk '{print $2}' || true)
    max_connections=$(mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" 'SELECT @@max_connections' || true)
    if [[ -n "$threads_connected" && -n "$max_connections" && "$max_connections" -gt 0 ]] 2>/dev/null; then
      headroom=$((max_connections - threads_connected))
      pct=$((threads_connected * 100 / max_connections))
      if [[ "$headroom" -le 5 ]]; then
        emit_check connection_headroom BLOCK CONN_HEADROOM_LOW "threads_connected=${threads_connected}/${max_connections} headroom=${headroom}" "$CURRENT_PRIMARY"
      elif [[ "$pct" -ge "$CONN_WARN_PCT" ]]; then
        emit_check connection_headroom WARN CONN_HEADROOM_LOW "threads_connected=${threads_connected}/${max_connections} (${pct}%) >= ${CONN_WARN_PCT}%" "$CURRENT_PRIMARY"
      else
        emit_check connection_headroom PASS CONN_HEADROOM_OK "threads_connected=${threads_connected}/${max_connections} (${pct}%)" "$CURRENT_PRIMARY"
      fi
    else
      emit_check connection_headroom WARN CONN_HEADROOM_UNKNOWN "could not read Threads_connected/max_connections" "$CURRENT_PRIMARY"
    fi

    if long_tx_count=$(mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "
      SELECT COUNT(*)
      FROM information_schema.innodb_trx
      WHERE TIME_TO_SEC(TIMEDIFF(NOW(), trx_started)) > ${LONG_TX_THRESHOLD}"); then
      if [[ "${long_tx_count:-0}" -eq 0 ]] 2>/dev/null; then
        emit_check long_transactions PASS NO_LONG_TRX "no transaction older than ${LONG_TX_THRESHOLD}s" "$CURRENT_PRIMARY"
      else
        emit_check long_transactions WARN LONG_TRX_PRESENT "${long_tx_count} transaction(s) older than ${LONG_TX_THRESHOLD}s" "$CURRENT_PRIMARY"
      fi
    else
      emit_check long_transactions WARN LONG_TRX_UNKNOWN "could not query transactions older than ${LONG_TX_THRESHOLD}s" "$CURRENT_PRIMARY"
    fi

    if [[ -n "$EXPECTED_VERSION" ]]; then
      db_version=$(mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" 'SELECT @@version' || true)
      if [[ "$db_version" == *"$EXPECTED_VERSION"* ]]; then
        emit_check version PASS VERSION_OK "@@version=${db_version}" "$CURRENT_PRIMARY"
      else
        emit_check version BLOCK VERSION_MISMATCH "@@version=${db_version:-<empty>} expected contains ${EXPECTED_VERSION}" "$CURRENT_PRIMARY"
      fi
    fi
  elif [[ "$ROOT_PASSWORD_CHECKED" -ne 1 ]]; then
    emit_check root_password BLOCK ROOT_PASSWORD_UNAVAILABLE "cannot read MARIADB_ROOT_PASSWORD from ready MariaDB pods"
  fi
  [[ "$JSON_ONLY" -ne 1 ]] && echo
fi

REPLICA_PODS=()
if [[ -n "$CURRENT_PRIMARY" ]]; then
  for pod in "${PODS[@]}"; do
    [[ "$pod" == "$CURRENT_PRIMARY" ]] && continue
    REPLICA_PODS+=("$pod")
  done
fi

if bool_enabled "$CHECK_REPLICATION"; then
  [[ "$JSON_ONLY" -ne 1 ]] && echo "=== Replication ==="
  if [[ -z "$ROOT_PASSWORD" ]]; then
    emit_check replication BLOCK PRIMARY_SQL_UNREACHABLE "cannot check replication without SQL credentials"
  elif [[ "${#REPLICA_PODS[@]}" -eq 0 ]]; then
    emit_check replication PASS REPLICATION_NOT_APPLICABLE "no replica pods detected"
  else
    for pod in "${REPLICA_PODS[@]}"; do
      status_out=$(mariadb_sql_vertical "$pod" "$ROOT_PASSWORD" 'SHOW ALL SLAVES STATUS' || true)
      if [[ -z "$status_out" ]]; then
        emit_check replica_status BLOCK REPLICA_STATUS_EMPTY "SHOW ALL SLAVES STATUS returned no rows" "$pod"
      else
        io_running=$(printf '%s\n' "$status_out" | mariadb_status_field Slave_IO_Running)
        sql_running=$(printf '%s\n' "$status_out" | mariadb_status_field Slave_SQL_Running)
        last_io_error=$(printf '%s\n' "$status_out" | mariadb_status_field Last_IO_Error)
        last_sql_error=$(printf '%s\n' "$status_out" | mariadb_status_field Last_SQL_Error)
        seconds_behind=$(printf '%s\n' "$status_out" | mariadb_status_field Seconds_Behind_Master)
        gtid_io_pos=$(printf '%s\n' "$status_out" | mariadb_status_field Gtid_IO_Pos)
        gtid_slave_pos=$(printf '%s\n' "$status_out" | mariadb_status_field Gtid_Slave_Pos)

        [[ "$io_running" == "Yes" ]] \
          && emit_check replica_io PASS REPLICA_IO_RUNNING "Slave_IO_Running=Yes" "$pod" \
          || emit_check replica_io BLOCK REPLICA_IO_NOT_RUNNING "Slave_IO_Running=${io_running:-<empty>}" "$pod"
        [[ "$sql_running" == "Yes" ]] \
          && emit_check replica_sql PASS REPLICA_SQL_RUNNING "Slave_SQL_Running=Yes" "$pod" \
          || emit_check replica_sql BLOCK REPLICA_SQL_NOT_RUNNING "Slave_SQL_Running=${sql_running:-<empty>}" "$pod"
        [[ -z "$last_io_error" ]] \
          && emit_check replica_io_error PASS REPLICA_NO_IO_ERROR "Last_IO_Error empty" "$pod" \
          || emit_check replica_io_error BLOCK REPLICA_IO_ERROR "Last_IO_Error=${last_io_error}" "$pod"
        [[ -z "$last_sql_error" ]] \
          && emit_check replica_sql_error PASS REPLICA_NO_SQL_ERROR "Last_SQL_Error empty" "$pod" \
          || emit_check replica_sql_error BLOCK REPLICA_SQL_ERROR "Last_SQL_Error=${last_sql_error}" "$pod"

        if [[ -z "$seconds_behind" || "$seconds_behind" == "NULL" ]]; then
          emit_check replica_lag BLOCK REPLICA_LAG_UNKNOWN "Seconds_Behind_Master=${seconds_behind:-<empty>}" "$pod"
        elif [[ "$seconds_behind" -le "$LAG_THRESHOLD" ]] 2>/dev/null; then
          emit_check replica_lag PASS REPLICA_LAG_OK "Seconds_Behind_Master=${seconds_behind}s threshold=${LAG_THRESHOLD}s" "$pod"
        else
          emit_check replica_lag BLOCK REPLICA_LAG_HIGH "Seconds_Behind_Master=${seconds_behind}s threshold=${LAG_THRESHOLD}s" "$pod"
        fi

        if [[ -n "$gtid_io_pos" && -n "$gtid_slave_pos" ]]; then
          if [[ "$gtid_io_pos" == "$gtid_slave_pos" ]]; then
            emit_check replica_gtid PASS REPLICA_RELAY_APPLIED "Gtid_IO_Pos equals Gtid_Slave_Pos" "$pod"
          elif [[ -n "$PRIMARY_GTID" && -n "$gtid_slave_pos" ]] && mariadb_gtid_covers "$PRIMARY_GTID" "$gtid_slave_pos"; then
            emit_check replica_gtid PASS REPLICA_RELAY_APPLIED "Gtid_Slave_Pos covers primary @@gtid_binlog_pos" "$pod"
          else
            emit_check replica_gtid BLOCK REPLICA_RELAY_PENDING "Gtid_IO_Pos=${gtid_io_pos} Gtid_Slave_Pos=${gtid_slave_pos}" "$pod"
          fi
        else
          emit_check replica_gtid WARN REPLICA_RELAY_GTID_UNKNOWN "Gtid_IO_Pos=${gtid_io_pos:-<empty>} Gtid_Slave_Pos=${gtid_slave_pos:-<empty>}" "$pod"
        fi
      fi

      replica_read_only=$(mariadb_sql "$pod" "$ROOT_PASSWORD" 'SELECT @@read_only' || true)
      if [[ "$replica_read_only" == "1" ]]; then
        emit_check replica_read_only PASS REPLICA_READ_ONLY_OK "@@read_only=1" "$pod"
      else
        emit_check replica_read_only BLOCK REPLICA_NOT_READ_ONLY "@@read_only=${replica_read_only:-<empty>}" "$pod"
      fi
    done
  fi
  [[ "$JSON_ONLY" -ne 1 ]] && echo
fi

if bool_enabled "$CHECK_SEMI_SYNC"; then
  [[ "$JSON_ONLY" -ne 1 ]] && echo "=== Semi-sync ==="
  if [[ -z "$ROOT_PASSWORD" ]]; then
    emit_check semi_sync BLOCK PRIMARY_SQL_UNREACHABLE "cannot check semi-sync without SQL credentials"
  elif [[ "${#REPLICA_PODS[@]}" -eq 0 ]]; then
    emit_check semi_sync PASS SEMI_SYNC_NOT_APPLICABLE "no replica pods detected"
  else
    master_status=$(mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "SHOW STATUS LIKE 'Rpl_semi_sync_master_status'" | awk '{print $2}' || true)
    master_clients=$(mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "SHOW STATUS LIKE 'Rpl_semi_sync_master_clients'" | awk '{print $2}' || true)
    expected_clients="${#REPLICA_PODS[@]}"
    if [[ "$master_status" == "ON" ]]; then
      emit_check semi_sync_master PASS SEMI_SYNC_MASTER_ON "Rpl_semi_sync_master_status=ON clients=${master_clients:-?}" "$CURRENT_PRIMARY"
    else
      emit_check semi_sync_master BLOCK SEMI_SYNC_MASTER_OFF "Rpl_semi_sync_master_status=${master_status:-<empty>}" "$CURRENT_PRIMARY"
    fi
    if [[ "${master_clients:-0}" -ge "$expected_clients" ]] 2>/dev/null; then
      emit_check semi_sync_clients PASS SEMI_SYNC_CLIENTS_OK "clients=${master_clients:-0} expected>=${expected_clients}" "$CURRENT_PRIMARY"
    else
      emit_check semi_sync_clients BLOCK SEMI_SYNC_CLIENTS_LOW "clients=${master_clients:-0} expected>=${expected_clients}" "$CURRENT_PRIMARY"
    fi
    for pod in "${REPLICA_PODS[@]}"; do
      slave_status=$(mariadb_sql "$pod" "$ROOT_PASSWORD" "SHOW STATUS LIKE 'Rpl_semi_sync_slave_status'" | awk '{print $2}' || true)
      if [[ "$slave_status" == "ON" ]]; then
        emit_check semi_sync_slave PASS SEMI_SYNC_SLAVE_ON "Rpl_semi_sync_slave_status=ON" "$pod"
      else
        emit_check semi_sync_slave BLOCK SEMI_SYNC_SLAVE_OFF "Rpl_semi_sync_slave_status=${slave_status:-<empty>}" "$pod"
      fi
    done
  fi
  [[ "$JSON_ONLY" -ne 1 ]] && echo
fi

TOTAL=$((PASS_COUNT + WARN_COUNT + BLOCK_COUNT + ERROR_COUNT))
if [[ "$ERROR_COUNT" -gt 0 ]]; then
  RESULT_STATUS="ERROR"
  RESULT_REASON="${FIRST_ERROR_REASON:-SANITY_ERROR}"
elif [[ "$BLOCK_COUNT" -gt 0 ]]; then
  RESULT_STATUS="BLOCK"
  RESULT_REASON="${FIRST_BLOCK_REASON:-SANITY_BLOCK}"
elif [[ "$WARN_COUNT" -gt 0 ]]; then
  RESULT_STATUS="WARN"
  RESULT_REASON="${FIRST_WARN_REASON:-SANITY_WARN}"
else
  RESULT_STATUS="PASS"
  RESULT_REASON="SANITY_PASS"
fi

case "$RESULT_STATUS" in
  PASS) SUMMARY="MariaDB operator, service, SQL, replication, and semi-sync sanity checks passed" ;;
  WARN) SUMMARY="MariaDB sanity checks passed with non-blocking warnings" ;;
  BLOCK) SUMMARY="MariaDB sanity checks found blocking issues; stop the automated step" ;;
  *) SUMMARY="MariaDB sanity check could not complete cleanly" ;;
esac

RESULT_JSON=$(printf '{"status":"%s","reason_code":"%s","summary":"%s","target":{"context":"%s","namespace":"%s","resource":"%s","mdb":"%s"},"thresholds":{"lag_sec":%d,"conn_warn_pct":%d,"long_tx_sec":%d},"counts":{"pass":%d,"warn":%d,"block":%d,"error":%d,"total":%d},"checks":[%s]}\n' \
  "$RESULT_STATUS" \
  "$(json_escape "$RESULT_REASON")" \
  "$(json_escape "$SUMMARY")" \
  "$(json_escape "${CONTEXT:-}")" \
  "$(json_escape "$NAMESPACE")" \
  "$(json_escape "$RESOURCE")" \
  "$(json_escape "$MDB")" \
  "$LAG_THRESHOLD" \
  "$CONN_WARN_PCT" \
  "$LONG_TX_THRESHOLD" \
  "$PASS_COUNT" \
  "$WARN_COUNT" \
  "$BLOCK_COUNT" \
  "$ERROR_COUNT" \
  "$TOTAL" \
  "$CHECKS_JSON")

if [[ -n "$RESULT_FILE" ]]; then
  printf '%s' "$RESULT_JSON" > "$RESULT_FILE"
fi

if [[ "$JSON_ONLY" -eq 1 || -z "$RESULT_FILE" ]]; then
  printf '%s' "$RESULT_JSON"
else
  echo "=== SANITY CHECK: ${RESULT_STATUS} ==="
  echo "$SUMMARY"
fi

if [[ "$STRICT_EXIT" -eq 1 ]]; then
  case "$RESULT_STATUS" in
    PASS | WARN) exit 0 ;;
    BLOCK) exit 1 ;;
    ERROR) exit 2 ;;
  esac
fi

exit 0
