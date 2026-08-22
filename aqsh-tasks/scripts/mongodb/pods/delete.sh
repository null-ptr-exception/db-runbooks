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
#   POD_UID      — required when DRY_RUN is "false"; the target Pod's UID as
#                  returned by the preceding dry-run. Compared against the
#                  live Pod's UID before deleting so a confirm call can never
#                  delete a same-name replacement Pod the StatefulSet already
#                  recreated since the dry-run that inspected it.
#   LOG_LEVEL    — optional per-call log verbosity
#
# sts_name is not a task input (see AGENTS.md "Configuration Layers") — same
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
_POD_UID_INPUT="${POD_UID:-}"

# ── Gate (same triad as ops/kill, plus the pod_uid precondition) ───────────
# dry_run must be an explicit "true"/"false" (schema-enforced too) — this is
# a safety control, not a generic flag: bool_enabled treats any unrecognized
# string as false, so a typo like dry_run="flase" combined with confirm=true
# would otherwise skip the dry-run gate entirely and perform the delete.
if [[ "$DRY_RUN" != "true" && "$DRY_RUN" != "false" ]]; then
  fail_task "INVALID_INPUT" "dry_run must be a boolean (true/false); got '${DRY_RUN}'"
fi
if bool_enabled "$DRY_RUN" && bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true with dry_run=true is not supported"
fi
if ! bool_enabled "$DRY_RUN" && ! bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true is required when dry_run=false"
fi
if ! bool_enabled "$DRY_RUN" && [[ -z "$_POD_UID_INPUT" ]]; then
  fail_task "INVALID_INPUT" "pod_uid is required when dry_run=false — carry it from the preceding dry-run response"
fi

# ── Resolve instance ─────────────────────────────────────────────────────────
_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "")
log_debug "pods-delete" "resolved StatefulSet=${_STS} namespace=${DB_NAMESPACE} target_pod=${_TARGET_POD} dry_run=${DRY_RUN}"

# ── Fetch the target Pod directly, then gate on identity ───────────────────
# Fetching the specific target Pod (rather than deriving membership from a
# separately-listed live member set) is what makes POD_ALREADY_DELETED
# reachable: an already-deleted Pod simply drops out of a live member list,
# which previously made "already gone" indistinguishable from "never a
# member" and always failed POD_NOT_MEMBER first. pods_fetch_json
# distinguishes a confirmed-gone Pod (rc 1) from a failed status check (rc
# 2, e.g. a transient API error) — only the former is safe to report as
# POD_ALREADY_DELETED; the latter must abort instead of silently masking an
# unreachable API server as "nothing to delete".
_POD_JSON=""
_FETCH_RC=0
_POD_JSON="$(pods_fetch_json "$_TARGET_POD")" || _FETCH_RC=$?

if [[ "$_FETCH_RC" -eq 1 ]]; then
  log_info "pods-delete" "${_TARGET_POD} already gone"
  write_task_result "$(jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg instance "$_STS" \
    --arg target_pod "$_TARGET_POD" \
    '{status:"ok", reason_code:"POD_ALREADY_DELETED",
      summary:("Pod " + $target_pod + " does not exist; nothing to delete."),
      namespace:$namespace, instance:$instance, target_pod:$target_pod, deleted:false}')"
  exit 0
elif [[ "$_FETCH_RC" -eq 2 ]]; then
  fail_task "POD_STATUS_UNKNOWN" "could not determine whether ${_TARGET_POD} exists"
fi

if ! pods_owned_by_sts "$_POD_JSON" "$_STS"; then
  log_debug "pods-delete" "target_pod ${_TARGET_POD} is not owned by StatefulSet ${_STS}"
  fail_task "POD_NOT_MEMBER" "'${_TARGET_POD}' is not a member pod of StatefulSet ${_STS} in ${DB_NAMESPACE}"
fi

_LIVE_UID=$(pods_uid "$_POD_JSON")
_FORCE="false"
pods_ready "$_POD_JSON" || _FORCE="true"
log_debug "pods-delete" "target_pod=${_TARGET_POD} uid=${_LIVE_UID} force=${_FORCE}"

if bool_enabled "$DRY_RUN"; then
  log_info "pods-delete" "dry-run: would delete ${_TARGET_POD} (force=${_FORCE}) in ${DB_NAMESPACE}"
  write_task_result "$(jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg instance "$_STS" \
    --arg target_pod "$_TARGET_POD" \
    --arg pod_uid "$_LIVE_UID" \
    --argjson force "$_FORCE" \
    '{status:"DRY_RUN_READY", reason_code:"DRY_RUN_READY",
      summary:("Dry-run only. Would delete " + $target_pod + " (force=" + ($force|tostring) + ")."),
      namespace:$namespace, instance:$instance, target_pod:$target_pod,
      deleted:false, would_delete:true, force:$force, pod_uid:$pod_uid}')"
  exit 0
fi

# ── Confirmed delete: verify identity against the dry-run's UID ────────────
# Not a server-enforced precondition — the kubectl CLI has no flag for one
# (see pods_delete in lib/pods.sh) — but comparing the live UID against what
# the caller observed during dry-run, immediately before issuing the
# delete, closes the realistic window: the StatefulSet recreating a
# same-name replacement Pod during the (often human-paced) gap between a
# dry-run and its confirm call.
if [[ "$_POD_UID_INPUT" != "$_LIVE_UID" ]]; then
  log_info "pods-delete" "pod_uid mismatch for ${_TARGET_POD}: expected=${_POD_UID_INPUT} live=${_LIVE_UID}"
  fail_task "POD_REPLACED" \
    "'${_TARGET_POD}' is a different Pod object than the one inspected in the dry-run (uid mismatch) — it was likely already recreated; re-run pods/delete with dry_run=true to get the current pod_uid"
fi

# ── Execute ──────────────────────────────────────────────────────────────────
log_info "pods-delete" "deleting ${_TARGET_POD} (uid=${_LIVE_UID}) in ${DB_NAMESPACE} (instance=${_STS}, force=${_FORCE})"
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
