#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/migration/setup-replication.sh
# Configure a MariaDB GTID replication channel using root credentials.
#
# AQSH injects inputs as environment variables and reads $AQSH_RESULT_FILE.
# Rundeck/local users can pass the same values as CLI flags.
# =============================================================================

# Capture the caller-supplied target name BEFORE sourcing libs — lib/mariadb.sh
# defaults MARIADB_NAME to "mariadb" at load time. Empty here means auto-detect.
MDB_INPUT="${MARIADB_NAME:-${MARIADB_STS_NAME:-}}"

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi

# shellcheck source=../../../lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=../../../lib/response.sh
source "${LIB_DIR}/response.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  setup-replication.sh --namespace <namespace> --host <host> [options]

Required:
  --namespace <namespace>           Kubernetes namespace.
  --host <host>                     Replication source host (IP or hostname).

Replication options:
  --channel <name>                  Channel name. Default: "" (default channel).
  --port <port>                     Source port. Default: 3306.
  --delay <seconds>                 MASTER_DELAY in seconds. Omit to leave unset.
  --async <bool>                    Set rpl_semi_sync_slave_enabled=OFF. Default: false.

Target options:
  --context <context>               Kubernetes context. Optional for in-cluster AQSH.
  --resource <kind>                 MariaDB CR kind. Default: mariadb.
  --mdb <name>                      MariaDB CR / StatefulSet name. Default: auto-detected.
  --container <name>                MariaDB container name. Default: mariadb.

Password options:
  --repl-password-secret <name>     Secret holding the replication (source root) password.
                                    Defaults to using the pod's own MARIADB_ROOT_PASSWORD.
  --repl-password-key <key>         Key in the secret. Default: password.

Safety options:
  --dry-run <bool>                  Show SQL plan; no changes applied. Default: true.
  --confirm <bool>                  Required true when dry_run=false. Default: false.

Output:
  --json                            Print only JSON result to stdout.
  --result-file <path>              Write JSON result to this file.
  --strict-exit                     Exit non-zero on BLOCKED or ERROR.

Environment equivalents:
  DB_NAMESPACE, REPL_HOST, REPL_CHANNEL, REPL_PORT, REPL_DELAY, REPL_ASYNC,
  K8S_CONTEXT, MARIADB_RESOURCE, MARIADB_NAME, MARIADB_CONTAINER,
  REPL_PASSWORD_SECRET, REPL_PASSWORD_KEY, DRY_RUN, CONFIRM, AQSH_RESULT_FILE.
EOF
}

require_value() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo "error: $1 requires a value" >&2
    exit 2
  fi
}

bool_enabled() {
  case "${1:-false}" in
    1 | true | TRUE | yes | YES | on | ON) return 0 ;;
    *) return 1 ;;
  esac
}

sql_string_literal() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

json_escape() { _escape_json_string "$1"; }

# ---------- defaults from environment ----------
CONTEXT="${K8S_CONTEXT:-${CONTEXT:-}}"
NAMESPACE="${DB_NAMESPACE:-${K8S_NAMESPACE:-}}"
RESOURCE="${MARIADB_RESOURCE:-mariadb}"
MDB="$MDB_INPUT"
CONTAINER="${MARIADB_CONTAINER:-mariadb}"
REPL_HOST="${REPL_HOST:-}"
REPL_CHANNEL="${REPL_CHANNEL:-}"
REPL_PORT="${REPL_PORT:-3306}"
REPL_DELAY="${REPL_DELAY:-}"
REPL_ASYNC="${REPL_ASYNC:-false}"
REPL_PASSWORD_SECRET="${REPL_PASSWORD_SECRET:-}"
REPL_PASSWORD_KEY="${REPL_PASSWORD_KEY:-password}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"
JSON_ONLY=0
STRICT_EXIT=0
RESULT_FILE="${AQSH_RESULT_FILE:-}"

