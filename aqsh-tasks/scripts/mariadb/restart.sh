#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/restart.sh
# Operator-driven restart of a MariaDB cluster.
#
# AQSH does not delete MariaDB Pods or decide the rollout order. It patches a
# MariaDB CR Pod-template annotation and lets mariadb-operator reconcile the
# restart according to spec.updateStrategy (for example ReplicasFirstPrimaryLast).
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
  --mdb <name>                   MariaDB CR name. Default: mariadb.
  --container <name>             MariaDB container name. Default: mariadb.
  --allow-role-change <bool>     Tolerate a primary role move during restart. Default: false.
  --wait-timeout <sec>           Operator restart wait timeout in seconds. Default: 300.
  --dry-run <true|false>         Plan only, change nothing. Default: true.
  --confirm <true|false>         Required with --dry-run false. Default: false.
  --annotation-key <key>         Pod template annotation patched on the MariaDB CR.
  --metadata-field <field>       podMetadata, inheritMetadata, or auto. Default: auto.
  --json                         Print only JSON result to stdout.
  --result-file <path>           Write JSON result to this file.

Deprecated compatibility options:
  --target-pod <pod>             Unsupported; operator-driven restart is resource-scoped.
  --include-primary <true|false> Ignored; mariadb-operator decides rollout order.
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

json_string_array() {
  if [[ $# -eq 0 ]]; then
    printf '[]'
    return 0
  fi
  printf '%s\n' "$@" | jq -R . | jq -cs .
}

json_num_or_null() {
  case "${1:-}" in
    '' | *[!0-9]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
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
ANNOTATION_KEY="${RESTART_ANNOTATION_KEY:-aqsh.null-ptr-exception.dev/restarted-at}"
RESTART_METADATA_FIELD="${RESTART_METADATA_FIELD:-auto}"
METADATA_FIELD=""
RESULT_FILE="${AQSH_RESULT_FILE:-}"
JSON_ONLY=0

PRIMARY_BEFORE=""
PRIMARY_AFTER=""
UPDATE_STRATEGY=""
REPLICAS=""
PATCH_VALUE=""
PATCH_OUT=""
RESULT_JSON=""

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
    --annotation-key) require_value "$1" "${2:-}"; ANNOTATION_KEY="$2"; shift 2 ;;
    --metadata-field) require_value "$1" "${2:-}"; RESTART_METADATA_FIELD="$2"; shift 2 ;;
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

emit_result() {
  local status="$1"
  local reason="$2"
  local summary="$3"
  local changed="$4"
  local pods_json="${5:-[]}"

  RESULT_JSON=$(jq -nc \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg summary "$summary" \
    --arg context "${CONTEXT:-}" \
    --arg namespace "$NAMESPACE" \
    --arg resource "$RESOURCE" \
    --arg mdb "$MDB" \
    --arg update_strategy "${UPDATE_STRATEGY:-}" \
    --arg annotation_key "$ANNOTATION_KEY" \
    --arg annotation_value "${PATCH_VALUE:-}" \
    --arg metadata_field "${METADATA_FIELD:-}" \
    --arg primary_before "${PRIMARY_BEFORE:-}" \
    --arg primary_after "${PRIMARY_AFTER:-}" \
    --argjson replicas "$(json_num_or_null "$REPLICAS")" \
    --argjson dry_run "$(json_bool "$DRY_RUN")" \
    --argjson confirm "$(json_bool "$CONFIRM")" \
    --argjson allow_role_change "$(json_bool "$ALLOW_ROLE_CHANGE")" \
    --argjson changed "$(json_bool "$changed")" \
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
        update_strategy: ($update_strategy | if . == "" then null else . end),
        replicas: $replicas
      },
      operator_controlled: true,
      annotation: {
        metadata_field: ($metadata_field | if . == "" then null else . end),
        key: $annotation_key,
        value: ($annotation_value | if . == "" then null else . end)
      },
      dry_run: $dry_run,
      confirm: $confirm,
      allow_role_change: $allow_role_change,
      changed: $changed,
      primary_before: ($primary_before | if . == "" then null else . end),
      primary_after: ($primary_after | if . == "" then null else . end),
      restart_order: [],
      pods: $pods
    }')

  [[ -n "$RESULT_FILE" ]] && printf '%s\n' "$RESULT_JSON" > "$RESULT_FILE"
  printf '%s\n' "$RESULT_JSON"
}

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

