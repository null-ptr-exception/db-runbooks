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
# shellcheck source=../../lib/task-input.sh
source "${LIB_DIR}/task-input.sh"
# shellcheck source=../../lib/k8s.sh
source "${LIB_DIR}/k8s.sh"
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"
# shellcheck source=../../lib/mariadb-operator.sh
source "${LIB_DIR}/mariadb-operator.sh"

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
    --context) task_require_value "$1" "${2:-}"; CONTEXT="$2"; shift 2 ;;
    --namespace) task_require_value "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
    --resource) task_require_value "$1" "${2:-}"; RESOURCE="$2"; shift 2 ;;
    --mdb | --name) task_require_value "$1" "${2:-}"; MDB="$2"; shift 2 ;;
    --container) task_require_value "$1" "${2:-}"; CONTAINER="$2"; shift 2 ;;
    --target-pod) task_require_value "$1" "${2:-}"; TARGET_POD="$2"; shift 2 ;;
    --include-primary) task_require_value "$1" "${2:-}"; INCLUDE_PRIMARY="$2"; shift 2 ;;
    --allow-role-change) task_require_value "$1" "${2:-}"; ALLOW_ROLE_CHANGE="$2"; shift 2 ;;
    --wait-timeout) task_require_value "$1" "${2:-}"; WAIT_TIMEOUT="$2"; shift 2 ;;
    --dry-run) task_require_value "$1" "${2:-}"; DRY_RUN="$2"; shift 2 ;;
    --confirm) task_require_value "$1" "${2:-}"; CONFIRM="$2"; shift 2 ;;
    --annotation-key) task_require_value "$1" "${2:-}"; ANNOTATION_KEY="$2"; shift 2 ;;
    --metadata-field) task_require_value "$1" "${2:-}"; RESTART_METADATA_FIELD="$2"; shift 2 ;;
    --json) JSON_ONLY=1; shift ;;
    --result-file) task_require_value "$1" "${2:-}"; RESULT_FILE="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$NAMESPACE" ]]; then
  usage
  exit 2
fi

if ! task_is_uint "$WAIT_TIMEOUT"; then
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
    --argjson replicas "$(task_json_num_or_null "$REPLICAS")" \
    --argjson dry_run "$(task_json_bool "$DRY_RUN")" \
    --argjson confirm "$(task_json_bool "$CONFIRM")" \
    --argjson allow_role_change "$(task_json_bool "$ALLOW_ROLE_CHANGE")" \
    --argjson changed "$(task_json_bool "$changed")" \
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
METADATA_FIELD=$(mariadb_operator_select_restart_metadata_field "$RESOURCE" "$RESTART_METADATA_FIELD") || select_status=$?
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

PRIMARY_BEFORE=$(mariadb_operator_resolve_primary "$RESOURCE" "$MDB" "$ROOT_PASSWORD" "${PODS[@]}")

declare -A POD_UID_BEFORE
declare -A POD_RESTARTED
declare -A POD_READY_AFTER

for pod in "${PODS[@]}"; do
  POD_UID_BEFORE["$pod"]=$(mariadb_pod_jsonpath "$pod" '{.metadata.uid}' 2>/dev/null || true)
  POD_RESTARTED["$pod"]=false
  POD_READY_AFTER["$pod"]=null
done

PODS_JSON=$(mariadb_operator_build_pods_json "$CONTAINER" "$PRIMARY_BEFORE" "$ROOT_PASSWORD" "${PODS[@]}")

if [[ "${#PODS[@]}" -eq 0 ]]; then
  emit_result "BLOCKED" "MARIADB_PODS_NOT_FOUND" "MariaDB CR exists, but no MariaDB pods were found" false "$PODS_JSON"
  exit 0
fi

for pod in "${PODS[@]}"; do
  if ! mariadb_operator_pod_ready "$pod" "$CONTAINER"; then
    emit_result "BLOCKED" "POD_NOT_READY" \
      "MariaDB already has a not-Ready pod; refusing to trigger an operator restart" false "$PODS_JSON"
    exit 0
  fi
done

if task_bool_enabled "$DRY_RUN"; then
  emit_result "READY" "RESTART_DRY_RUN" \
    "Dry-run made no changes; mariadb-operator will decide restart order after the annotation patch" false \
    "$PODS_JSON"
  exit 0
fi

if ! task_bool_enabled "$CONFIRM"; then
  emit_result "BLOCKED" "RESTART_CONFIRM_REQUIRED" \
    "Set confirm=true with dry_run=false to patch the MariaDB restart annotation" false \
    "$PODS_JSON"
  exit 0
fi

PATCH_VALUE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if ! PATCH_OUT=$(mariadb_operator_patch_restart_annotation "$RESOURCE" "$MDB" "$METADATA_FIELD" "$ANNOTATION_KEY" "$PATCH_VALUE"); then
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

if ! mariadb_operator_wait_for_restart "$CONTAINER" "$WAIT_TIMEOUT" "${PODS[@]}"; then
  PRIMARY_AFTER=$(mariadb_operator_resolve_primary "$RESOURCE" "$MDB" "$ROOT_PASSWORD" "${PODS[@]}")
  PODS_JSON=$(mariadb_operator_build_pods_json "$CONTAINER" "$PRIMARY_BEFORE" "$ROOT_PASSWORD" "${PODS[@]}")
  emit_result "ERROR" "OPERATOR_RESTART_TIMEOUT" \
    "MariaDB CR was patched, but not all pods restarted and became Ready within ${WAIT_TIMEOUT}s" true \
    "$PODS_JSON"
  exit 0
fi

PRIMARY_AFTER=$(mariadb_operator_resolve_primary "$RESOURCE" "$MDB" "$ROOT_PASSWORD" "${PODS[@]}")
PODS_JSON=$(mariadb_operator_build_pods_json "$CONTAINER" "$PRIMARY_BEFORE" "$ROOT_PASSWORD" "${PODS[@]}")

if [[ -n "$PRIMARY_BEFORE" && -n "$PRIMARY_AFTER" && "$PRIMARY_BEFORE" != "$PRIMARY_AFTER" ]]; then
  if task_bool_enabled "$ALLOW_ROLE_CHANGE"; then
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
