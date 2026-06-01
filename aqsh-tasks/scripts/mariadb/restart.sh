#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/restart.sh
# Role-aware restart of a MariaDB cluster (operator CR or native StatefulSet).
#
# Unlike a blind `kubectl rollout restart`, this task understands MariaDB roles:
#   - It discovers the current primary and replicas before touching anything.
#   - It restarts replicas first, one by one, and the primary last (and only
#     when explicitly allowed).
#   - It restarts pods individually with `kubectl delete pod`, waiting for each
#     to become Ready before moving on, so the cluster is never degraded by
#     more than one intentional pod at a time.
#   - It is conservative by default: dry-run prints the plan and changes nothing.
#   - It detects whether the primary role moved during the operation and treats
#     an unexpected move as an error.
#
# This task does NOT promote replicas or patch operator/Service state. Use
# promote-replica for explicit role changes.
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
  restart.sh --namespace <namespace> [options]

Options:
  --context <context>            Kubernetes context. Optional for in-cluster AQSH.
  --resource <kind>              MariaDB CR kind. Default: mariadb.
  --mdb <name>                   MariaDB CR / StatefulSet name. Default: mariadb.
  --container <name>             MariaDB container name. Default: mariadb.
  --target-pod <pod>             Restart only this pod instead of the whole cluster.
  --include-primary <true|false> Allow restarting the current primary. Default: false.
  --allow-role-change <bool>     Tolerate a primary role move during restart. Default: false.
  --wait-timeout <sec>           Per-pod readiness timeout in seconds. Default: 300.
  --dry-run <true|false>         Plan only, change nothing. Default: true.
  --confirm <true|false>         Required with --dry-run false. Default: false.
  --json                         Print only JSON result to stdout.
  --result-file <path>           Write JSON result to this file.
EOF
}

require_value() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo "error: $1 requires a value" >&2
    exit 2
  fi
}

is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
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

# Emit a JSON array from the remaining arguments (each becomes a string element).
json_string_array() {
  if [[ $# -eq 0 ]]; then
    printf '[]'
    return 0
  fi
  printf '%s\n' "$@" | jq -R . | jq -cs .
}

CONTEXT="${K8S_CONTEXT:-${CONTEXT:-}}"
NAMESPACE="${DB_NAMESPACE:-${K8S_NAMESPACE:-}}"
RESOURCE="${MARIADB_RESOURCE:-mariadb}"
MDB="${MARIADB_NAME:-${MARIADB_STS_NAME:-mariadb}}"
CONTAINER="${MARIADB_CONTAINER:-mariadb}"
TARGET_POD="${TARGET_POD:-}"
INCLUDE_PRIMARY="${INCLUDE_PRIMARY:-false}"
ALLOW_ROLE_CHANGE="${ALLOW_ROLE_CHANGE:-false}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"
RESULT_FILE="${AQSH_RESULT_FILE:-}"
JSON_ONLY=0

PRIMARY_BEFORE=""
PRIMARY_AFTER=""
UPDATE_STRATEGY=""
RESTART_ERROR_REASON=""
RESTART_ERROR_SUMMARY=""
RESTART_POD_DELETED=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) require_value "$1" "${2:-}"; CONTEXT="$2"; shift 2 ;;
    --namespace) require_value "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
    --resource) require_value "$1" "${2:-}"; RESOURCE="$2"; shift 2 ;;
    --mdb | --name) require_value "$1" "${2:-}"; MDB="$2"; shift 2 ;;
    --container) require_value "$1" "${2:-}"; CONTAINER="$2"; shift 2 ;;
    --target-pod) require_value "$1" "${2:-}"; TARGET_POD="$2"; shift 2 ;;
    --include-primary) require_value "$1" "${2:-}"; INCLUDE_PRIMARY="$2"; shift 2 ;;
    --allow-role-change) require_value "$1" "${2:-}"; ALLOW_ROLE_CHANGE="$2"; shift 2 ;;
    --wait-timeout) require_value "$1" "${2:-}"; WAIT_TIMEOUT="$2"; shift 2 ;;
    --dry-run) require_value "$1" "${2:-}"; DRY_RUN="$2"; shift 2 ;;
    --confirm) require_value "$1" "${2:-}"; CONFIRM="$2"; shift 2 ;;
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

if ! is_uint "$WAIT_TIMEOUT"; then
  echo "error: WAIT_TIMEOUT must be an unsigned integer (got: ${WAIT_TIMEOUT})" >&2
  exit 2
fi

mariadb_set_target "$CONTEXT" "$NAMESPACE" "$RESOURCE" "$MDB" "$CONTAINER"

