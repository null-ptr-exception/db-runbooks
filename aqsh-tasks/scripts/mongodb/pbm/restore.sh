#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/pbm/restore.sh
# aqsh task: LOGICAL restore from a snapshot (backup_name) or to a point in
# time (time, PITR), gated dry_run -> confirm. dry-run validates the target
# (backup exists and is done / the time falls inside a covered PITR chunk)
# and previews side effects; confirm disables PITR first when it is on
# (PBM requires it), runs the restore, and reports that PITR stays DISABLED
# until a fresh base backup exists — deliberately never re-enabled here.
# See docs/mongodb/pbm.md.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE     — target namespace
#   PBM_BACKUP_NAME  — snapshot to restore (XOR with PBM_RESTORE_TIME)
#   PBM_RESTORE_TIME — point in time "YYYY-MM-DDTHH:MM:SS" (UTC)
#   PBM_NS_FILTER    — optional selective restore, e.g. "app.orders"
#   PBM_WAIT_TIMEOUT — poll budget in seconds (default 1500)
#   DRY_RUN          — default "true": validate + preview, change nothing
#   CONFIRM          — must be "true" when DRY_RUN is "false"
#   LOG_LEVEL        — optional per-call log verbosity
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-recovery.sh"
source "${LIB_DIR}/mongodb-account.sh"
source "${LIB_DIR}/minio-client.sh"
source "${LIB_DIR}/mongodb-pbm.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
log_set_level "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT:-INFO}}"

_BACKUP_NAME="${PBM_BACKUP_NAME:-}"
_TIME="${PBM_RESTORE_TIME:-}"
_NS_FILTER="${PBM_NS_FILTER:-}"
_WAIT_TIMEOUT="${PBM_WAIT_TIMEOUT:-1500}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"

# ── Gate (same triad as fcv/account tasks) ───────────────────────────────────
if bool_enabled "$DRY_RUN" && bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true with dry_run=true is not supported"
fi
if ! bool_enabled "$DRY_RUN" && ! bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true is required when dry_run=false"
fi
if [[ -n "$_BACKUP_NAME" && -n "$_TIME" ]]; then
  fail_task "INVALID_INPUT" "backup_name and time are mutually exclusive — pass exactly one"
fi
if [[ -z "$_BACKUP_NAME" && -z "$_TIME" ]]; then
  fail_task "INVALID_INPUT" "one of backup_name (snapshot restore) or time (PITR restore) is required"
fi
if [[ ! "$_WAIT_TIMEOUT" =~ ^[0-9]+$ ]]; then
  fail_task "INVALID_INPUT" "wait_timeout must be an integer number of seconds (got '${_WAIT_TIMEOUT}')"
fi

pbm_task_init "pbm-restore"
pbm_require_storage "pbm-restore"

_STATUS_JSON=$(pbm_status_json "$PBM_POD" "$PBM_AGENT_CONTAINER") \
  || fail_task "PBM_CLI_ERROR" "pbm status failed in ${PBM_POD}/${PBM_AGENT_CONTAINER}" \
    "$(jq -nc --arg raw "${_STATUS_JSON:0:1000}" '{raw_output:$raw}')"
_PITR_ENABLED=false
pbm_pitr_enabled "$_STATUS_JSON" && _PITR_ENABLED=true

# ── Validate the restore target (both modes, both gate phases) ──────────────
_TARGET_DESC='null'
if [[ -n "$_BACKUP_NAME" ]]; then
  _TARGET_DESC=$(pbm_describe_backup_json "$PBM_POD" "$PBM_AGENT_CONTAINER" "$_BACKUP_NAME") \
    || fail_task "BACKUP_NOT_FOUND" "backup '${_BACKUP_NAME}' not found" \
      "$(jq -nc --arg raw "${_TARGET_DESC:0:1000}" '{raw_output:$raw, hint:"pbm/list shows the inventory"}')"
  _B_STATUS=$(jq -r '.status // "unknown"' <<< "$_TARGET_DESC")
  _B_TYPE=$(jq -r '.type // "unknown"' <<< "$_TARGET_DESC")
  if [[ "$_B_STATUS" != "done" ]]; then
    fail_task "BACKUP_NOT_RESTORABLE" "backup '${_BACKUP_NAME}' has status '${_B_STATUS}', need 'done'"
  fi
  if [[ "$_B_TYPE" != "logical" ]]; then
    fail_task "UNSUPPORTED_BACKUP_TYPE" \
      "backup '${_BACKUP_NAME}' is type '${_B_TYPE}' — this deployment can only restore logical backups" \
      '{"reason":"physical/incremental restores need mongod lifecycle control (Percona Operator territory)","see":"docs/mongodb/pbm.md#future-work"}'
  fi
  log_debug "pbm-restore" "target snapshot ${_BACKUP_NAME}: status=done type=logical"
else
  _EPOCH=$(_pbm_epoch "$_TIME") \
    || fail_task "INVALID_INPUT" "time '${_TIME}' is not a parseable UTC timestamp (YYYY-MM-DDTHH:MM:SS)"
  if ! pbm_pitr_covers "$_STATUS_JSON" "$_EPOCH"; then
    fail_task "TIME_NOT_COVERED" \
      "time '${_TIME}' is outside the PITR-covered window" \
      "$(jq -c --argjson t "$_EPOCH" \
        '{requested_epoch: $t,
          covered_ranges: [.backups.pitrChunks.pitrChunks[]?.range],
          hint: "the window runs from a done base backup to the newest flushed oplog chunk; pbm/status shows it live"}' \
        <<< "$_STATUS_JSON")"
  fi
  log_debug "pbm-restore" "time ${_TIME} (epoch ${_EPOCH}) is inside a covered PITR chunk"