# ---------- parse CLI flags ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)               require_value "$1" "${2:-}"; CONTEXT="$2";               shift 2 ;;
    --namespace)             require_value "$1" "${2:-}"; NAMESPACE="$2";             shift 2 ;;
    --resource)              require_value "$1" "${2:-}"; RESOURCE="$2";              shift 2 ;;
    --mdb | --name)          require_value "$1" "${2:-}"; MDB="$2";                   shift 2 ;;
    --container)             require_value "$1" "${2:-}"; CONTAINER="$2";             shift 2 ;;
    --host)                  require_value "$1" "${2:-}"; REPL_HOST="$2";             shift 2 ;;
    --channel)               require_value "$1" "${2:-}"; REPL_CHANNEL="$2";          shift 2 ;;
    --port)                  require_value "$1" "${2:-}"; REPL_PORT="$2";             shift 2 ;;
    --delay)                 require_value "$1" "${2:-}"; REPL_DELAY="$2";            shift 2 ;;
    --async)                 require_value "$1" "${2:-}"; REPL_ASYNC="$2";            shift 2 ;;
    --repl-password-secret)  require_value "$1" "${2:-}"; REPL_PASSWORD_SECRET="$2"; shift 2 ;;
    --repl-password-key)     require_value "$1" "${2:-}"; REPL_PASSWORD_KEY="$2";    shift 2 ;;
    --dry-run)               require_value "$1" "${2:-}"; DRY_RUN="$2";               shift 2 ;;
    --confirm)               require_value "$1" "${2:-}"; CONFIRM="$2";               shift 2 ;;
    --json)                  JSON_ONLY=1;                                             shift ;;
    --result-file)           require_value "$1" "${2:-}"; RESULT_FILE="$2";           shift 2 ;;
    --strict-exit)           STRICT_EXIT=1;                                           shift ;;
    -h | --help)             usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

# ---------- validation ----------
ERRORS=()
add_error() { ERRORS+=("$1"); }

[[ -n "$NAMESPACE" ]] || add_error "namespace is required"
[[ -n "$REPL_HOST" ]] || add_error "host is required"

if [[ -n "$NAMESPACE" && ! "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  add_error "namespace must be a valid Kubernetes namespace"
fi

if [[ -n "$REPL_PORT" && ! "$REPL_PORT" =~ ^[0-9]+$ ]]; then
  add_error "port must be a positive integer"
fi

if [[ -n "$REPL_DELAY" && ! "$REPL_DELAY" =~ ^[0-9]+$ ]]; then
  add_error "delay must be a non-negative integer (seconds)"
fi

if [[ -n "$REPL_CHANNEL" ]] && { [[ "$REPL_CHANNEL" == *$'\n'* ]] || [[ "$REPL_CHANNEL" =~ [[:cntrl:]] ]]; }; then
  add_error "channel name contains unsupported control characters"
fi

is_valid_bool() {
  case "${1:-}" in
    1 | 0 | true | false | TRUE | FALSE | yes | no | YES | NO | on | off | ON | OFF) return 0 ;;
    *) return 1 ;;
  esac
}

for bool_var in REPL_ASYNC DRY_RUN CONFIRM; do
  if ! is_valid_bool "${!bool_var}"; then
    add_error "${bool_var} must be a boolean-like value"
  fi
done

# ---------- build SQL plan (always redacted) ----------
CHANNEL_CLAUSE=""
if [[ -n "$REPL_CHANNEL" ]]; then
  CHANNEL_CLAUSE=" $(sql_string_literal "$REPL_CHANNEL")"
fi

build_change_master_sql() {
  local password="${1:-<redacted>}"
  local sql="CHANGE MASTER${CHANNEL_CLAUSE} TO"
  sql="${sql} MASTER_HOST=$(sql_string_literal "$REPL_HOST"),"
  sql="${sql} MASTER_PORT=${REPL_PORT},"
  sql="${sql} MASTER_USER='root',"
  sql="${sql} MASTER_PASSWORD=$(sql_string_literal "$password"),"
  sql="${sql} MASTER_USE_GTID=slave_pos"
  if [[ -n "$REPL_DELAY" ]]; then
    sql="${sql}, MASTER_DELAY=${REPL_DELAY}"
  fi
  printf '%s' "$sql"
}

build_sql_plan_json() {
  local stmts=()
  stmts+=("STOP SLAVE${CHANNEL_CLAUSE}")
  stmts+=("$(build_change_master_sql)")
  if bool_enabled "$REPL_ASYNC"; then
    stmts+=("SET GLOBAL rpl_semi_sync_slave_enabled=OFF")
  fi
  stmts+=("START SLAVE${CHANNEL_CLAUSE}")
  stmts+=("SHOW ALL SLAVES STATUS")

  local out="" sep=""
  for stmt in "${stmts[@]}"; do
    out="${out}${sep}\"$(json_escape "$stmt")\""
    sep=","
  done
  printf '[%s]' "$out"
}

errors_json() {
  local out="" sep="" item
  for item in "${ERRORS[@]}"; do
    out="${out}${sep}\"$(json_escape "$item")\""
    sep=","
  done
  printf '[%s]' "$out"
}

