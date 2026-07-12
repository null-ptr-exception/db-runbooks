#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/pbm/delete.sh
# aqsh task: remove backup artifacts, gated dry_run -> confirm. Two modes,
# mutually exclusive: backup_name (single snapshot, pbm delete-backup) or
# older_than (retention sweep of snapshots + PITR chunks, pbm cleanup).
# dry-run lists exactly what would go. Two PBM semantics surface here:
# deleting an incremental BASE cascades to its whole chain (chains are
# only ever removed as a whole), and deletions PBM refuses (e.g. the
# snapshot anchoring live PITR coverage) are surfaced verbatim.
# See docs/mongodb/pbm.md.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE    — target namespace
#   PBM_BACKUP_NAME — snapshot to delete (XOR with PBM_OLDER_THAN)
#   PBM_OLDER_THAN  — "Nd" (days) or "YYYY-MM-DDTHH:MM:SS" cutoff
#   DRY_RUN         — default "true"
#   CONFIRM         — must be "true" when DRY_RUN is "false"
#   LOG_LEVEL       — optional per-call log verbosity
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

_BACKUP_NAME="${PBM_BACKUP_NAME:-}"
_OLDER_THAN="${PBM_OLDER_THAN:-}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"

# ── Gate ─────────────────────────────────────────────────────────────────────
if bool_enabled "$DRY_RUN" && bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true with dry_run=true is not supported"
fi
if ! bool_enabled "$DRY_RUN" && ! bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true is required when dry_run=false"
fi
if [[ -n "$_BACKUP_NAME" && -n "$_OLDER_THAN" ]]; then
  fail_task "INVALID_INPUT" "backup_name and older_than are mutually exclusive — pass exactly one"
fi
if [[ -z "$_BACKUP_NAME" && -z "$_OLDER_THAN" ]]; then
  fail_task "INVALID_INPUT" "one of backup_name (single delete) or older_than (retention sweep) is required"
fi

pbm_task_init "pbm-delete"

_LIST_JSON=$(pbm_list_json "$PBM_POD" "$PBM_AGENT_CONTAINER") \
  || fail_task "PBM_CLI_ERROR" "pbm list failed in ${PBM_POD}/${PBM_AGENT_CONTAINER}" \
    "$(jq -nc --arg raw "${_LIST_JSON:0:1000}" '{raw_output:$raw}')"

# ── Build the would-delete preview (both gate phases) ────────────────────────
if [[ -n "$_BACKUP_NAME" ]]; then
  _PREVIEW=$(jq -c --arg n "$_BACKUP_NAME" \
    '[.snapshots[]? | select(.name == $n) | {name, status, completeTS, type}]' <<< "$_LIST_JSON")
  if [[ "$(jq -r 'length' <<< "$_PREVIEW")" == "0" ]]; then
    fail_task "BACKUP_NOT_FOUND" "backup '${_BACKUP_NAME}' not found" \
      '{"hint":"pbm/list shows the inventory"}'
  fi
else
  _CUTOFF_EPOCH=$(_pbm_epoch "$_OLDER_THAN") \
    || fail_task "INVALID_INPUT" "older_than '${_OLDER_THAN}' is not 'Nd' or a parseable UTC timestamp"
  _PREVIEW=$(pbm_snapshots_older_than "$_LIST_JSON" "$_CUTOFF_EPOCH")
  log_debug "pbm-delete" "cutoff epoch ${_CUTOFF_EPOCH}: $(jq -r 'length' <<< "$_PREVIEW") snapshot(s) match"
fi

if bool_enabled "$DRY_RUN"; then
  log_info "pbm-delete" "dry-run: $(jq -r 'length' <<< "$_PREVIEW") artifact(s) would be removed — no changes made"
  jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg sts "$PBM_STS" \
    --arg backup_name "$_BACKUP_NAME" \
    --arg older_than "$_OLDER_THAN" \
    --argjson preview "$_PREVIEW" \
    '{dry_run: true, namespace: $namespace, sts: $sts,
      mode: (if $backup_name != "" then "single" else "retention" end),
      would_delete: $preview}
     + (if $older_than == "" then {} else {older_than: $older_than, note: "pbm cleanup also trims PITR oplog chunks before the cutoff"} end)
     + (if ($preview | any(.type == "incremental")) then {note: "deleting an incremental base cascades to every increment built on it — the chain is only ever removed as a whole"} else {} end)' \
    > "$AQSH_RESULT_FILE"
  exit 0
fi

# ── confirm: execute ─────────────────────────────────────────────────────────
if [[ -n "$_BACKUP_NAME" ]]; then
  _OUT=$(pbm_delete_backup "$PBM_POD" "$PBM_AGENT_CONTAINER" "$_BACKUP_NAME") \
    || fail_task "DELETE_FAILED" "pbm delete-backup '${_BACKUP_NAME}' failed" \
      "$(jq -nc --arg raw "${_OUT:0:1000}" \
        '{raw_output:$raw, hint:"PBM refuses to delete a snapshot that anchors the current PITR chain — disable PITR or take a fresh base backup first"}')"
else
  _OUT=$(pbm_cleanup "$PBM_POD" "$PBM_AGENT_CONTAINER" "$_OLDER_THAN") \
    || fail_task "CLEANUP_FAILED" "pbm cleanup --older-than '${_OLDER_THAN}' failed" \
      "$(jq -nc --arg raw "${_OUT:0:1000}" '{raw_output:$raw}')"
fi

_REMAINING=$(pbm_list_json "$PBM_POD" "$PBM_AGENT_CONTAINER" | jq -r '[.snapshots[]?] | length' 2>/dev/null) || _REMAINING="unknown"
log_info "pbm-delete" "delete confirmed (${_BACKUP_NAME:-older_than=${_OLDER_THAN}}); ${_REMAINING} snapshot(s) remain"

jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg sts "$PBM_STS" \
  --arg backup_name "$_BACKUP_NAME" \
  --arg older_than "$_OLDER_THAN" \
  --arg remaining "$_REMAINING" \
  --argjson deleted "$_PREVIEW" \
  '{namespace: $namespace, sts: $sts, status: "done",
    mode: (if $backup_name != "" then "single" else "retention" end),
    deleted: $deleted,
    snapshots_remaining: ($remaining | tonumber? // $remaining)}
   + (if $older_than == "" then {} else {older_than: $older_than} end)' \
  > "$AQSH_RESULT_FILE"
