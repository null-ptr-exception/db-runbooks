#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/pbm/backup.sh
# aqsh task: start a PBM backup (logical | physical | incremental, optional
# selective --ns for logical) and, by default, wait for completion. Storage
# config is auto-ensured on first use (G1-self-heal spirit); an existing
# config pointing elsewhere is never overwritten — that path fails with
# STORAGE_CONFIG_MISMATCH and points at pbm/config.
#
# physical/incremental run online (no takeover needed): the agent opens a
# $backupCursor and streams data files off the shared volume — which is why
# they gate on the two live-detected prerequisites: the mongod engine must
# be Percona Server for MongoDB (PSMDB_REQUIRED otherwise; $backupCursor is
# a PSMDB extension) and the agent sidecar must mount the data volume at
# the same path (AGENT_NO_DATA_VOLUME otherwise). An incremental backup
# with no existing chain automatically becomes the --base. "external"
# stays rejected (snapshot tooling is infra-owned). Ungated: a backup adds
# an artifact and mutates no database state. See docs/mongodb/pbm.md.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE     — target namespace
#   PBM_BACKUP_TYPE  — logical (default) | physical | incremental
#   PBM_NS_FILTER    — optional selective backup filter, e.g. "app.orders"
#                      (logical only — PBM restriction)
#   PBM_WAIT         — default "true": poll until done/error
#   PBM_WAIT_TIMEOUT — poll budget in seconds (default 1200)
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

_TYPE="${PBM_BACKUP_TYPE:-logical}"
[[ -z "$_TYPE" ]] && _TYPE="logical"
_NS_FILTER="${PBM_NS_FILTER:-}"
_WAIT="${PBM_WAIT:-true}"
_WAIT_TIMEOUT="${PBM_WAIT_TIMEOUT:-1200}"

if [[ "$_TYPE" == "external" ]]; then
  fail_task "UNSUPPORTED_BACKUP_TYPE" \
    "backup type 'external' is not supported — snapshot orchestration is infra-owned" \
    '{"requested_type":"external","supported":["logical","physical","incremental"],"see":"docs/mongodb/pbm.md"}'
fi
if [[ "$_TYPE" != "logical" && -n "$_NS_FILTER" ]]; then
  fail_task "INVALID_INPUT" \
    "selective backup (ns) is a logical-only PBM feature — physical/incremental always capture the whole data set"
fi
# Belt-and-braces after the tasks.yaml pattern check.
if [[ ! "$_WAIT_TIMEOUT" =~ ^[0-9]+$ ]]; then
  fail_task "INVALID_INPUT" "wait_timeout must be an integer number of seconds (got '${_WAIT_TIMEOUT}')"
fi

pbm_task_init "pbm-backup"

# ── physical/incremental prerequisites (live-detected, never guessed) ────────
_WITH_BASE="false"
if [[ "$_TYPE" != "logical" ]]; then
  _STS_JSON=$(_pbm_phys_get_sts_json "$PBM_STS") \
    || fail_task "PBM_CLI_ERROR" "could not read StatefulSet ${PBM_STS}"
  _MONGOD_C=$(pbm_phys_detect_mongod_container "$_STS_JSON" "$PBM_AGENT_CONTAINER") \
    || fail_task "PHYSICAL_UNSUPPORTED_SPEC" "could not identify the mongod container on StatefulSet ${PBM_STS}"

  _ENGINE=$(pbm_phys_detect_engine "$PBM_POD" "$_MONGOD_C") || _ENGINE="unknown"
  log_debug "pbm-backup" "engine=${_ENGINE} mongod_container=${_MONGOD_C}"
  if [[ "$_ENGINE" != psmdb:* ]]; then
    fail_task "PSMDB_REQUIRED" \
      "${_TYPE} backups need Percona Server for MongoDB (\$backupCursor); this mongod reports '${_ENGINE}'" \
      "$(jq -nc --arg engine "$_ENGINE" --arg type "$_TYPE" \
        '{requested_type: $type, engine: $engine,
          hint: "run the percona/percona-server-mongodb image (a drop-in replacement) to enable physical backups; logical backups work on any engine",
          see: "docs/mongodb/pbm.md#deployment-requirements"}')"
  fi

  _MISSING=$(pbm_phys_agent_volume_ok "$_STS_JSON" "$PBM_AGENT_CONTAINER" "$_MONGOD_C") || {
    fail_task "AGENT_NO_DATA_VOLUME" \
      "the ${PBM_AGENT_CONTAINER} sidecar does not mount the mongod data volume(s) at the same path — physical backups read data files directly" \
      "$(jq -nc --argjson missing "${_MISSING:-[]}" \
        '{missing_mounts: $missing,
          hint: "add the data volumeMount(s) to the agent sidecar (same name, same mountPath); this is a deployment change, deliberately not auto-patched by a backup task",
          see: "docs/mongodb/pbm.md#deployment-requirements"}')"
  }

  if [[ "$_TYPE" == "incremental" ]]; then
    _LIST_JSON=$(pbm_list_json "$PBM_POD" "$PBM_AGENT_CONTAINER") || _LIST_JSON='{}'
    if ! printf '%s' "$_LIST_JSON" | jq -e \
        '[.snapshots[]? | select(.type == "incremental" and .status == "done")] | length > 0' >/dev/null 2>&1; then
      _WITH_BASE="true"
      log_debug "pbm-backup" "no completed incremental chain found — this backup becomes the --base"
    fi
  fi
