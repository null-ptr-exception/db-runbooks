#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/migration/get-db-env.sh
# Read named environment variable values from a MariaDB pod.
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

CONTEXT="${K8S_CONTEXT:-${CONTEXT:-}}"
NAMESPACE="${DB_NAMESPACE:-${K8S_NAMESPACE:-}}"
RESOURCE="${MARIADB_RESOURCE:-mariadb}"
MDB="$MDB_INPUT"
CONTAINER="${MARIADB_CONTAINER:-mariadb}"
ENVS_STR="${ENVS_STR:-}"
RESULT_FILE="${AQSH_RESULT_FILE:-}"
JSON_ONLY=0

usage() {
  cat >&2 <<'EOF'
Usage:
  get-db-env.sh --namespace <namespace> --envs <VAR1,VAR2,...> [options]

Options:
  --context <context>      Kubernetes context. Optional for in-cluster AQSH.
  --resource <kind>        MariaDB CR kind. Default: mariadb.
  --mdb <name>             MariaDB CR / StatefulSet name. Default: auto-detected.
  --container <name>       MariaDB container name. Default: mariadb.
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)     require_value "$1" "${2:-}"; CONTEXT="$2";   shift 2 ;;
    --namespace)   require_value "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
    --resource)    require_value "$1" "${2:-}"; RESOURCE="$2";  shift 2 ;;
    --mdb | --name) require_value "$1" "${2:-}"; MDB="$2";      shift 2 ;;
    --container)   require_value "$1" "${2:-}"; CONTAINER="$2"; shift 2 ;;
    --envs)        require_value "$1" "${2:-}"; ENVS_STR="$2";  shift 2 ;;
    --json)        JSON_ONLY=1; shift ;;
    --result-file) require_value "$1" "${2:-}"; RESULT_FILE="$2"; shift 2 ;;
    -h | --help)   usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$NAMESPACE" ]]; then
  echo "error: --namespace is required" >&2
  usage
  exit 2
fi

if [[ -z "$ENVS_STR" ]]; then
  echo "error: --envs is required" >&2
  usage
  exit 2
fi

# shellcheck source=../../../lib/k8s.sh
source "${LIB_DIR}/k8s.sh"
# shellcheck source=../../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"

mariadb_set_target "$CONTEXT" "$NAMESPACE" "$RESOURCE" "$MDB" "$CONTAINER"

[[ "$JSON_ONLY" -ne 1 ]] && log_info "mariadb-get-db-env" "namespace=${NAMESPACE} mdb=${MDB:-<auto>} envs=${ENVS_STR}"

_emit_result() {
  local json="$1"
  [[ -n "$RESULT_FILE" ]] && printf '%s\n' "$json" > "$RESULT_FILE"
  printf '%s\n' "$json"
}

if ! k8s_check >/dev/null; then
  _emit_result "$(jq -nc \
    --arg context "${CONTEXT:-}" \
    --arg namespace "$NAMESPACE" \
    --arg resource "$RESOURCE" \
    --arg mdb "$MDB" \
    '{status:"CRITICAL", reason_code:"KUBECTL_UNAVAILABLE", summary:"Kubernetes API is not reachable",
      target:{context:$context, namespace:$namespace, resource:$resource, mdb:$mdb, pod:null},
      vars:{}}')"
  exit 0
fi

_emit_resolve_error() {
  local reason="$1" summary="$2" candidates="${3:-}"
  _emit_result "$(jq -nc \
    --arg context "${CONTEXT:-}" \
    --arg namespace "$NAMESPACE" \
    --arg resource "$RESOURCE" \
    --arg reason "$reason" \
    --arg summary "$summary" \
    --arg candidates "$candidates" \
    '{status:"CRITICAL", reason_code:$reason, summary:$summary,
      target:{context:$context, namespace:$namespace, resource:$resource, mdb:null, pod:null},
      candidates:($candidates | if . == "" then [] else (. / ",") end),
      vars:{}}')"
  exit 0
}
_on_ambiguous() { _emit_resolve_error MARIADB_AMBIGUOUS "Multiple MariaDB targets in namespace; specify --mdb" "$1"; }
_on_none()      { _emit_resolve_error MARIADB_NOT_FOUND "No MariaDB CR or StatefulSet found in namespace"; }

