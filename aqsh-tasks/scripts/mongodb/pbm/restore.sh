#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/pbm/restore.sh
# aqsh task: restore from a snapshot (backup_name) or to a point in time
# (time, PITR), gated dry_run -> confirm. The flow is dispatched on the
# backup's own type:
#
#   logical              — online restore over MongoDB connections; mongod
#                          keeps running.
#   physical/incremental — FULL-CLUSTER-DOWNTIME takeover: the StatefulSet
#                          is patched so pbm-agent runs inside the mongod
#                          container (supervisor command, pbm binaries via
#                          initContainer, probes off, sidecar parked), all
#                          pods are recreated, the restore runs with
#                          progress tracked on the S3 storage (the database
#                          is down), then the StatefulSet is surgically
#                          reverted and pods recreated again on the restored
#                          data. See docs/mongodb/pbm.md#physical-restore.
#
# time= restores pick their own base snapshot (newest done snapshot at or
# before T) and pin it with --base-snapshot when it is physical/incremental.
# dry-run validates everything and previews side effects — for physical
# that includes the downtime warning and the step plan. PITR slicing is
# disabled before any restore (PBM requirement) and stays OFF until a fresh
# base backup + explicit pbm/pitr enabled=true.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE     — target namespace
#   PBM_BACKUP_NAME  — snapshot to restore (XOR with PBM_RESTORE_TIME)
#   PBM_RESTORE_TIME — point in time "YYYY-MM-DDTHH:MM:SS" (UTC)
#   PBM_NS_FILTER    — optional selective restore (logical only)
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
source "${LIB_DIR}/mongodb-pbm-physical.sh"

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

# ── Validate the restore target and settle the flavor ────────────────────────
_TARGET_DESC='null'
_FLAVOR="logical"       # logical | physical (incremental restores are physical-flavored)
_BASE_NAME=""           # time mode: the pinned base snapshot
_BASE_TYPE=""
if [[ -n "$_BACKUP_NAME" ]]; then
  _TARGET_DESC=$(pbm_describe_backup_json "$PBM_POD" "$PBM_AGENT_CONTAINER" "$_BACKUP_NAME") \
    || fail_task "BACKUP_NOT_FOUND" "backup '${_BACKUP_NAME}' not found" \
      "$(jq -nc --arg raw "${_TARGET_DESC:0:1000}" '{raw_output:$raw, hint:"pbm/list shows the inventory"}')"
  _B_STATUS=$(jq -r '.status // "unknown"' <<< "$_TARGET_DESC")
  _B_TYPE=$(jq -r '.type // "unknown"' <<< "$_TARGET_DESC")
  if [[ "$_B_STATUS" != "done" ]]; then
    fail_task "BACKUP_NOT_RESTORABLE" "backup '${_BACKUP_NAME}' has status '${_B_STATUS}', need 'done'"
  fi
  case "$_B_TYPE" in
    logical) _FLAVOR="logical" ;;
    physical | incremental) _FLAVOR="physical" ;;
    *) fail_task "UNSUPPORTED_BACKUP_TYPE" \
         "backup '${_BACKUP_NAME}' has type '${_B_TYPE}' — this gateway restores logical, physical and incremental backups" ;;
  esac
  log_debug "pbm-restore" "target snapshot ${_BACKUP_NAME}: status=done type=${_B_TYPE} flavor=${_FLAVOR}"
