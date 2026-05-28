#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/status.sh
# Read-only MariaDB status summary for operator and native StatefulSet targets.
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

CONTEXT="${K8S_CONTEXT:-${CONTEXT:-}}"
NAMESPACE="${DB_NAMESPACE:-${K8S_NAMESPACE:-}}"
RESOURCE="${MARIADB_RESOURCE:-mariadb}"
MDB="${MARIADB_NAME:-${MARIADB_STS_NAME:-mariadb}}"
CONTAINER="${MARIADB_CONTAINER:-mariadb}"
INCLUDE_SQL="${INCLUDE_SQL:-true}"
RESULT_FILE="${AQSH_RESULT_FILE:-}"
JSON_ONLY=0

usage() {
  cat >&2 <<'EOF'
Usage:
  status.sh --namespace <namespace> [options]

Options:
  --context <context>      Kubernetes context. Optional for in-cluster AQSH.
  --resource <kind>        MariaDB CR kind. Default: mariadb.
  --mdb <name>             MariaDB CR / StatefulSet name. Default: mariadb.
  --container <name>       MariaDB container name. Default: mariadb.
  --skip-sql               Do not exec into pods for SQL role/readiness.
  --json                   Print only JSON to stdout.
  --result-file <path>     Write JSON result to this file.
EOF
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

json_bool() {
  case "${1:-false}" in
    1 | true | TRUE | yes | YES | on | ON) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

json_num_or_null() {
  case "${1:-}" in
    '' | *[!0-9]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) require_value "$1" "${2:-}"; CONTEXT="$2"; shift 2 ;;
    --namespace) require_value "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
    --resource) require_value "$1" "${2:-}"; RESOURCE="$2"; shift 2 ;;
    --mdb | --name) require_value "$1" "${2:-}"; MDB="$2"; shift 2 ;;
    --container) require_value "$1" "${2:-}"; CONTAINER="$2"; shift 2 ;;
    --skip-sql) INCLUDE_SQL=false; shift ;;
    --json) JSON_ONLY=1; shift ;;
    --result-file) require_value "$1" "${2:-}"; RESULT_FILE="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$NAMESPACE" ]]; then
  usage
  exit 2
fi

mariadb_set_target "$CONTEXT" "$NAMESPACE" "$RESOURCE" "$MDB" "$CONTAINER"

if [[ "$JSON_ONLY" -ne 1 ]]; then
  log_info "mariadb-status" "Collecting status for namespace=${NAMESPACE} mdb=${MDB}"
fi

if ! k8s_check >/dev/null; then
  RESULT_JSON=$(jq -nc \
    --arg namespace "$NAMESPACE" \
    --arg resource "$RESOURCE" \
    --arg mdb "$MDB" \
    '{status:"CRITICAL", reason_code:"KUBECTL_UNAVAILABLE", summary:"Kubernetes API is not reachable", target:{namespace:$namespace, resource:$resource, mdb:$mdb}}')
  [[ -n "$RESULT_FILE" ]] && printf '%s\n' "$RESULT_JSON" > "$RESULT_FILE"
  printf '%s\n' "$RESULT_JSON"
  exit 0
fi

CR_PRESENT=false
CR_READY=""
CURRENT_PRIMARY=""
CURRENT_PRIMARY_INDEX=""
CR_REPLICAS=""
if CR_JSON=$(_kubectl get "$RESOURCE" "$MDB" -o json 2>/dev/null); then
  CR_PRESENT=true
  CR_READY=$(printf '%s' "$CR_JSON" | jq -r '.status.conditions[]? | select(.type == "Ready") | .status' | head -1)
  CURRENT_PRIMARY=$(printf '%s' "$CR_JSON" | jq -r '.status.currentPrimary // ""')
  CURRENT_PRIMARY_INDEX=$(printf '%s' "$CR_JSON" | jq -r '.status.currentPrimaryPodIndex // ""')
  CR_REPLICAS=$(printf '%s' "$CR_JSON" | jq -r '.spec.replicas // ""')
fi

STS_PRESENT=false
STS_REPLICAS=""
STS_READY_REPLICAS=""
STS_OBSERVED_GENERATION=""
STS_UPDATE_STRATEGY=""
if STS_JSON=$(_kubectl get statefulset "$MDB" -o json 2>/dev/null); then
  STS_PRESENT=true
  STS_REPLICAS=$(printf '%s' "$STS_JSON" | jq -r '.spec.replicas // ""')
  STS_READY_REPLICAS=$(printf '%s' "$STS_JSON" | jq -r '.status.readyReplicas // 0')
  STS_OBSERVED_GENERATION=$(printf '%s' "$STS_JSON" | jq -r '.status.observedGeneration // ""')
  STS_UPDATE_STRATEGY=$(printf '%s' "$STS_JSON" | jq -r '.spec.updateStrategy.type // ""')
fi

REPLICAS="${CR_REPLICAS:-$STS_REPLICAS}"
if [[ -z "$CURRENT_PRIMARY" && -n "$CURRENT_PRIMARY_INDEX" ]]; then
  CURRENT_PRIMARY=$(mariadb_pod_name "$CURRENT_PRIMARY_INDEX")
fi

mapfile -t PODS < <(mariadb_list_pods "$REPLICAS")

ROOT_PASSWORD=""
ROOT_PASSWORD_AVAILABLE=false
if bool_enabled "$INCLUDE_SQL" && [[ "${#PODS[@]}" -gt 0 ]]; then
  if ROOT_PASSWORD=$(mariadb_read_root_password "$CURRENT_PRIMARY" "${PODS[@]}"); then
    ROOT_PASSWORD_AVAILABLE=true
  fi
