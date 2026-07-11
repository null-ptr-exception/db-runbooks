#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/pbm/backup.sh
# aqsh task: start a PBM LOGICAL backup (optionally selective via --ns) and,
# by default, wait for completion. Storage config is auto-ensured on first
# use (G1-self-heal spirit); an existing config pointing elsewhere is never
# overwritten — that path fails with STORAGE_CONFIG_MISMATCH and points at
# pbm/config. physical/incremental/external types are rejected here: their
# restore needs mongod lifecycle control (Percona Operator territory), and a
# backup this deployment cannot restore is false safety. Ungated: a backup
# adds an artifact and mutates no database state. See docs/mongodb/pbm.md.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE     — target namespace
#   PBM_BACKUP_TYPE  — must be "logical" (default)
#   PBM_NS_FILTER    — optional selective backup filter, e.g. "app.orders"
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

export K8S_NAMESPACE="${DB_NAMESPACE}"
log_set_level "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT:-INFO}}"

_TYPE="${PBM_BACKUP_TYPE:-logical}"
[[ -z "$_TYPE" ]] && _TYPE="logical"
_NS_FILTER="${PBM_NS_FILTER:-}"
_WAIT="${PBM_WAIT:-true}"
_WAIT_TIMEOUT="${PBM_WAIT_TIMEOUT:-1200}"

if [[ "$_TYPE" != "logical" ]]; then
  fail_task "UNSUPPORTED_BACKUP_TYPE" \
    "backup type '${_TYPE}' is not supported on this deployment — logical only" \
    "$(jq -nc --arg type "$_TYPE" \
      '{requested_type: $type,
        reason: "physical/incremental restores need pbm-agent to stop/start mongod; in a plain StatefulSet mongod is the container PID 1, so that coordination needs the Percona Operator (or an operator-equivalent). A backup this deployment cannot restore is deliberately refused.",
        supported: ["logical"],
        see: "docs/mongodb/pbm.md#future-work"}')"
fi
# Belt-and-braces after the tasks.yaml pattern check.
if [[ ! "$_WAIT_TIMEOUT" =~ ^[0-9]+$ ]]; then
  fail_task "INVALID_INPUT" "wait_timeout must be an integer number of seconds (got '${_WAIT_TIMEOUT}')"
fi

pbm_task_init "pbm-backup"
pbm_require_storage "pbm-backup"
pbm_wait_agents_ready "$PBM_POD" "$PBM_AGENT_CONTAINER" 60

_NAME=$(pbm_start_backup "$PBM_POD" "$PBM_AGENT_CONTAINER" "$_NS_FILTER") \
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
  --arg status "$_STATUS" \
  --arg ns_filter "$_NS_FILTER" \
  --arg endpoint "$PBM_ENDPOINT" --arg bucket "$PBM_BUCKET" --arg prefix "$PBM_PREFIX" \
  --argjson waited "$(bool_enabled "$_WAIT" && echo true || echo false)" \
  --argjson desc "$_DESC" \
  '{namespace: $namespace, sts: $sts,
    backup_name: $backup_name, type: "logical", status: $status,
    size_bytes: (if $desc == null then null else ($desc.size // null) end),
    storage: {endpointUrl: $endpoint, bucket: $bucket, prefix: $prefix},
    waited: $waited,
    restorable_by: {task: "pbm/restore", input: {namespace: $namespace, backup_name: $backup_name, confirm: "true", dry_run: "false"}}}
   + (if $ns_filter == "" then {} else {ns_filter: $ns_filter} end)' \
  > "$AQSH_RESULT_FILE"
