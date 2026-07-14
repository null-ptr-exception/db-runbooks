#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/pbm/cancel-backup.sh
# aqsh task: abort the currently running backup, gated dry_run -> confirm
# (aborting in-flight work is state-changing: the partial artifact is marked
# cancelled). dry-run reports the op that would be aborted; confirm with
# nothing running fails NO_RUNNING_OP. Kept out of pbm/backup on purpose —
# an abort verb inside a start-task API would break the "dry_run previews
# exactly what confirm executes" contract. See docs/mongodb/pbm.md.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE — target namespace
#   DRY_RUN      — default "true"
#   CONFIRM      — must be "true" when DRY_RUN is "false"
#   LOG_LEVEL    — optional per-call log verbosity
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-recovery.sh"
source "${LIB_DIR}/mongodb-account.sh"
source "${LIB_DIR}/mongodb-pbm.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
log_set_level "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT:-INFO}}"

DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"

# ── Gate ─────────────────────────────────────────────────────────────────────
if bool_enabled "$DRY_RUN" && bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true with dry_run=true is not supported"
fi
if ! bool_enabled "$DRY_RUN" && ! bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true is required when dry_run=false"
fi

pbm_task_init "pbm-cancel-backup"

_STATUS_JSON=$(pbm_status_json "$PBM_POD" "$PBM_AGENT_CONTAINER") \
  || fail_task "PBM_CLI_ERROR" "pbm status failed in ${PBM_POD}/${PBM_AGENT_CONTAINER}" \
    "$(jq -nc --arg raw "${_STATUS_JSON:0:1000}" '{raw_output:$raw}')"
_RUNNING=$(pbm_current_op "$_STATUS_JSON")

if bool_enabled "$DRY_RUN"; then
  log_info "pbm-cancel-backup" "dry-run: running_op=$(jq -r 'if .==null then "none" else (.type // "unknown") end' <<< "$_RUNNING") — no changes made"
  jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg sts "$PBM_STS" \
    --argjson running "$_RUNNING" \
    '{dry_run: true, namespace: $namespace, sts: $sts,
      running: $running,
      would_cancel: ($running != null)}
     + (if $running == null then {note: "nothing is running — confirm would fail with NO_RUNNING_OP"} else {} end)' \
    > "$AQSH_RESULT_FILE"
  exit 0
fi

# ── confirm: execute ─────────────────────────────────────────────────────────
if [[ "$_RUNNING" == "null" ]]; then
  fail_task "NO_RUNNING_OP" "no backup is currently running" \
    '{"hint":"pbm/status shows the running op; a finished backup cannot be cancelled — use pbm/delete instead"}'
fi

_OUT=$(pbm_cancel_backup "$PBM_POD" "$PBM_AGENT_CONTAINER") \
  || fail_task "CANCEL_FAILED" "pbm cancel-backup failed" \
    "$(jq -nc --arg raw "${_OUT:0:1000}" '{raw_output:$raw}')"

log_info "pbm-cancel-backup" "cancel issued for $(jq -r '.type // "op"' <<< "$_RUNNING") $(jq -r '.name // ""' <<< "$_RUNNING")"

jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg sts "$PBM_STS" \
  --argjson cancelled "$_RUNNING" \
  '{namespace: $namespace, sts: $sts, status: "done", cancelled: $cancelled,
    note: "the aborted backup shows up as status=cancelled in pbm/list"}' \
  > "$AQSH_RESULT_FILE"