else
  _EPOCH=$(_pbm_epoch "$_TIME") \
    || fail_task "INVALID_INPUT" "time '${_TIME}' is not a parseable UTC timestamp (YYYY-MM-DDTHH:MM:SS)"
  if ! pbm_pitr_covers "$_STATUS_JSON" "$_EPOCH"; then
    fail_task "TIME_NOT_COVERED" \
      "time '${_TIME}' is outside the PITR-covered window" \
      "$(jq -c --argjson t "$_EPOCH" \
        '{requested_epoch: $t,
          covered_ranges: [.backups.pitrChunks.pitrChunks[]?.range],
          hint: "the window runs from a done base backup to the newest flushed oplog chunk (the first chunk can take ~2 minutes to flush); pbm/status shows it live"}' \
        <<< "$_STATUS_JSON")"
  fi
  _BASE_ROW=$(jq -c --argjson t "$_EPOCH" '
    [.backups.snapshot[]? | select(.status == "done" and (.restoreTo // 0) <= $t)]
    | sort_by(.restoreTo) | last // empty' <<< "$_STATUS_JSON")
  if [[ -z "$_BASE_ROW" || "$_BASE_ROW" == "null" ]]; then
    fail_task "TIME_NOT_COVERED" "no completed base snapshot exists at or before '${_TIME}'" \
      '{"hint":"a point-in-time restore replays oplog on top of a base backup — run pbm/backup first"}'
  fi
  _BASE_NAME=$(jq -r '.name' <<< "$_BASE_ROW")
  _BASE_TYPE=$(jq -r '.type // "logical"' <<< "$_BASE_ROW")
  [[ "$_BASE_TYPE" == "logical" ]] || _FLAVOR="physical"
  log_debug "pbm-restore" "time ${_TIME} (epoch ${_EPOCH}) covered; base snapshot ${_BASE_NAME} (type=${_BASE_TYPE}) flavor=${_FLAVOR}"
fi

if [[ "$_FLAVOR" == "physical" && -n "$_NS_FILTER" ]]; then
  fail_task "INVALID_INPUT" \
    "selective restore (ns) is a logical-only PBM feature — a physical restore always replaces the whole data set"
fi

# ── Physical preconditions (checked in BOTH gate phases) ─────────────────────
_MONGOD_C=""
_TAKEOVER_LEFTOVER=false
_REPLICAS=""
if [[ "$_FLAVOR" == "physical" ]]; then
  _STS_JSON=$(_pbm_phys_get_sts_json "$PBM_STS") \
    || fail_task "PBM_CLI_ERROR" "could not read StatefulSet ${PBM_STS}"
  _MONGOD_C=$(pbm_phys_detect_mongod_container "$_STS_JSON" "$PBM_AGENT_CONTAINER") \
    || fail_task "PHYSICAL_UNSUPPORTED_SPEC" "could not identify the mongod container on StatefulSet ${PBM_STS}"
  _ENGINE=$(pbm_phys_detect_engine "$PBM_POD" "$_MONGOD_C") || _ENGINE="unknown"
  if [[ "$_ENGINE" != psmdb:* ]]; then
    fail_task "PSMDB_REQUIRED" \
      "physical restores need Percona Server for MongoDB (the agent spawns temporary mongod processes from the container image); this mongod reports '${_ENGINE}'" \
      '{"see":"docs/mongodb/pbm.md#deployment-requirements"}'
  fi
  _HAS_CMD=$(jq -r --arg m "$_MONGOD_C" \
    '(.spec.template.spec.containers[] | select(.name==$m) | .command // []) | length' <<< "$_STS_JSON")
  if [[ "${_HAS_CMD:-0}" == "0" ]]; then
    fail_task "PHYSICAL_UNSUPPORTED_SPEC" \
      "the ${_MONGOD_C} container has no explicit command — the takeover supervisor cannot reproduce an image-default entrypoint" \
      '{"hint":"set an explicit command (e.g. [\"mongod\"]) plus args on the mongod container","see":"docs/mongodb/pbm.md#physical-restore"}'
  fi
  pbm_phys_in_progress "$_STS_JSON" && _TAKEOVER_LEFTOVER=true
  _REPLICAS=$(jq -r '.spec.replicas // 1' <<< "$_STS_JSON")
  log_debug "pbm-restore" "physical preconditions ok: mongod_container=${_MONGOD_C} engine=${_ENGINE} replicas=${_REPLICAS} takeover_leftover=${_TAKEOVER_LEFTOVER}"
fi

# ── dry-run: preview only ────────────────────────────────────────────────────
if bool_enabled "$DRY_RUN"; then
  log_info "pbm-restore" "dry-run: target valid (${_BACKUP_NAME:-time=${_TIME}}), flavor=${_FLAVOR}, pitr_enabled=${_PITR_ENABLED} — no changes made"
  jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg sts "$PBM_STS" \
    --arg backup_name "$_BACKUP_NAME" \
    --arg time "$_TIME" \
    --arg ns_filter "$_NS_FILTER" \
    --arg flavor "$_FLAVOR" \
    --arg base_name "$_BASE_NAME" \
    --arg base_type "$_BASE_TYPE" \
    --argjson pitr_enabled "$_PITR_ENABLED" \
    --argjson takeover_leftover "$_TAKEOVER_LEFTOVER" \
    --argjson target "$_TARGET_DESC" \
    '{dry_run: true, namespace: $namespace, sts: $sts,
      restore_flavor: $flavor,
      would_restore: ((if $backup_name != "" then {mode: "snapshot", backup_name: $backup_name} else {mode: "pitr", time: $time, base_snapshot: $base_name, base_type: $base_type} end)
        + (if $ns_filter == "" then {} else {ns_filter: $ns_filter} end)),
      target_backup: $target,
      pitr_enabled: $pitr_enabled,
      pitr_will_be_disabled: $pitr_enabled,
      post_restore_required: (if $pitr_enabled then "after the restore: run pbm/backup (fresh base), then pbm/pitr enabled=true" else null end),
      note: "restore replaces live data in the replica set — every write after the restore point is lost (selective ns_filter limits the blast radius to the listed collections)"}
     + (if $flavor == "physical" then
         {downtime: true,
          downtime_note: "physical restore takes the FULL CLUSTER OFFLINE for the whole restore window — plan a maintenance window",
          plan: ["disable PITR if enabled",
                 "patch StatefulSet into pbm takeover mode (supervised mongod, probes off, sidecar parked)",
                 "recreate all pods on the takeover template",
                 "start pbm restore; progress is tracked on the S3 storage (database is down)",
                 "revert the StatefulSet surgically and recreate all pods on the restored data",
                 "force-resync PBM metadata"]}
         + (if $takeover_leftover then {takeover_leftover: true, warning: "a previous takeover annotation is still on the StatefulSet — confirm will revert it first; only proceed after verifying no restore is still running (pbm/logs)"} else {} end)
       else {} end)' \
    > "$AQSH_RESULT_FILE"
  exit 0
fi

# ── confirm: shared step — PITR off before any restore ───────────────────────
_PITR_WAS_ENABLED="$_PITR_ENABLED"
if [[ "$_PITR_ENABLED" == "true" ]]; then
  log_warn "pbm-restore" "PITR slicing is enabled — disabling it for the restore (PBM requirement); it stays off until a fresh base backup + explicit pbm/pitr enabled=true"
  _PITR_OUT=$(pbm_pitr_set "$PBM_POD" "$PBM_AGENT_CONTAINER" "false") \
    || fail_task "PITR_DISABLE_FAILED" "could not disable PITR before the restore" \
      "$(jq -nc --arg raw "${_PITR_OUT:0:1000}" '{raw_output:$raw}')"
fi

# =============================================================================
# LOGICAL flavor — online restore (mongod keeps running)
# =============================================================================
if [[ "$_FLAVOR" == "logical" ]]; then
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

  log_info "pbm-restore" "logical restore ${_RESTORE_NAME} done (${_BACKUP_NAME:-time=${_TIME}})"

  jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg sts "$PBM_STS" \
    --arg restore_name "$_RESTORE_NAME" \
    --arg backup_name "$_BACKUP_NAME" \
    --arg time "$_TIME" \
    --arg ns_filter "$_NS_FILTER" \
    --argjson pitr_was_enabled "$_PITR_WAS_ENABLED" \
    --argjson final "$_FINAL" \
    '{namespace: $namespace, sts: $sts, status: "done", restore_flavor: "logical",
      restore_name: $restore_name,
      restored: ((if $backup_name != "" then {mode: "snapshot", backup_name: $backup_name} else {mode: "pitr", time: $time} end)
        + (if $ns_filter == "" then {} else {ns_filter: $ns_filter} end)),
      detail: $final,
      pitr_was_enabled: $pitr_was_enabled,
      pitr_enabled_now: false,
      post_restore_required: "run pbm/backup (fresh base backup), then pbm/pitr enabled=true to resume point-in-time coverage"}' \
    > "$AQSH_RESULT_FILE"
  exit 0
fi

# =============================================================================
# PHYSICAL flavor — full-downtime StatefulSet takeover
# =============================================================================

# Best-effort rollback used by every failure path below EXCEPT wait-timeout
# (reverting while agents may still be copying data would corrupt the
# restore — a timeout leaves the takeover in place deliberately).
_phys_rollback() {
  local ctx="${1:?}"
  log_warn "pbm-restore" "rolling back takeover after failure at: ${ctx}"
  if pbm_phys_revert_takeover "$PBM_STS" >/dev/null; then
    pbm_phys_recreate_pods "$PBM_STS" 420 \
      || log_error "pbm-restore" "pods did not come back Ready after rollback — inspect with recovery/pre-check"
  else
    log_error "pbm-restore" "takeover revert failed — StatefulSet ${PBM_STS} still carries ${_PBM_PHYS_ANNOTATION}; re-run pbm/restore (confirm) to retry, or revert manually"
  fi
}

# Leftover takeover from an earlier failed/interrupted run: revert first
# (self-heal spirit) — the dry-run warned that this must only happen after
# verifying no restore is still running.
if [[ "$_TAKEOVER_LEFTOVER" == "true" ]]; then
  log_warn "pbm-restore" "reverting leftover takeover on ${PBM_STS} before starting a new physical restore"
  pbm_phys_revert_takeover "$PBM_STS" >/dev/null \
    || fail_task "REVERT_FAILED" "could not revert the leftover takeover on ${PBM_STS}" \
      '{"hint":"kubectl describe sts and the pbm-restore/original annotation hold the original shape; revert manually, then re-run"}'
  pbm_phys_recreate_pods "$PBM_STS" 420 \
    || fail_task "POST_RESTORE_UNHEALTHY" "pods did not come back Ready after reverting the leftover takeover" \
      '{"hint":"inspect with recovery/pre-check before retrying"}'
fi

log_info "pbm-restore" "physical restore starting: FULL CLUSTER DOWNTIME begins (${_BACKUP_NAME:-time=${_TIME}, base=${_BASE_NAME}})"

_PATCH_RC=0
_PATCH_OUT=$(pbm_phys_patch_takeover "$PBM_STS" "$_MONGOD_C" "$PBM_AGENT_CONTAINER") || _PATCH_RC=$?
if (( _PATCH_RC == 2 )); then
  fail_task "PHYSICAL_UNSUPPORTED_SPEC" \
    "the ${_MONGOD_C} container has no explicit command — the takeover supervisor cannot reproduce an image-default entrypoint"
elif (( _PATCH_RC != 0 )); then
  fail_task "TAKEOVER_PATCH_FAILED" "could not patch StatefulSet ${PBM_STS} into takeover mode" \
    "$(jq -nc --arg raw "${_PATCH_OUT:0:500}" '{raw_output:$raw, hint:"check RBAC (statefulsets patch) and kubectl connectivity"}')"
fi

if ! pbm_phys_recreate_pods "$PBM_STS" 420; then
  _phys_rollback "takeover pod recreation"
  fail_task "TAKEOVER_PODS_NOT_READY" "pods did not become Ready on the takeover template" \
    '{"hint":"kubectl describe pods for image-pull/init-container errors; the takeover was rolled back"}'
fi
if ! pbm_phys_wait_agents "$PBM_POD" "$_MONGOD_C" "$_REPLICAS" 240; then
  _phys_rollback "takeover agent registration"
  fail_task "TAKEOVER_PODS_NOT_READY" "takeover pbm-agents did not all report ok" \
    '{"hint":"kubectl logs <pod> -c '"$_MONGOD_C"' shows the supervisor + pbm-agent output; the takeover was rolled back"}'
fi

_RESTORE_ARGS=()
if [[ -n "$_BACKUP_NAME" ]]; then
  _RESTORE_ARGS=(restore "$_BACKUP_NAME")
else
  _RESTORE_ARGS=(restore --time "$_TIME" --base-snapshot "$_BASE_NAME")
fi
_START_OUT=$(_pbm_phys_exec_json "$PBM_POD" "$_MONGOD_C" "${_RESTORE_ARGS[@]}") || {
  _phys_rollback "pbm restore start"
  fail_task "RESTORE_START_FAILED" "pbm restore did not start" \
    "$(jq -nc --arg raw "${_START_OUT:0:1000}" --argjson pitr_was_enabled "$_PITR_WAS_ENABLED" \
      '{raw_output: $raw, pitr_was_enabled: $pitr_was_enabled, note: "the takeover was rolled back"}')"
}
_RESTORE_NAME=$(jq -r '.name // empty' <<< "$_START_OUT")
[[ -z "$_RESTORE_NAME" ]] && {
  _phys_rollback "pbm restore start (no name returned)"
  fail_task "RESTORE_START_FAILED" "pbm restore returned no restore name" \
    "$(jq -nc --arg raw "${_START_OUT:0:1000}" '{raw_output:$raw}')"
}
log_info "pbm-restore" "physical restore ${_RESTORE_NAME} running — database is DOWN, progress tracked on the S3 storage"

_WAIT_RC=0
_FINAL=$(pbm_phys_wait_restore "$PBM_POD" "$_MONGOD_C" "$_RESTORE_NAME" "$_WAIT_TIMEOUT") || _WAIT_RC=$?
if (( _WAIT_RC == 124 )); then
  # Deliberately NOT rolled back: agents may still be copying data files;
  # reverting mid-flight would corrupt the restore.
  fail_task "WAIT_TIMEOUT" "physical restore ${_RESTORE_NAME} did not finish within ${_WAIT_TIMEOUT}s" \
    "$(jq -nc --arg name "$_RESTORE_NAME" --arg sts "$PBM_STS" \
      '{restore_name: $name,
        takeover_left_in_place: true,
        note: "the restore may still be running — the takeover was deliberately NOT reverted",
        next_steps: ["watch progress: kubectl logs <pod> -c mongod-container / pbm/logs after recovery",
                     ("re-run pbm/restore (dry_run) — it reports takeover_leftover; once the restore is confirmed finished or dead, confirm reverts the takeover first")]}')"
elif (( _WAIT_RC != 0 )); then
  _phys_rollback "physical restore execution"
  fail_task "RESTORE_FAILED" "physical restore ${_RESTORE_NAME} failed" \
    "$(jq -nc --arg name "$_RESTORE_NAME" \
      --arg error "$(jq -r '.error // "unknown error"' <<< "${_FINAL:-null}" 2>/dev/null)" \
      --argjson pitr_was_enabled "$_PITR_WAS_ENABLED" \
      '{restore_name: $name, error: $error, pitr_was_enabled: $pitr_was_enabled,
        warning: "data files may be in a partially-restored state — verify with recovery/pre-check and sanity-check before trusting this cluster; consider re-running the restore",
        note: "the takeover was rolled back"}')"