fi

pbm_require_storage "pbm-backup"
# Generous budget: on a fresh deployment the auto-ensure above wrote the
# very first config, and agents only register after one exists.
pbm_wait_agents_ready "$PBM_POD" "$PBM_AGENT_CONTAINER" 120

_NAME=$(pbm_start_backup "$PBM_POD" "$PBM_AGENT_CONTAINER" "$_TYPE" "$_NS_FILTER" "$_WITH_BASE") \
  || fail_task "BACKUP_START_FAILED" "pbm backup did not start" \
    "$(jq -nc --arg raw "${_NAME:0:1000}" '{raw_output:$raw, hint:"pbm/status shows agent health; pbm/logs severity=E shows agent-side errors"}')"

_STATUS="starting"
_DESC='null'
if bool_enabled "$_WAIT"; then
  _WAIT_RC=0
  _DESC=$(pbm_wait_backup "$PBM_POD" "$PBM_AGENT_CONTAINER" "$_NAME" "$_WAIT_TIMEOUT") || _WAIT_RC=$?
  if (( _WAIT_RC == 124 )); then
    fail_task "WAIT_TIMEOUT" "backup ${_NAME} did not finish within ${_WAIT_TIMEOUT}s" \
      "$(jq -nc --arg name "$_NAME" \
        '{backup_name: $name,
          note: "the backup keeps running server-side — check it later with pbm/list name=<backup_name>",
          hint: "raise wait_timeout, or submit with wait=false for fire-and-forget"}')"
  elif (( _WAIT_RC != 0 )); then
    fail_task "BACKUP_FAILED" "backup ${_NAME} failed" \
      "$(jq -nc --arg name "$_NAME" --arg error "$(jq -r '.error // "unknown error"' <<< "${_DESC:-null}" 2>/dev/null)" \
        '{backup_name: $name, error: $error, hint: ("diagnose with pbm/logs event=backup/" + $name)}')"
  fi
  _STATUS=$(jq -r '.status // "done"' <<< "$_DESC")
else
  log_info "pbm-backup" "wait=false — backup ${_NAME} left running (fire-and-forget)"
fi

jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg sts "$PBM_STS" \
  --arg backup_name "$_NAME" \
  --arg type "$_TYPE" \
  --arg status "$_STATUS" \
  --arg ns_filter "$_NS_FILTER" \
  --arg endpoint "$PBM_ENDPOINT" --arg bucket "$PBM_BUCKET" --arg prefix "$PBM_PREFIX" \
  --argjson waited "$(bool_enabled "$_WAIT" && echo true || echo false)" \
  --argjson base "$_WITH_BASE" \
  --argjson desc "$_DESC" \
  '{namespace: $namespace, sts: $sts,
    backup_name: $backup_name, type: $type, status: $status,
    size_bytes: (if $desc == null then null else ($desc.size // null) end),
    storage: {endpointUrl: $endpoint, bucket: $bucket, prefix: $prefix},
    waited: $waited,
    restorable_by: {task: "pbm/restore", input: {namespace: $namespace, backup_name: $backup_name, confirm: "true", dry_run: "false"}}}
   + (if $type == "incremental" then {incremental_base: $base} else {} end)
   + (if $type == "logical" then {} else {restore_note: "restoring this backup takes the FULL CLUSTER OFFLINE for the restore window (StatefulSet takeover) — see docs/mongodb/pbm.md#physical-restore"} end)
   + (if $ns_filter == "" then {} else {ns_filter: $ns_filter} end)' \
  > "$AQSH_RESULT_FILE"