# -----------------------------------------------------------------------------
# emit_result <status> <reason> <summary> <changed> [restart_order_json] [pods_json]
# -----------------------------------------------------------------------------
emit_result() {
  local status="$1"
  local reason="$2"
  local summary="$3"
  local changed="$4"
  local restart_order_json="${5:-[]}"
  local pods_json="${6:-[]}"

  RESULT_JSON=$(jq -nc \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg summary "$summary" \
    --arg context "${CONTEXT:-}" \
    --arg namespace "$NAMESPACE" \
    --arg resource "$RESOURCE" \
    --arg mdb "$MDB" \
    --arg update_strategy "${UPDATE_STRATEGY:-}" \
    --arg primary_before "${PRIMARY_BEFORE:-}" \
    --arg primary_after "${PRIMARY_AFTER:-}" \
    --argjson dry_run "$(json_bool "$DRY_RUN")" \
    --argjson confirm "$(json_bool "$CONFIRM")" \
    --argjson include_primary "$(json_bool "$INCLUDE_PRIMARY")" \
    --argjson allow_role_change "$(json_bool "$ALLOW_ROLE_CHANGE")" \
    --argjson changed "$(json_bool "$changed")" \
    --argjson restart_order "$restart_order_json" \
    --argjson pods "$pods_json" \
    '{
      status: $status,
      reason_code: $reason,
      summary: $summary,
      target: {
        context: ($context | if . == "" then null else . end),
        namespace: $namespace,
        resource: $resource,
        mdb: $mdb,
        update_strategy: ($update_strategy | if . == "" then null else . end)
      },
      dry_run: $dry_run,
      confirm: $confirm,
      include_primary: $include_primary,
      allow_role_change: $allow_role_change,
      changed: $changed,
      primary_before: ($primary_before | if . == "" then null else . end),
      primary_after: ($primary_after | if . == "" then null else . end),
      restart_order: $restart_order,
      pods: $pods
    }')

  [[ -n "$RESULT_FILE" ]] && printf '%s\n' "$RESULT_JSON" > "$RESULT_FILE"
  printf '%s\n' "$RESULT_JSON"
}

# Resolve the current primary pod from operator CR status, then fall back to an
# SQL read_only==0 probe when credentials are available.
resolve_primary() {
  local primary index pod read_only
  primary=$(mariadb_jsonpath "$RESOURCE" "$MDB" '{.status.currentPrimary}' 2>/dev/null || true)
  if [[ -z "$primary" ]]; then
    index=$(mariadb_jsonpath "$RESOURCE" "$MDB" '{.status.currentPrimaryPodIndex}' 2>/dev/null || true)
    [[ -n "$index" ]] && primary=$(mariadb_pod_name "$index")
  fi
  if [[ -z "$primary" && -n "${ROOT_PASSWORD:-}" ]]; then
    for pod in "${PODS[@]}"; do
      read_only=$(mariadb_sql "$pod" "$ROOT_PASSWORD" 'SELECT @@read_only' 2>/dev/null || true)
      if [[ "$read_only" == "0" ]]; then
        primary="$pod"
        break
      fi
    done
  fi
  printf '%s' "$primary"
}

pod_ready() {
  local pod="$1" ready
  ready=$(mariadb_pod_jsonpath "$pod" \
    "{.status.containerStatuses[?(@.name==\"${CONTAINER}\")].ready}" 2>/dev/null || true)
  [[ "$ready" == "true" ]]
}

# Restart one pod by deleting it and waiting for the controller to recreate it
# and report Ready again, up to WAIT_TIMEOUT seconds.
restart_pod_and_wait() {
  local pod="$1" start now old_uid new_uid delete_out
  RESTART_ERROR_REASON=""
  RESTART_ERROR_SUMMARY=""
  RESTART_POD_DELETED=false
  # Record the pod UID first so we can confirm the pod was actually recreated,
  # not just observed Ready on the old (still-terminating) object whose
  # containerStatus may briefly report ready=true.
  old_uid=$(mariadb_pod_jsonpath "$pod" '{.metadata.uid}' 2>/dev/null || true)
  # `kubectl delete pod` is intentionally synchronous: it blocks until the old
  # pod is gone, so the readiness poll below sees the freshly recreated pod.
  # Do NOT switch this to a non-blocking delete (--wait=false) — the UID guard
  # would then race the still-present old pod.
  if ! delete_out=$(_kubectl delete pod "$pod" --timeout="${WAIT_TIMEOUT}s" 2>&1); then
    RESTART_ERROR_REASON="RESTART_DELETE_FAILED"
    RESTART_ERROR_SUMMARY="Failed to delete pod ${pod}: ${delete_out:-kubectl delete failed}"
    return 1
  fi
  RESTART_POD_DELETED=true
  start=$(date +%s)
  while true; do
    new_uid=$(mariadb_pod_jsonpath "$pod" '{.metadata.uid}' 2>/dev/null || true)
    # Require a different UID (genuine recreation) AND Ready.
    if [[ -n "$new_uid" && "$new_uid" != "$old_uid" ]] && pod_ready "$pod"; then
      return 0
    fi
    now=$(date +%s)
    if (( now - start >= WAIT_TIMEOUT )); then
      RESTART_ERROR_REASON="RESTART_POD_NOT_READY"
      RESTART_ERROR_SUMMARY="Pod ${pod} did not become Ready within ${WAIT_TIMEOUT}s; restart halted"
      return 1
    fi
    sleep 5
  done
}