if [[ -z "$MDB" ]]; then
  mariadb_autodetect_target true _on_ambiguous _on_none
  MDB="$MARIADB_NAME"
  [[ "$JSON_ONLY" -ne 1 ]] && log_info "mariadb-get-db-env" "auto-detected mdb=${MDB}"
fi

# Resolve pod list via CR replicas first, then StatefulSet replicas.
CR_REPLICAS=""
if CR_JSON=$(_kubectl get "$RESOURCE" "$MDB" -o json 2>/dev/null); then
  CR_REPLICAS=$(printf '%s' "$CR_JSON" | jq -r '.spec.replicas // ""')
fi

STS_REPLICAS=""
if STS_JSON=$(_kubectl get statefulset "$MDB" -o json 2>/dev/null); then
  STS_REPLICAS=$(printf '%s' "$STS_JSON" | jq -r '.spec.replicas // ""')
fi

REPLICAS="${CR_REPLICAS:-$STS_REPLICAS}"
mapfile -t PODS < <(mariadb_list_pods "$REPLICAS")

if [[ "${#PODS[@]}" -eq 0 ]]; then
  _emit_result "$(jq -nc \
    --arg context "${CONTEXT:-}" \
    --arg namespace "$NAMESPACE" \
    --arg resource "$RESOURCE" \
    --arg mdb "$MDB" \
    '{status:"CRITICAL", reason_code:"NO_PODS_FOUND", summary:"No MariaDB pods found in namespace",
      target:{context:$context, namespace:$namespace, resource:$resource, mdb:$mdb, pod:null},
      vars:{}}')"
  exit 0
fi

POD="${PODS[0]}"
[[ "$JSON_ONLY" -ne 1 ]] && log_info "mariadb-get-db-env" "reading env vars from pod=${POD}"

# Fetch each requested env var via kubectl exec printenv.
# Values containing whitespace are preserved; unset vars produce null.
VARS_JSON="{}"
RETRIEVED=0
IFS=',' read -ra ENV_NAMES <<< "$ENVS_STR"
for raw_name in "${ENV_NAMES[@]}"; do
  name="${raw_name// /}"  # strip surrounding spaces
  [[ -z "$name" ]] && continue
  value=$(mariadb_exec "$POD" printenv "$name" 2>/dev/null) || true
  if [[ -n "$value" ]]; then
    VARS_JSON=$(printf '%s' "$VARS_JSON" | jq --arg k "$name" --arg v "$value" '. + {($k): $v}')
    RETRIEVED=$((RETRIEVED + 1))
  else
    VARS_JSON=$(printf '%s' "$VARS_JSON" | jq --arg k "$name" '. + {($k): null}')
  fi
done

TOTAL="${#ENV_NAMES[@]}"
RESULT_JSON=$(jq -nc \
  --arg status "OK" \
  --arg reason "GET_DB_ENV_OK" \
  --arg summary "Retrieved ${RETRIEVED}/${TOTAL} environment variables from ${POD}" \
  --arg context "${CONTEXT:-}" \
  --arg namespace "$NAMESPACE" \
  --arg resource "$RESOURCE" \
  --arg mdb "$MDB" \
  --arg pod "$POD" \
  --argjson vars "$VARS_JSON" \
  '{status:$status, reason_code:$reason, summary:$summary,
    target:{context:$context, namespace:$namespace, resource:$resource, mdb:$mdb, pod:$pod},
    vars:$vars}')

_emit_result "$RESULT_JSON"