fi

# ── dry-run: preview only ────────────────────────────────────────────────────
if bool_enabled "$DRY_RUN"; then
  log_info "pbm-restore" "dry-run: target valid (${_BACKUP_NAME:-time=${_TIME}}), pitr_enabled=${_PITR_ENABLED} — no changes made"
  jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg sts "$PBM_STS" \
    --arg backup_name "$_BACKUP_NAME" \
    --arg time "$_TIME" \
    --arg ns_filter "$_NS_FILTER" \
    --argjson pitr_enabled "$_PITR_ENABLED" \
    --argjson target "$_TARGET_DESC" \
    '{dry_run: true, namespace: $namespace, sts: $sts,
      would_restore: (if $backup_name != "" then {mode: "snapshot", backup_name: $backup_name} else {mode: "pitr", time: $time} end)
        + (if $ns_filter == "" then {} else {ns_filter: $ns_filter} end),
      target_backup: $target,
      pitr_enabled: $pitr_enabled,
      pitr_will_be_disabled: $pitr_enabled,
      post_restore_required: (if $pitr_enabled then "after the restore: run pbm/backup (fresh base), then pbm/pitr enabled=true" else null end),
      note: "restore replaces live data in the replica set — every write after the restore point is lost (selective ns_filter limits the blast radius to the listed collections)"}' \
    > "$AQSH_RESULT_FILE"
  exit 0
fi

# ── confirm: execute ─────────────────────────────────────────────────────────
_PITR_WAS_ENABLED="$_PITR_ENABLED"
if [[ "$_PITR_ENABLED" == "true" ]]; then
  log_warn "pbm-restore" "PITR slicing is enabled — disabling it for the restore (PBM requirement); it stays off until a fresh base backup + explicit pbm/pitr enabled=true"
  _PITR_OUT=$(pbm_pitr_set "$PBM_POD" "$PBM_AGENT_CONTAINER" "false") \
    || fail_task "PITR_DISABLE_FAILED" "could not disable PITR before the restore" \
      "$(jq -nc --arg raw "${_PITR_OUT:0:1000}" '{raw_output:$raw}')"
fi

_RESTORE_NAME=$(pbm_start_restore "$PBM_POD" "$PBM_AGENT_CONTAINER" "$_BACKUP_NAME" "$_TIME" "$_NS_FILTER") \
  || fail_task "RESTORE_START_FAILED" "pbm restore did not start" \
    "$(jq -nc --arg raw "${_RESTORE_NAME:0:1000}" --argjson pitr_was_enabled "$_PITR_WAS_ENABLED" \
      '{raw_output: $raw, pitr_was_enabled: $pitr_was_enabled,
        note: (if $pitr_was_enabled then "PITR was disabled for this attempt and is still off" else null end)}')"

_WAIT_RC=0
_FINAL=$(pbm_wait_restore "$PBM_POD" "$PBM_AGENT_CONTAINER" "$_RESTORE_NAME" "$_WAIT_TIMEOUT") || _WAIT_RC=$?
if (( _WAIT_RC == 124 )); then
  fail_task "WAIT_TIMEOUT" "restore ${_RESTORE_NAME} did not finish within ${_WAIT_TIMEOUT}s" \
    "$(jq -nc --arg name "$_RESTORE_NAME" --argjson pitr_was_enabled "$_PITR_WAS_ENABLED" \
      '{restore_name: $name, note: ("the restore keeps running server-side — follow it with pbm/logs event=restore/" + $name), pitr_was_enabled: $pitr_was_enabled}')"
elif (( _WAIT_RC != 0 )); then
  fail_task "RESTORE_FAILED" "restore ${_RESTORE_NAME} failed" \
    "$(jq -nc --arg name "$_RESTORE_NAME" \
      --arg error "$(jq -r '.error // "unknown error"' <<< "${_FINAL:-null}" 2>/dev/null)" \
      --argjson pitr_was_enabled "$_PITR_WAS_ENABLED" \
      '{restore_name: $name, error: $error, pitr_was_enabled: $pitr_was_enabled,
        hint: ("diagnose with pbm/logs event=restore/" + $name),
        note: (if $pitr_was_enabled then "PITR was disabled for this attempt and is still off" else null end)}')"
fi

log_info "pbm-restore" "restore ${_RESTORE_NAME} done (${_BACKUP_NAME:-time=${_TIME}})"

jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg sts "$PBM_STS" \
  --arg restore_name "$_RESTORE_NAME" \
  --arg backup_name "$_BACKUP_NAME" \
  --arg time "$_TIME" \
  --arg ns_filter "$_NS_FILTER" \
  --argjson pitr_was_enabled "$_PITR_WAS_ENABLED" \
  --argjson final "$_FINAL" \
  '{namespace: $namespace, sts: $sts, status: "done",
    restore_name: $restore_name,
    restored: (if $backup_name != "" then {mode: "snapshot", backup_name: $backup_name} else {mode: "pitr", time: $time} end)
      + (if $ns_filter == "" then {} else {ns_filter: $ns_filter} end),
    detail: $final,
    pitr_was_enabled: $pitr_was_enabled,
    pitr_enabled_now: false,
    post_restore_required: "run pbm/backup (fresh base backup), then pbm/pitr enabled=true to resume point-in-time coverage"}' \
  > "$AQSH_RESULT_FILE"