build_pods_json() {
  local pods_json="[]" pod ready role read_only uid restarted ready_after

  for pod in "${PODS[@]}"; do
    ready=false
    pod_ready "$pod" && ready=true

    role="unknown"
    if [[ -n "$pod" && "$pod" == "$PRIMARY_BEFORE" ]]; then
      role="primary"
    elif [[ -n "${ROOT_PASSWORD:-}" ]]; then
      read_only=$(mariadb_sql "$pod" "$ROOT_PASSWORD" 'SELECT @@read_only' 2>/dev/null || true)
      case "$read_only" in
        0) role="primary" ;;
        1) role="replica" ;;
      esac
    fi

    uid=$(mariadb_pod_jsonpath "$pod" '{.metadata.uid}' 2>/dev/null || true)
    restarted=false
    ready_after=null
    if [[ -n "${POD_RESTARTED[$pod]:-}" ]]; then
      restarted="${POD_RESTARTED[$pod]}"
      ready_after="${POD_READY_AFTER[$pod]:-false}"
    fi

    pods_json=$(jq -c \
      --arg name "$pod" \
      --arg role "$role" \
      --arg uid "$uid" \
      --argjson ready "$(json_bool "$ready")" \
      --argjson restarted "$(json_bool "$restarted")" \
      --argjson ready_after "$ready_after" \
      '. + [{
        name: $name,
        role: $role,
        uid_before: ($uid | if . == "" then null else . end),
        ready_before: $ready,
        restarted: $restarted,
        ready_after: $ready_after
      }]' \
      <<<"$pods_json")
  done

  printf '%s' "$pods_json"
}

patch_restart_annotation() {
  local patch_json
  PATCH_VALUE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  patch_json=$(jq -nc \
    --arg field "$METADATA_FIELD" \
    --arg key "$ANNOTATION_KEY" \
    --arg value "$PATCH_VALUE" \
    '{spec: {($field): {annotations: {($key): $value}}}}')

  _kubectl patch "$RESOURCE" "$MDB" --type merge -p "$patch_json" 2>&1
}

metadata_field_supported() {
  local field="${1:?field is required}"
  _kubectl_global explain "${RESOURCE}.spec.${field}" >/dev/null 2>&1
}

select_restart_metadata_field() {
  case "$RESTART_METADATA_FIELD" in
    auto)
      if metadata_field_supported "podMetadata"; then
        METADATA_FIELD="podMetadata"
        return 0
      fi
      if metadata_field_supported "inheritMetadata"; then
        METADATA_FIELD="inheritMetadata"
        return 0
      fi
      return 1
      ;;
    podMetadata | inheritMetadata)
      METADATA_FIELD="$RESTART_METADATA_FIELD"
      metadata_field_supported "$METADATA_FIELD"
      ;;
    *)
      return 2
      ;;
  esac
}

wait_for_operator_restart() {
  local start now pod old_uid new_uid all_restarted

  start=$(date +%s)
  while true; do
    all_restarted=true
    for pod in "${PODS[@]}"; do
      old_uid="${POD_UID_BEFORE[$pod]:-}"
      new_uid=$(mariadb_pod_jsonpath "$pod" '{.metadata.uid}' 2>/dev/null || true)
      if [[ -n "$new_uid" && -n "$old_uid" && "$new_uid" != "$old_uid" ]] && pod_ready "$pod"; then
        POD_RESTARTED["$pod"]=true
        POD_READY_AFTER["$pod"]=true
      else
        all_restarted=false
        if [[ -n "$new_uid" && -n "$old_uid" && "$new_uid" != "$old_uid" ]]; then
          POD_RESTARTED["$pod"]=true
        fi
        pod_ready "$pod" && POD_READY_AFTER["$pod"]=true || POD_READY_AFTER["$pod"]=false
      fi
    done

    [[ "$all_restarted" == "true" ]] && return 0

    now=$(date +%s)
    if (( now - start >= WAIT_TIMEOUT )); then
      return 1
    fi
    sleep 5
  done
}

if [[ "$JSON_ONLY" -ne 1 ]]; then
  log_info "mariadb-restart" "Planning operator-driven restart for namespace=${NAMESPACE} mdb=${MDB} (dry_run=${DRY_RUN})"
fi

if ! k8s_check >/dev/null; then
  emit_result "ERROR" "KUBECTL_UNAVAILABLE" "Kubernetes API is not reachable" false
  exit 0
fi

if [[ -n "$TARGET_POD" ]]; then
  emit_result "BLOCKED" "TARGET_POD_UNSUPPORTED" \
    "Operator-driven restart is scoped to the MariaDB resource; target_pod is not supported" false
  exit 0
fi

if ! mariadb_jsonpath "$RESOURCE" "$MDB" '{.metadata.name}' >/dev/null 2>&1; then
  emit_result "BLOCKED" "MARIADB_OPERATOR_REQUIRED" \
    "MariaDB CR was not found; operator-driven restart requires a mariadb-operator resource" false
  exit 0
fi

