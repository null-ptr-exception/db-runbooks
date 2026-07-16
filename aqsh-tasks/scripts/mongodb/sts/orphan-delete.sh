#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/sts/orphan-delete.sh
# aqsh task: delete the target StatefulSet with `--cascade=orphan` — removes
# the controller object only, leaving its Pods and PVCs running untouched.
#
# This is step one of the standard workaround for enlarging a PVC bound by
# an immutable volumeClaimTemplate (resize the now-orphaned PVCs directly,
# then recreate the StatefulSet with the new size so it adopts the existing
# PVCs by naming convention instead of provisioning new ones). This task
# does NOT resize PVCs or recreate the StatefulSet — those remain separate,
# manual steps for now. See docs/mongodb/sts-orphan-delete.md.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE — target namespace
#   DRY_RUN      — default "true"
#   CONFIRM      — must be "true" when DRY_RUN is "false"
#   LOG_LEVEL    — optional per-call log verbosity
#
# sts_name is deliberately NOT a task input (see CLAUDE.md "Configuration
# Layers" / "Auto-detect tier") — resolved via recovery_resolve_sts_name:
# internal config -> single-StatefulSet-in-namespace auto-detect ->
# hardcoded "mongodb" fallback. This task detaches a StatefulSet from
# control of its own Pods, so the API surface is deliberately kept to just
# `namespace` + the dry_run/confirm gate.
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb-recovery.sh"
source "${LIB_DIR}/mongodb-account.sh" # bool_enabled, fail_task, write_task_result

export K8S_NAMESPACE="${DB_NAMESPACE}"
log_set_level "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT:-INFO}}"

DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"

if bool_enabled "$DRY_RUN" && bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true with dry_run=true is not supported"
fi
if ! bool_enabled "$DRY_RUN" && ! bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true is required when dry_run=false"
fi

# mongodb-recovery.sh (sourced above) already loads /etc/aqsh/config/mongodb.env
# before this point — see its header comment for why it must run there.
_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}")
log_debug "sts-orphan-delete" "resolved STS name: ${_STS}"

if bool_enabled "$DRY_RUN"; then
  # Preview here only; the confirm path relies on the identical snapshot
  # k8s_delete_sts_cascade_orphan takes itself, so one execution never holds
  # two divergent views of the same StatefulSet.
  if ! _PREVIEW=$(k8s_get_sts_pods "$_STS"); then
    # Pass the real failure through — "not found" is only one of the ways a
    # lookup can fail (RBAC forbidden, API timeout, ...), and reporting the
    # wrong one sends the operator chasing a nonexistent naming problem.
    fail_task "STS_LOOKUP_FAILED" \
      "$(jq -r '.message // "StatefulSet lookup failed"' <<< "$_PREVIEW"): '${_STS}' in namespace '${DB_NAMESPACE}'" \
      "$(jq -c '.data // {}' <<< "$_PREVIEW")"
  fi
  log_info "sts-orphan-delete" "dry-run: $(jq -r \
    '.data | "would delete StatefulSet \(.sts) (replicas=\(.replicas)) with --cascade=orphan; \(.pods | length) pod(s) would keep running: \(.pods | join(", "))"' \
    <<< "$_PREVIEW") — no changes made"
  jq -c --arg namespace "$DB_NAMESPACE" \
    '.data | {dry_run: true, namespace: $namespace, sts, replicas, would_orphan_pods: .pods,
      note: "pods and PVCs stay running and untouched; only the StatefulSet controller object is removed. Resizing PVCs and recreating the StatefulSet are separate, manual steps not performed by this task."}' \
    <<< "$_PREVIEW" > "$AQSH_RESULT_FILE"
  exit 0
fi

log_info "sts-orphan-delete" "confirm=true: deleting StatefulSet '${_STS}' with --cascade=orphan"
result=$(k8s_delete_sts_cascade_orphan "$_STS") || {
  printf '%s\n' "$result" | jq -c '{error: .message} + (.data // {})' > "$AQSH_RESULT_FILE"
  exit 1
}
printf '%s\n' "$result" | jq -c '.data' > "$AQSH_RESULT_FILE"