if [[ "$JSON_ONLY" -ne 1 ]]; then
  log_info "mariadb-restart" "Planning role-aware restart for namespace=${NAMESPACE} mdb=${MDB} (dry_run=${DRY_RUN})"
fi

if ! k8s_check >/dev/null; then
  emit_result "ERROR" "KUBECTL_UNAVAILABLE" "Kubernetes API is not reachable" false
  exit 0
fi

# --- Topology discovery -------------------------------------------------------
UPDATE_STRATEGY=$(mariadb_jsonpath statefulset "$MDB" '{.spec.updateStrategy.type}' 2>/dev/null || true)
STS_PRESENT=false
[[ -n "$(mariadb_jsonpath statefulset "$MDB" '{.metadata.name}' 2>/dev/null || true)" ]] && STS_PRESENT=true

REPLICAS=$(mariadb_cr_replicas 2>/dev/null || true)
[[ -z "$REPLICAS" ]] && REPLICAS=$(mariadb_sts_replicas 2>/dev/null || true)
mapfile -t PODS < <(mariadb_list_pods "$REPLICAS")

if [[ "$STS_PRESENT" != "true" && "${#PODS[@]}" -eq 0 ]]; then
  emit_result "BLOCKED" "MARIADB_NOT_FOUND" "MariaDB StatefulSet and pods were not found" false
  exit 0
fi

ROOT_PASSWORD=""
if [[ "${#PODS[@]}" -gt 0 ]]; then
  ROOT_PASSWORD=$(mariadb_read_root_password "" "${PODS[@]}" 2>/dev/null || true)
fi

PRIMARY_BEFORE=$(resolve_primary)

# --- Per-pod role + readiness snapshot ---------------------------------------
PODS_JSON="[]"
declare -A POD_READY
for pod in "${PODS[@]}"; do
  ready=false
  pod_ready "$pod" && ready=true
  POD_READY["$pod"]="$ready"

  role="unknown"
  if [[ -n "$pod" && "$pod" == "$PRIMARY_BEFORE" ]]; then
    role="primary"
  elif [[ -n "$ROOT_PASSWORD" ]]; then
    read_only=$(mariadb_sql "$pod" "$ROOT_PASSWORD" 'SELECT @@read_only' 2>/dev/null || true)
    case "$read_only" in
      0) role="primary" ;;
      1) role="replica" ;;
    esac
  fi

  PODS_JSON=$(jq -c \
    --arg name "$pod" \
    --arg role "$role" \
    --argjson ready "$(json_bool "$ready")" \
    '. + [{name: $name, role: $role, ready_before: $ready, restarted: false, ready_after: null}]' \
    <<<"$PODS_JSON")
done

# Role-aware restart is meaningless without knowing the primary: replica-first
# ordering can't exclude a primary it can't name, and a default restart would
# then silently cycle the real primary too. Refuse before building any order.
if [[ -z "$PRIMARY_BEFORE" ]]; then
  emit_result "BLOCKED" "PRIMARY_UNKNOWN" \
    "Cannot identify the current primary; refusing to restart without role awareness" false \
    "[]" "$PODS_JSON"
  exit 0
fi

# --- Build restart order ------------------------------------------------------
RESTART_ORDER=()
if [[ -n "$TARGET_POD" ]]; then
  pod_found=false
  for pod in "${PODS[@]}"; do
    [[ "$pod" == "$TARGET_POD" ]] && { pod_found=true; break; }
  done
  if [[ "$pod_found" != "true" ]]; then
    emit_result "BLOCKED" "TARGET_POD_NOT_FOUND" "Target pod was not found in the MariaDB cluster" false \
      "$(json_string_array "${PODS[@]}")" "$PODS_JSON"
    exit 0
  fi
  if [[ "$TARGET_POD" == "$PRIMARY_BEFORE" ]] && ! bool_enabled "$INCLUDE_PRIMARY"; then
    emit_result "BLOCKED" "PRIMARY_RESTART_NOT_ALLOWED" \
      "Target pod is the current primary; set include_primary=true to restart it" false \
      "[]" "$PODS_JSON"
    exit 0
  fi
  RESTART_ORDER=("$TARGET_POD")