select_status=0
select_restart_metadata_field || select_status=$?
if [[ "$select_status" -ne 0 ]]; then
  case "$select_status" in
    2)
      emit_result "BLOCKED" "RESTART_METADATA_FIELD_INVALID" \
        "restart metadata field must be podMetadata, inheritMetadata, or auto" false
      ;;
    *)
      emit_result "BLOCKED" "RESTART_METADATA_FIELD_UNSUPPORTED" \
        "MariaDB CRD does not expose spec.podMetadata or spec.inheritMetadata for operator-driven restart annotation" false
      ;;
  esac
  exit 0
fi

UPDATE_STRATEGY=$(mariadb_jsonpath "$RESOURCE" "$MDB" '{.spec.updateStrategy.type}' 2>/dev/null || true)
[[ -z "$UPDATE_STRATEGY" ]] && UPDATE_STRATEGY="ReplicasFirstPrimaryLast"

REPLICAS=$(mariadb_cr_replicas 2>/dev/null || true)
mapfile -t PODS < <(mariadb_list_pods "$REPLICAS")

ROOT_PASSWORD=""
if [[ "${#PODS[@]}" -gt 0 ]]; then
  ROOT_PASSWORD=$(mariadb_read_root_password "" "${PODS[@]}" 2>/dev/null || true)
fi

PRIMARY_BEFORE=$(resolve_primary)

declare -A POD_UID_BEFORE
declare -A POD_RESTARTED
declare -A POD_READY_AFTER

for pod in "${PODS[@]}"; do
  POD_UID_BEFORE["$pod"]=$(mariadb_pod_jsonpath "$pod" '{.metadata.uid}' 2>/dev/null || true)
  POD_RESTARTED["$pod"]=false
  POD_READY_AFTER["$pod"]=null
done

PODS_JSON=$(build_pods_json)

if [[ "${#PODS[@]}" -eq 0 ]]; then
  emit_result "BLOCKED" "MARIADB_PODS_NOT_FOUND" "MariaDB CR exists, but no MariaDB pods were found" false "$PODS_JSON"
  exit 0
fi

for pod in "${PODS[@]}"; do
  if ! pod_ready "$pod"; then
    emit_result "BLOCKED" "POD_NOT_READY" \
      "MariaDB already has a not-Ready pod; refusing to trigger an operator restart" false "$PODS_JSON"
    exit 0
  fi
done

if bool_enabled "$DRY_RUN"; then
  emit_result "READY" "RESTART_DRY_RUN" \
    "Dry-run made no changes; mariadb-operator will decide restart order after the annotation patch" false \
    "$PODS_JSON"
  exit 0
fi

if ! bool_enabled "$CONFIRM"; then
  emit_result "BLOCKED" "RESTART_CONFIRM_REQUIRED" \
    "Set confirm=true with dry_run=false to patch the MariaDB restart annotation" false \
    "$PODS_JSON"
  exit 0
fi

if ! PATCH_OUT=$(patch_restart_annotation); then
  emit_result "ERROR" "RESTART_PATCH_FAILED" \
    "Failed to patch MariaDB restart annotation: ${PATCH_OUT:-kubectl patch failed}" false \
    "$PODS_JSON"
  exit 0
fi

if [[ "$UPDATE_STRATEGY" == "OnDelete" || "$UPDATE_STRATEGY" == "Never" ]]; then
  emit_result "PATCHED" "OPERATOR_UPDATE_PENDING" \
    "MariaDB CR was patched; updateStrategy=${UPDATE_STRATEGY} leaves pod restart control to the operator/manual update policy" true \
    "$PODS_JSON"
  exit 0
fi

if ! wait_for_operator_restart; then
  PRIMARY_AFTER=$(resolve_primary)
  PODS_JSON=$(build_pods_json)
  emit_result "ERROR" "OPERATOR_RESTART_TIMEOUT" \
    "MariaDB CR was patched, but not all pods restarted and became Ready within ${WAIT_TIMEOUT}s" true \
    "$PODS_JSON"
  exit 0
fi

PRIMARY_AFTER=$(resolve_primary)
PODS_JSON=$(build_pods_json)

if [[ -n "$PRIMARY_BEFORE" && -n "$PRIMARY_AFTER" && "$PRIMARY_BEFORE" != "$PRIMARY_AFTER" ]]; then
  if bool_enabled "$ALLOW_ROLE_CHANGE"; then
    emit_result "WARN" "ROLE_CHANGED" \
      "Operator restart completed but the primary role moved (${PRIMARY_BEFORE} -> ${PRIMARY_AFTER})" true \
      "$PODS_JSON"
  else
    emit_result "ERROR" "ROLE_CHANGED" \
      "Operator restart completed but the primary role moved unexpectedly (${PRIMARY_BEFORE} -> ${PRIMARY_AFTER})" true \
      "$PODS_JSON"
  fi
  exit 0
fi

emit_result "RESTARTED" "RESTART_COMPLETED" \
  "MariaDB restart annotation was patched and mariadb-operator restarted all pods; primary role unchanged" true \
  "$PODS_JSON"
