#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/pods/delete.sh
# aqsh task: delete a single Pod belonging to the StatefulSet backing this
# namespace's MongoDB deployment (see docs/mongodb/pods.md). Gated
# dry_run -> confirm. The StatefulSet controller recreates the Pod afterward
# — this task only removes the current one; it does not wait for the
# replacement. target_pod must be an exact member of the auto-detected
# StatefulSet (ownerReferences-verified) — this task can never be pointed at
# a pod outside that instance, even though the underlying RBAC grant is an
# unscoped `delete` on pods in the namespace.
#
# This is a distinct capability from ops/kill: ops/kill interrupts a running
# mongod OPERATION by opid; this task deletes the POD itself.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE — target namespace, e.g. "mongo-1"
#   TARGET_POD   — required; the pod to delete
#   DRY_RUN      — default "true": resolve and validate, change nothing
#   CONFIRM      — must be "true" when DRY_RUN is "false"
#   LOG_LEVEL    — optional per-call log verbosity
#
# sts_name is not a task input (see CLAUDE.md "Configuration Layers") — same
# auto-detect tier as pods/list. Whether the delete is graceful or forced
# (--grace-period=0 --force) is decided internally from the pod's own Ready
# condition, not a caller-facing field — a not-Ready pod is usually already
# stuck and the StatefulSet's OrderedReady controller will not otherwise
# progress (same rationale as recovery_wipe_pod).
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb-recovery.sh"
source "${LIB_DIR}/mongodb-account.sh"
source "${LIB_DIR}/pods.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
log_set_level "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT:-INFO}}"
_TARGET_POD="${TARGET_POD:?TARGET_POD is required}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"

# ── Gate (same triad as ops/kill) ────────────────────────────────────────────
if bool_enabled "$DRY_RUN" && bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true with dry_run=true is not supported"
fi
if ! bool_enabled "$DRY_RUN" && ! bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true is required when dry_run=false"
fi

# ── Resolve instance + exact membership ─────────────────────────────────────
_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "")
log_debug "pods-delete" "resolved StatefulSet=${_STS} namespace=${DB_NAMESPACE} target_pod=${_TARGET_POD} dry_run=${DRY_RUN}"

_MEMBER_NAMES=$(_k8s_sts_owned_pod_names "$_STS") \
  || fail_task "PODS_LIST_FAILED" "could not list pods for StatefulSet ${_STS} in ${DB_NAMESPACE}"

if ! grep -qxF "$_TARGET_POD" <<<"$_MEMBER_NAMES"; then
  log_debug "pods-delete" "target_pod ${_TARGET_POD} not in member list: $(printf '%s' "$_MEMBER_NAMES" | tr '\n' ',')"
  fail_task "POD_NOT_MEMBER" "'${_TARGET_POD}' is not a member pod of StatefulSet ${_STS} in ${DB_NAMESPACE}"
fi

# ── Already gone: idempotent success, skip the gate entirely ───────────────
if ! pods_exists "$_TARGET_POD"; then
  log_info "pods-delete" "${_TARGET_POD} already gone"
  write_task_result "$(jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg instance "$_STS" \
    --arg target_pod "$_TARGET_POD" \
    '{status:"ok", reason_code:"POD_ALREADY_DELETED",
      summary:("Pod " + $target_pod + " does not exist; nothing to delete."),
      namespace:$namespace, instance:$instance, target_pod:$target_pod, deleted:false}')"
  exit 0
fi

_FORCE="false"
if ! pods_is_ready "$_TARGET_POD"; then
  _FORCE="true"
fi
log_debug "pods-delete" "target_pod=${_TARGET_POD} ready=$([[ "$_FORCE" == "true" ]] && echo false || echo true) force=${_FORCE}"

if bool_enabled "$DRY_RUN"; then
  log_info "pods-delete" "dry-run: would delete ${_TARGET_POD} (force=${_FORCE}) in ${DB_NAMESPACE}"
  write_task_result "$(jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg instance "$_STS" \
    --arg target_pod "$_TARGET_POD" \
    --argjson force "$_FORCE" \
    '{status:"DRY_RUN_READY", reason_code:"DRY_RUN_READY",
      summary:("Dry-run only. Would delete " + $target_pod + " (force=" + ($force|tostring) + ")."),
      namespace:$namespace, instance:$instance, target_pod:$target_pod,
      deleted:false, would_delete:true, force:$force}')"
  exit 0
fi

# ── Execute ──────────────────────────────────────────────────────────────────
log_info "pods-delete" "deleting ${_TARGET_POD} in ${DB_NAMESPACE} (instance=${_STS}, force=${_FORCE})"
_DELETE_OUT=$(pods_delete "$_TARGET_POD" "$_FORCE") \
  || fail_task "DELETE_FAILED" \
    "kubectl delete pod ${_TARGET_POD} failed" \
    "$(jq -nc --arg detail "${_DELETE_OUT:-}" '{detail:$detail}')"

log_info "pods-delete" "${_TARGET_POD} delete issued (force=${_FORCE}); StatefulSet ${_STS} will recreate it"
write_task_result "$(jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg instance "$_STS" \
  --arg target_pod "$_TARGET_POD" \
  --argjson force "$_FORCE" \
  '{status:"ok", reason_code:"POD_DELETED",
    summary:("Pod " + $target_pod + " delete issued (force=" + ($force|tostring) + "); the StatefulSet will recreate it."),
    namespace:$namespace, instance:$instance, target_pod:$target_pod,
    deleted:true, force:$force}')"