fi

PODS_JSON="[]"
for pod in "${PODS[@]}"; do
  phase=$(mariadb_pod_jsonpath "$pod" '{.status.phase}' || true)
  ready=$(mariadb_pod_jsonpath "$pod" "{.status.containerStatuses[?(@.name==\"${CONTAINER}\")].ready}" || true)
  restarts=$(mariadb_pod_jsonpath "$pod" "{.status.containerStatuses[?(@.name==\"${CONTAINER}\")].restartCount}" || true)
  read_only=""
  sql_ready=false
  role="unknown"

  if [[ -n "$ROOT_PASSWORD" ]]; then
    if mariadb_sql "$pod" "$ROOT_PASSWORD" 'SELECT 1' >/dev/null; then
      sql_ready=true
      read_only=$(mariadb_sql "$pod" "$ROOT_PASSWORD" 'SELECT @@read_only' || true)
      case "$read_only" in
        0) role="primary" ;;
        1) role="replica" ;;
      esac
    fi
  elif [[ "$pod" == "$CURRENT_PRIMARY" ]]; then
    role="primary"
  fi

  PODS_JSON=$(jq -c \
    --arg name "$pod" \
    --arg phase "${phase:-}" \
    --arg ready "$(json_bool "$ready")" \
    --argjson restarts "$(json_num_or_null "$restarts")" \
    --arg role "$role" \
    --arg read_only "$read_only" \
    --arg sql_ready "$(json_bool "$sql_ready")" \
    '. + [{
      name: $name,
      phase: ($phase | if . == "" then null else . end),
      ready: ($ready == "true"),
      restarts: $restarts,
      role: $role,
      read_only: ($read_only | if . == "" then null else . end),
      sql_ready: ($sql_ready == "true")
    }]' <<<"$PODS_JSON")
done

STATUS="OK"
REASON="MARIADB_STATUS_OK"
SUMMARY="MariaDB status is healthy"

if [[ "$STS_PRESENT" != "true" && "${#PODS[@]}" -eq 0 ]]; then
  STATUS="CRITICAL"
  REASON="MARIADB_NOT_FOUND"
  SUMMARY="MariaDB StatefulSet and pods were not found"
elif [[ -n "$STS_REPLICAS" && "$STS_READY_REPLICAS" != "$STS_REPLICAS" ]]; then
  STATUS="WARN"
  REASON="MARIADB_REPLICAS_NOT_READY"
  SUMMARY="MariaDB has unavailable replicas"
elif bool_enabled "$INCLUDE_SQL" && [[ "$ROOT_PASSWORD_AVAILABLE" != "true" ]]; then
  STATUS="WARN"
  REASON="MARIADB_SQL_STATUS_UNAVAILABLE"
  SUMMARY="MariaDB Kubernetes status is available but SQL status could not be collected"
elif [[ "$CR_PRESENT" == "true" && -n "$CR_READY" && "$CR_READY" != "True" ]]; then
  STATUS="WARN"
  REASON="MARIADB_CR_NOT_READY"
  SUMMARY="MariaDB CR is not Ready"
fi

RESULT_JSON=$(jq -nc \
  --arg status "$STATUS" \
  --arg reason "$REASON" \
  --arg summary "$SUMMARY" \
  --arg context "${CONTEXT:-}" \
  --arg namespace "$NAMESPACE" \
  --arg resource "$RESOURCE" \
  --arg mdb "$MDB" \
  --argjson cr_present "$(json_bool "$CR_PRESENT")" \
  --arg cr_ready "$CR_READY" \
  --arg current_primary "$CURRENT_PRIMARY" \
  --arg current_primary_index "$CURRENT_PRIMARY_INDEX" \
  --argjson cr_replicas "$(json_num_or_null "$CR_REPLICAS")" \
  --argjson sts_present "$(json_bool "$STS_PRESENT")" \
  --argjson sts_replicas "$(json_num_or_null "$STS_REPLICAS")" \
  --argjson ready_replicas "$(json_num_or_null "$STS_READY_REPLICAS")" \
  --argjson observed_generation "$(json_num_or_null "$STS_OBSERVED_GENERATION")" \
  --arg update_strategy "$STS_UPDATE_STRATEGY" \
  --argjson include_sql "$(json_bool "$INCLUDE_SQL")" \
  --argjson root_password_available "$(json_bool "$ROOT_PASSWORD_AVAILABLE")" \
  --argjson pods "$PODS_JSON" \
  '{
    status: $status,
    reason_code: $reason,
    summary: $summary,
    target: {context: $context, namespace: $namespace, resource: $resource, mdb: $mdb},
    operator: {
      present: $cr_present,
      ready: ($cr_ready | if . == "" then null else . end),
      current_primary: ($current_primary | if . == "" then null else . end),
      current_primary_pod_index: ($current_primary_index | if . == "" then null else . end),
      replicas: $cr_replicas
    },
    statefulset: {
      present: $sts_present,
      replicas: $sts_replicas,
      ready_replicas: $ready_replicas,
      observed_generation: $observed_generation,
      update_strategy: ($update_strategy | if . == "" then null else . end)
    },
    sql: {
      checked: $include_sql,
      root_password_available: $root_password_available
    },
    pods: $pods
  }')

[[ -n "$RESULT_FILE" ]] && printf '%s\n' "$RESULT_JSON" > "$RESULT_FILE"
printf '%s\n' "$RESULT_JSON"