result_json() {
  local status="$1" reason_code="$2" summary="$3"
  local pod="${4:-}" sql_plan="${5:-[]}" slave_status="${6:-}" error_json="${7:-[]}"
  printf '{"status":"%s","reason_code":"%s","summary":"%s","target":{"context":"%s","namespace":"%s","resource":"%s","mdb":"%s","pod":"%s"},"replication":{"channel":"%s","host":"%s","port":%s,"delay_sec":%s,"async":%s},"dry_run":%s,"sql_plan":%s,"slave_status":"%s","errors":%s}\n' \
    "$status" \
    "$(json_escape "$reason_code")" \
    "$(json_escape "$summary")" \
    "$(json_escape "${CONTEXT:-}")" \
    "$(json_escape "$NAMESPACE")" \
    "$(json_escape "$RESOURCE")" \
    "$(json_escape "$MDB")" \
    "$(json_escape "$pod")" \
    "$(json_escape "$REPL_CHANNEL")" \
    "$(json_escape "$REPL_HOST")" \
    "$REPL_PORT" \
    "${REPL_DELAY:-null}" \
    "$(bool_enabled "$REPL_ASYNC" && printf true || printf false)" \
    "$(bool_enabled "$DRY_RUN" && printf true || printf false)" \
    "$sql_plan" \
    "$(json_escape "$slave_status")" \
    "$error_json"
}

emit_result() {
  local json="$1" status_value="$2" summary="$3"

  if [[ -n "$RESULT_FILE" ]]; then
    printf '%s' "$json" > "$RESULT_FILE"
  fi

  if [[ "$JSON_ONLY" -eq 1 || -z "$RESULT_FILE" ]]; then
    printf '%s' "$json"
  else
    echo "=== SETUP REPLICATION: ${status_value} ==="
    echo "$summary"
  fi

  if [[ "$STRICT_EXIT" -eq 1 ]]; then
    case "$status_value" in
      READY | DONE) exit 0 ;;
      BLOCKED) exit 1 ;;
      ERROR) exit 2 ;;
    esac
  fi
  exit 0
}

# ---------- early exits ----------
SQL_PLAN_JSON="$(build_sql_plan_json)"

if [[ "${#ERRORS[@]}" -gt 0 ]]; then
  SUMMARY="Invalid setup-replication request"
  emit_result "$(result_json ERROR INVALID_INPUT "$SUMMARY" "" "$SQL_PLAN_JSON" "" "$(errors_json)")" ERROR "$SUMMARY"
fi

if bool_enabled "$DRY_RUN"; then
  SUMMARY="Dry-run ready; no Kubernetes or SQL changes were made"
  emit_result "$(result_json READY DRY_RUN_READY "$SUMMARY" "" "$SQL_PLAN_JSON" "" "[]")" READY "$SUMMARY"
fi

if ! bool_enabled "$CONFIRM"; then
  SUMMARY="confirm=true is required when dry_run=false"
  emit_result "$(result_json BLOCKED CONFIRM_REQUIRED "$SUMMARY" "" "$SQL_PLAN_JSON" "" "[]")" BLOCKED "$SUMMARY"
fi

# ---------- k8s setup ----------
# shellcheck source=../../../lib/k8s.sh
source "${LIB_DIR}/k8s.sh"
# shellcheck source=../../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"

mariadb_set_target "$CONTEXT" "$NAMESPACE" "$RESOURCE" "$MDB" "$CONTAINER"

if ! k8s_check >/dev/null; then
  SUMMARY="kubectl is unavailable or cannot reach the target cluster"
  emit_result "$(result_json ERROR KUBECTL_UNAVAILABLE "$SUMMARY" "" "$SQL_PLAN_JSON" "" "[]")" ERROR "$SUMMARY"
fi

_on_ambiguous() {
  local summary="Multiple MariaDB targets in namespace ($1); specify --mdb"
  emit_result "$(result_json ERROR MARIADB_AMBIGUOUS "$summary" "" "$SQL_PLAN_JSON" "" "[]")" ERROR "$summary"
}
_on_none() {
  local summary="No MariaDB CR or StatefulSet found in namespace"
  emit_result "$(result_json ERROR MARIADB_NOT_FOUND "$summary" "" "$SQL_PLAN_JSON" "" "[]")" ERROR "$summary"
}

if [[ -z "$MDB" ]]; then
  mariadb_autodetect_target true _on_ambiguous _on_none
  MDB="$MARIADB_NAME"
fi

REPLICAS=""
REPLICAS=$(mariadb_cr_replicas 2>/dev/null || true)
if [[ -z "$REPLICAS" ]]; then
  REPLICAS=$(mariadb_sts_replicas 2>/dev/null || true)
fi
mapfile -t PODS < <(mariadb_list_pods "$REPLICAS")
TARGET_POD=""
[[ "${#PODS[@]}" -gt 0 ]] && TARGET_POD="${PODS[0]}"

if [[ -z "$TARGET_POD" ]]; then
  SUMMARY="No MariaDB pod found in namespace ${NAMESPACE}"
  emit_result "$(result_json ERROR NO_POD_FOUND "$SUMMARY" "" "$SQL_PLAN_JSON" "" "[]")" ERROR "$SUMMARY"