else
  # Replicas first (every pod that is not the primary), primary last if allowed.
  for pod in "${PODS[@]}"; do
    [[ "$pod" == "$PRIMARY_BEFORE" ]] && continue
    RESTART_ORDER+=("$pod")
  done
  if [[ -n "$PRIMARY_BEFORE" ]] && bool_enabled "$INCLUDE_PRIMARY"; then
    RESTART_ORDER+=("$PRIMARY_BEFORE")
  fi
fi

if [[ "${#RESTART_ORDER[@]}" -eq 0 ]]; then
  emit_result "BLOCKED" "NO_RESTART_TARGETS" \
    "No pods selected for restart (primary excluded; set include_primary=true to include it)" false \
    "[]" "$PODS_JSON"
  exit 0
fi

ORDER_JSON=$(json_string_array "${RESTART_ORDER[@]}")

# --- Conservative health gate: peers (pods not being restarted) must be Ready -
declare -A IN_SCOPE
for pod in "${RESTART_ORDER[@]}"; do
  IN_SCOPE["$pod"]=1
done
for pod in "${PODS[@]}"; do
  [[ -n "${IN_SCOPE[$pod]:-}" ]] && continue
  if [[ "${POD_READY[$pod]}" != "true" ]]; then
    emit_result "BLOCKED" "PEER_POD_NOT_READY" \
      "A pod not selected for restart is not Ready; cluster looks degraded" false \
      "$ORDER_JSON" "$PODS_JSON"
    exit 0
  fi
done

# --- Dry-run: report the plan and stop ---------------------------------------
if bool_enabled "$DRY_RUN"; then
  emit_result "READY" "RESTART_DRY_RUN" \
    "Dry-run made no changes; restart_order lists the planned per-pod restart sequence" false \
    "$ORDER_JSON" "$PODS_JSON"
  exit 0
fi

if ! bool_enabled "$CONFIRM"; then
  emit_result "BLOCKED" "RESTART_CONFIRM_REQUIRED" \
    "Set confirm=true with dry_run=false to perform the restart" false \
    "$ORDER_JSON" "$PODS_JSON"
  exit 0
fi

# --- Execute: restart pods one by one, waiting for Ready between each ---------
RESTART_FAILED=""
ANY_RESTARTED=false
for pod in "${RESTART_ORDER[@]}"; do
  if [[ "$JSON_ONLY" -ne 1 ]]; then
    log_info "mariadb-restart" "Restarting pod ${pod}"
  fi
  ready_after=false
  if restart_pod_and_wait "$pod"; then
    ready_after=true
  fi
  [[ "$RESTART_POD_DELETED" == "true" ]] && ANY_RESTARTED=true
  PODS_JSON=$(jq -c \
    --arg name "$pod" \
    --argjson restarted "$(json_bool "$RESTART_POD_DELETED")" \
    --argjson ready_after "$(json_bool "$ready_after")" \
    'map(if .name == $name then (.restarted = $restarted | .ready_after = $ready_after) else . end)' \
    <<<"$PODS_JSON")
  if [[ "$ready_after" != "true" ]]; then
    RESTART_FAILED="$pod"
    break
  fi
done

if [[ -n "$RESTART_FAILED" ]]; then
  PRIMARY_AFTER=$(resolve_primary)
  emit_result "ERROR" "${RESTART_ERROR_REASON:-RESTART_POD_NOT_READY}" \
    "${RESTART_ERROR_SUMMARY:-Pod ${RESTART_FAILED} did not become Ready within ${WAIT_TIMEOUT}s; restart halted}" "$ANY_RESTARTED" \
    "$ORDER_JSON" "$PODS_JSON"
  exit 0
fi

# --- Post-restart role-change detection --------------------------------------
PRIMARY_AFTER=$(resolve_primary)

if [[ -n "$PRIMARY_BEFORE" && -n "$PRIMARY_AFTER" && "$PRIMARY_BEFORE" != "$PRIMARY_AFTER" ]]; then
  if bool_enabled "$ALLOW_ROLE_CHANGE"; then
    emit_result "WARN" "ROLE_CHANGED" \
      "Restart completed but the primary role moved (${PRIMARY_BEFORE} -> ${PRIMARY_AFTER})" true \
      "$ORDER_JSON" "$PODS_JSON"
  else
    emit_result "ERROR" "ROLE_CHANGED" \
      "Restart completed but the primary role moved unexpectedly (${PRIMARY_BEFORE} -> ${PRIMARY_AFTER})" true \
      "$ORDER_JSON" "$PODS_JSON"
  fi
  exit 0
fi

emit_result "RESTARTED" "RESTART_COMPLETED" \
  "All selected pods were restarted and became Ready; primary role unchanged" true \
  "$ORDER_JSON" "$PODS_JSON"
