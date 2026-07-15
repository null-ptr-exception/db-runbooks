#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/pbm/list.sh
# aqsh task: read-only backup inventory. Without `name`, lists all snapshots
# plus the PITR ranges (and, optionally, past restores). With `name`, returns
# the full describe-backup detail for that one backup — describe is folded
# into list rather than being a separate task (same read-only data plane).
# See docs/mongodb/pbm.md.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE         — target namespace
#   PBM_BACKUP_NAME      — optional backup name for detail view
#   PBM_INCLUDE_RESTORES — "true" to include past restore operations
#   LOG_LEVEL            — optional per-call log verbosity
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

_NAME="${PBM_BACKUP_NAME:-}"
_INCLUDE_RESTORES="${PBM_INCLUDE_RESTORES:-false}"

pbm_task_init "pbm-list"

if [[ -n "$_NAME" ]]; then
  _DESC=$(pbm_describe_backup_json "$PBM_POD" "$PBM_AGENT_CONTAINER" "$_NAME") \
    || fail_task "BACKUP_NOT_FOUND" "backup '${_NAME}' not found or unreadable" \
      "$(jq -nc --arg raw "${_DESC:0:1000}" '{raw_output:$raw, hint:"run pbm/list without name for the inventory"}')"
  log_info "pbm-list" "describe-backup ${_NAME}: status=$(jq -r '.status // "unknown"' <<< "$_DESC")"
  jq -n --arg namespace "$DB_NAMESPACE" --arg sts "$PBM_STS" --argjson backup "$_DESC" \
    '{namespace: $namespace, sts: $sts, backup: $backup}' > "$AQSH_RESULT_FILE"
  exit 0
fi

_LIST_JSON=$(pbm_list_json "$PBM_POD" "$PBM_AGENT_CONTAINER") \
  || fail_task "PBM_CLI_ERROR" "pbm list failed in ${PBM_POD}/${PBM_AGENT_CONTAINER}" \
    "$(jq -nc --arg raw "${_LIST_JSON:0:1000}" '{raw_output:$raw}')"

_RESTORES='null'
if bool_enabled "$_INCLUDE_RESTORES"; then
  _RESTORES=$(_pbm_exec_json "$PBM_POD" "$PBM_AGENT_CONTAINER" list --restore) || _RESTORES='null'
  log_debug "pbm-list" "restore history included"
fi

log_info "pbm-list" "snapshots=$(jq -r '[.snapshots[]?] | length' <<< "$_LIST_JSON") pitr_on=$(jq -r '.pitr.on // false' <<< "$_LIST_JSON")"

jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg sts "$PBM_STS" \
  --argjson list "$_LIST_JSON" \
  --argjson restores "$_RESTORES" \
  '{namespace: $namespace, sts: $sts,
    snapshots: ($list.snapshots // []),
    pitr: {on: ($list.pitr.on // false), ranges: ($list.pitr.ranges // [])}}
   + (if $restores == null then {} else {restores: $restores} end)' \
  > "$AQSH_RESULT_FILE"
