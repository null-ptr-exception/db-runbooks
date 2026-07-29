#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/pods/delete.sh
# aqsh task: delete a single Pod belonging to this namespace's MariaDB
# instance (see docs/mariadb/pods.md). Gated dry_run -> confirm. The
# StatefulSet controller recreates the Pod afterward — this task only
# removes the current one; it does not wait for the replacement. target_pod
# must be an exact member pod of the auto-detected instance
# (mariadb_list_member_pods) — this task can never be pointed at a pod
# outside that instance, even though the underlying RBAC grant is an
# unscoped `delete` on pods in the namespace.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE — target namespace
#   TARGET_POD   — required; the pod to delete
#   DRY_RUN      — default "true": resolve and validate, change nothing
#   CONFIRM      — must be "true" when DRY_RUN is "false"
#   LOG_LEVEL    — optional per-call log verbosity, matching MongoDB's gateway
#
# The instance itself is not a task input (see CLAUDE.md "Configuration
# Layers") — same auto-detect as pods/list. Whether the delete is graceful
# or forced (--grace-period=0 --force) is decided internally from the pod's
# own Ready condition, not a caller-facing field — a not-Ready pod is
# usually already stuck and the StatefulSet's OrderedReady controller will
# not otherwise progress.
# =============================================================================

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi

MDB_INPUT="${MARIADB_NAME:-}"

# shellcheck source=../../lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"  # logging, response, k8s + generic helpers
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"
# shellcheck source=../../lib/pods.sh
source "${LIB_DIR}/pods.sh"

mdbt_load_config
log_set_level "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT:-INFO}}"

OP="pods-delete"

NAMESPACE="${DB_NAMESPACE:-}"
TARGET_POD="${TARGET_POD:-}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"

# Confirm is required to apply; a dry run renders the plan without it.
if [[ "$(mdbt_bool_json "$DRY_RUN")" != "true" ]]; then
  mdbt_require_confirm "$OP" "$CONFIRM"
fi

mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"
mdbt_required "target_pod" "$TARGET_POD" "$OP"

mariadb_set_target "${K8S_CONTEXT:-}" "$NAMESPACE" "$MARIADB_RESOURCE" "$MDB_INPUT"

_on_ambiguous() {
  log_debug "$OP" "ambiguous instance candidates: ${1:-}"
  mdbt_fail "$OP" "database configuration is ambiguous" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2 "DATABASE_CONFIGURATION_AMBIGUOUS"
}
_on_none() {
  mdbt_fail "$OP" "database not found" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2 "DATABASE_NOT_FOUND"
}
if [[ -z "$MDB_INPUT" ]]; then
  mariadb_autodetect_target true _on_ambiguous _on_none
fi
log_debug "$OP" "resolved instance=${MARIADB_NAME} namespace=${NAMESPACE} target_pod=${TARGET_POD} dry_run=${DRY_RUN}"

MEMBER_PODS=""
if ! MEMBER_PODS="$(mariadb_list_member_pods)"; then
  mdbt_fail "$OP" "cannot resolve exact member pods for this instance" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1 "POD_TARGETS_UNRESOLVED"
fi

if ! grep -qxF "$TARGET_POD" <<<"$MEMBER_PODS"; then
  log_debug "$OP" "target_pod ${TARGET_POD} not in member list: $(printf '%s' "$MEMBER_PODS" | tr '\n' ',')"
  mdbt_fail "$OP" "target pod is not a member of this instance" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2 "POD_NOT_MEMBER"
fi

# Success responses splice a top-level "reason" onto response_ok's envelope,
# the same way mdbt_error_response splices one onto response_err — so a
# caller can always branch on top-level "reason" regardless of status.

# Already gone: idempotent success, skip the gate entirely. pods_exists
# distinguishes a confirmed-gone Pod (rc 1) from a failed status check
# (rc 2, e.g. a transient API error) — only the former is safe to report as
# POD_ALREADY_DELETED; the latter must abort instead of silently masking an
# unreachable API server as "nothing to delete".
EXISTS_RC=0
pods_exists "$TARGET_POD" || EXISTS_RC=$?
if [[ "$EXISTS_RC" -eq 1 ]]; then
  log_info "$OP" "${TARGET_POD} already gone"
  mdbt_write_result "$(response_ok "$OP" "Pod ${TARGET_POD} does not exist; nothing to delete." "$(jq -n \
    --arg namespace "$NAMESPACE" --arg instance "$MARIADB_NAME" --arg target_pod "$TARGET_POD" \
    '{namespace:$namespace, instance:$instance, target_pod:$target_pod, deleted:false}')" | \
    jq -c '. + {reason: "POD_ALREADY_DELETED"}')"
  exit 0
elif [[ "$EXISTS_RC" -eq 2 ]]; then
  mdbt_fail "$OP" "could not determine whether ${TARGET_POD} exists" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1 "POD_STATUS_UNKNOWN"
fi

FORCE="false"
READY_RC=0
pods_is_ready "$TARGET_POD" || READY_RC=$?
if [[ "$READY_RC" -eq 1 ]]; then
  FORCE="true"
elif [[ "$READY_RC" -eq 2 ]]; then
  mdbt_fail "$OP" "could not determine readiness of ${TARGET_POD}" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1 "POD_STATUS_UNKNOWN"
fi
log_debug "$OP" "target_pod=${TARGET_POD} force=${FORCE}"

if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  log_info "$OP" "dry-run: would delete ${TARGET_POD} (force=${FORCE}) in ${NAMESPACE}"
  mdbt_write_result "$(response_ok "$OP" "Dry-run only. Would delete ${TARGET_POD} (force=${FORCE})." "$(jq -n \
    --arg namespace "$NAMESPACE" --arg instance "$MARIADB_NAME" --arg target_pod "$TARGET_POD" \
    --argjson force "$FORCE" \
    '{namespace:$namespace, instance:$instance, target_pod:$target_pod,
      deleted:false, would_delete:true, force:$force}')" | \
    jq -c '. + {reason: "DRY_RUN_READY"}')"
  exit 0
fi

# --- Execute ------------------------------------------------------------------
log_info "$OP" "deleting ${TARGET_POD} in ${NAMESPACE} (instance=${MARIADB_NAME}, force=${FORCE})"
DELETE_OUT=""
if ! DELETE_OUT="$(pods_delete "$TARGET_POD" "$FORCE")"; then
  mdbt_fail "$OP" "kubectl delete pod failed" \
    "$(jq -n --arg detail "${DELETE_OUT:-}" '{detail:$detail}')" 1 "DELETE_FAILED"
fi

log_info "$OP" "${TARGET_POD} delete issued (force=${FORCE}); instance ${MARIADB_NAME} will recreate it"
mdbt_write_result "$(response_ok "$OP" "Pod ${TARGET_POD} delete issued (force=${FORCE}); the StatefulSet will recreate it." "$(jq -n \
  --arg namespace "$NAMESPACE" --arg instance "$MARIADB_NAME" --arg target_pod "$TARGET_POD" \
  --argjson force "$FORCE" \
  '{namespace:$namespace, instance:$instance, target_pod:$target_pod, deleted:true, force:$force}')" | \
  jq -c '. + {reason: "POD_DELETED"}')"