fi

# ---------- credentials ----------
ROOT_PASSWORD=""
if ! ROOT_PASSWORD="$(mariadb_read_root_password "$TARGET_POD" "${PODS[@]}")"; then
  SUMMARY="Cannot read MARIADB_ROOT_PASSWORD from target pod"
  emit_result "$(result_json ERROR ROOT_PASSWORD_UNAVAILABLE "$SUMMARY" "$TARGET_POD" "$SQL_PLAN_JSON" "" "[]")" ERROR "$SUMMARY"
fi

REPL_PASSWORD=""
if [[ -n "$REPL_PASSWORD_SECRET" ]]; then
  encoded=$(_kubectl get secret "$REPL_PASSWORD_SECRET" -o "jsonpath={.data.${REPL_PASSWORD_KEY}}" 2>/dev/null) || true
  if [[ -n "$encoded" ]]; then
    REPL_PASSWORD="$(printf '%s' "$encoded" | base64 -d)"
  fi
  if [[ -z "$REPL_PASSWORD" ]]; then
    SUMMARY="Cannot read replication password from secret ${REPL_PASSWORD_SECRET} (key: ${REPL_PASSWORD_KEY})"
    emit_result "$(result_json ERROR REPL_PASSWORD_UNAVAILABLE "$SUMMARY" "$TARGET_POD" "$SQL_PLAN_JSON" "" "[]")" ERROR "$SUMMARY"
  fi
else
  REPL_PASSWORD="$ROOT_PASSWORD"
fi

CHANGE_MASTER_SQL="$(build_change_master_sql "$REPL_PASSWORD")"

# ---------- execute ----------
if [[ "$JSON_ONLY" -ne 1 ]]; then
  echo "=== Setup Replication Channel ==="
  echo "pod=${TARGET_POD} channel=${REPL_CHANNEL:-<default>} host=${REPL_HOST}:${REPL_PORT}"
  echo
fi

if [[ "$JSON_ONLY" -ne 1 ]]; then
  echo "=== Stop Slave ==="
fi
# Ignore error: slave may not be configured or may already be stopped.
mariadb_sql "$TARGET_POD" "$ROOT_PASSWORD" "STOP SLAVE${CHANNEL_CLAUSE}" >/dev/null 2>&1 || true

if [[ "$JSON_ONLY" -ne 1 ]]; then
  echo "=== Change Master ==="
fi
if ! mariadb_sql "$TARGET_POD" "$ROOT_PASSWORD" "$CHANGE_MASTER_SQL" >/dev/null; then
  SUMMARY="CHANGE MASTER TO failed on pod=${TARGET_POD}"
  emit_result "$(result_json ERROR CHANGE_MASTER_FAILED "$SUMMARY" "$TARGET_POD" "$SQL_PLAN_JSON" "" "[]")" ERROR "$SUMMARY"
fi

if bool_enabled "$REPL_ASYNC"; then
  if [[ "$JSON_ONLY" -ne 1 ]]; then
    echo "=== Disable Semi-sync Slave ==="
  fi
  mariadb_sql "$TARGET_POD" "$ROOT_PASSWORD" "SET GLOBAL rpl_semi_sync_slave_enabled=OFF" >/dev/null 2>&1 || true
fi

if [[ "$JSON_ONLY" -ne 1 ]]; then
  echo "=== Start Slave ==="
fi
if ! mariadb_sql "$TARGET_POD" "$ROOT_PASSWORD" "START SLAVE${CHANNEL_CLAUSE}" >/dev/null; then
  SUMMARY="START SLAVE failed on pod=${TARGET_POD}"
  emit_result "$(result_json ERROR START_SLAVE_FAILED "$SUMMARY" "$TARGET_POD" "$SQL_PLAN_JSON" "" "[]")" ERROR "$SUMMARY"
fi

if [[ "$JSON_ONLY" -ne 1 ]]; then
  echo
  echo "=== Slave Status ==="
fi
SLAVE_STATUS_OUT=""
SLAVE_STATUS_OUT="$(mariadb_sql_vertical "$TARGET_POD" "$ROOT_PASSWORD" "SHOW ALL SLAVES STATUS" 2>/dev/null || true)"
if [[ "$JSON_ONLY" -ne 1 ]]; then
  printf '%s\n' "$SLAVE_STATUS_OUT"
fi

SUMMARY="Replication channel configured and started on pod=${TARGET_POD} host=${REPL_HOST}:${REPL_PORT} channel=${REPL_CHANNEL:-<default>}"
emit_result "$(result_json DONE REPLICATION_CONFIGURED "$SUMMARY" "$TARGET_POD" "$SQL_PLAN_JSON" "$SLAVE_STATUS_OUT" "[]")" DONE "$SUMMARY"