fi

log_info "pbm-restore" "physical restore ${_RESTORE_NAME} done — reverting takeover and restarting the cluster on the restored data"

pbm_phys_revert_takeover "$PBM_STS" >/dev/null \
  || fail_task "REVERT_FAILED" "restore succeeded but the takeover revert failed on ${PBM_STS}" \
    "$(jq -nc --arg name "$_RESTORE_NAME" \
      '{restore_name: $name,
        hint: "the data is restored; revert the StatefulSet manually (pbm-restore/original annotation holds the original shape) or re-run pbm/restore confirm to retry the revert",
        pitr_enabled_now: false}')"

if ! pbm_phys_recreate_pods "$PBM_STS" 600; then
  fail_task "POST_RESTORE_UNHEALTHY" "restore + revert succeeded but pods did not come back Ready on the restored data" \
    "$(jq -nc --arg name "$_RESTORE_NAME" \
      '{restore_name: $name, hint: "inspect with recovery/pre-check and sanity-check; mongod may still be replaying — retry readiness manually"}')"
fi

_RESYNC_OK=true
pbm_wait_agents_ready "$PBM_POD" "$PBM_AGENT_CONTAINER" 120
_RESYNC_OUT=$(_pbm_exec "$PBM_POD" "$PBM_AGENT_CONTAINER" config --force-resync) || {
  _RESYNC_OK=false
  log_warn "pbm-restore" "post-restore force-resync failed (run pbm/config confirm later): ${_RESYNC_OUT:0:300}"
}

log_info "pbm-restore" "physical restore complete — cluster is back on the restored data (downtime window closed)"

jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg sts "$PBM_STS" \
  --arg restore_name "$_RESTORE_NAME" \
  --arg backup_name "$_BACKUP_NAME" \
  --arg time "$_TIME" \
  --arg base_name "$_BASE_NAME" \
  --arg base_type "$_BASE_TYPE" \
  --argjson pitr_was_enabled "$_PITR_WAS_ENABLED" \
  --argjson resync_ok "$_RESYNC_OK" \
  --argjson final "$_FINAL" \
  '{namespace: $namespace, sts: $sts, status: "done", restore_flavor: "physical",
    downtime: true,
    restore_name: $restore_name,
    restored: (if $backup_name != "" then {mode: "snapshot", backup_name: $backup_name} else {mode: "pitr", time: $time, base_snapshot: $base_name, base_type: $base_type} end),
    detail: $final,
    takeover_reverted: true,
    metadata_resynced: $resync_ok,
    pitr_was_enabled: $pitr_was_enabled,
    pitr_enabled_now: false,
    post_restore_required: "run pbm/backup (fresh base backup), then pbm/pitr enabled=true to resume point-in-time coverage"}' \
  > "$AQSH_RESULT_FILE"
