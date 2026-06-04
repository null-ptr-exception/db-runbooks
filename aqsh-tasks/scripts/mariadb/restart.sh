#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/restart.sh
# Operator-driven restart of a MariaDB cluster.
#
# AQSH does not delete MariaDB Pods or decide the rollout order. It patches a
# MariaDB CR Pod-template annotation and lets mariadb-operator reconcile the
# restart according to spec.updateStrategy (for example ReplicasFirstPrimaryLast).
#
# The task's contract is deliberately narrow: patch the restart annotation, then
# verify that the operator recreated every pod and brought it back Ready. It does
# not track primary/replica roles or impose a restart order — those belong to the
# operator.
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
# shellcheck source=../../lib/mariadb-restart-input.sh
source "${LIB_DIR}/mariadb-restart-input.sh"
# shellcheck source=../../lib/mariadb-restart-result.sh
source "${LIB_DIR}/mariadb-restart-result.sh"

mariadb_restart_set_defaults
mariadb_restart_parse_args "$@"
mariadb_restart_validate_inputs

mariadb_set_target "$CONTEXT" "$NAMESPACE" "$RESOURCE" "$MDB" "$CONTAINER"

if [[ "$JSON_ONLY" -ne 1 ]]; then
  log_info "mariadb-restart" "Planning operator-driven restart for namespace=${NAMESPACE} mdb=${MDB} (dry_run=${DRY_RUN})"
fi

if ! k8s_check >/dev/null; then
  mariadb_restart_emit_result "ERROR" "KUBECTL_UNAVAILABLE" "Kubernetes API is not reachable" false
  exit 0
fi

if [[ -n "$TARGET_POD" ]]; then
  mariadb_restart_emit_result "BLOCKED" "TARGET_POD_UNSUPPORTED" \
    "Operator-driven restart is scoped to the MariaDB resource; target_pod is not supported" false
  exit 0
fi

if ! mariadb_jsonpath "$RESOURCE" "$MDB" '{.metadata.name}' >/dev/null 2>&1; then
  mariadb_restart_emit_result "BLOCKED" "MARIADB_OPERATOR_REQUIRED" \
    "MariaDB CR was not found; operator-driven restart requires a mariadb-operator resource" false
  exit 0
fi

select_status=0
METADATA_FIELD=$(mariadb_operator_select_restart_metadata_field "$RESOURCE" "$RESTART_METADATA_FIELD") || select_status=$?
if [[ "$select_status" -ne 0 ]]; then
  case "$select_status" in
    2)
      mariadb_restart_emit_result "BLOCKED" "RESTART_METADATA_FIELD_INVALID" \
        "restart metadata field must be podMetadata, inheritMetadata, or auto" false
      ;;
    *)
      mariadb_restart_emit_result "BLOCKED" "RESTART_METADATA_FIELD_UNSUPPORTED" \
        "MariaDB CRD does not expose spec.podMetadata or spec.inheritMetadata for operator-driven restart annotation" false
      ;;
  esac
  exit 0
fi

# shellcheck disable=SC2034  # Populated and consumed by mariadb-operator.sh helpers.
declare -A POD_UID_BEFORE
# shellcheck disable=SC2034  # Populated and consumed by mariadb-operator.sh helpers.
declare -A POD_RESTARTED
# shellcheck disable=SC2034  # Populated and consumed by mariadb-operator.sh helpers.
declare -A POD_READY_AFTER

mariadb_operator_load_restart_state "$RESOURCE" "$MDB"

if [[ "${#PODS[@]}" -eq 0 ]]; then
  mariadb_restart_emit_result "BLOCKED" "MARIADB_PODS_NOT_FOUND" "MariaDB CR exists, but no MariaDB pods were found" false "$PODS_JSON"
  exit 0
fi

for pod in "${PODS[@]}"; do
  if ! mariadb_operator_pod_ready "$pod" "$CONTAINER"; then
    mariadb_restart_emit_result "BLOCKED" "POD_NOT_READY" \
      "MariaDB already has a not-Ready pod; refusing to trigger an operator restart" false "$PODS_JSON"
    exit 0
  fi
done

if task_bool_enabled "$DRY_RUN"; then
  mariadb_restart_emit_result "READY" "RESTART_DRY_RUN" \
    "Dry-run made no changes; mariadb-operator will decide restart order after the annotation patch" false \
    "$PODS_JSON"
  exit 0
fi

if ! task_bool_enabled "$CONFIRM"; then
  mariadb_restart_emit_result "BLOCKED" "RESTART_CONFIRM_REQUIRED" \
    "Set confirm=true with dry_run=false to patch the MariaDB restart annotation" false \
    "$PODS_JSON"
  exit 0
fi

PATCH_VALUE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if ! PATCH_OUT=$(mariadb_operator_patch_restart_annotation "$RESOURCE" "$MDB" "$METADATA_FIELD" "$ANNOTATION_KEY" "$PATCH_VALUE"); then
  mariadb_restart_emit_result "ERROR" "RESTART_PATCH_FAILED" \
    "Failed to patch MariaDB restart annotation: ${PATCH_OUT:-kubectl patch failed}" false \
    "$PODS_JSON"
  exit 0
fi

if [[ "$UPDATE_STRATEGY" == "OnDelete" || "$UPDATE_STRATEGY" == "Never" ]]; then
  mariadb_restart_emit_result "PATCHED" "OPERATOR_UPDATE_PENDING" \
    "MariaDB CR was patched; updateStrategy=${UPDATE_STRATEGY} leaves pod restart control to the operator/manual update policy" true \
    "$PODS_JSON"
  exit 0
fi

if ! mariadb_operator_wait_for_restart "$CONTAINER" "$WAIT_TIMEOUT" "${PODS[@]}"; then
  PODS_JSON=$(mariadb_operator_build_pods_json "${PODS[@]}")
  mariadb_restart_emit_result "ERROR" "OPERATOR_RESTART_TIMEOUT" \
    "MariaDB CR was patched, but not all pods restarted and became Ready within ${WAIT_TIMEOUT}s" true \
    "$PODS_JSON"
  exit 0
fi

PODS_JSON=$(mariadb_operator_build_pods_json "${PODS[@]}")
mariadb_restart_emit_result "RESTARTED" "RESTART_COMPLETED" \
  "MariaDB restart annotation was patched and mariadb-operator restarted all pods" true \
  "$PODS_JSON"
