#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/pbm/status.sh
# aqsh task: read-only PBM health snapshot — agent state per replica-set
# node, storage config (configured? in sync with this deployment's resolved
# location?), PITR state + covered chunk ranges, currently running op, and
# snapshot inventory summary. Executes nothing, never mutates PBM config.
# See docs/mongodb/pbm.md.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE — target namespace, e.g. "mongo-pbm"
#   LOG_LEVEL    — optional per-call log verbosity (DEBUG|INFO|WARN|ERROR)
#
# sts_name / agent container / storage location are not task inputs (see
# CLAUDE.md "Configuration Layers") — they resolve internal config -> live
# cluster auto-detect -> hardcoded literal fallback.
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

pbm_task_init "pbm-status"

_STATUS_JSON=$(pbm_status_json "$PBM_POD" "$PBM_AGENT_CONTAINER") \
  || fail_task "PBM_CLI_ERROR" "pbm status failed in ${PBM_POD}/${PBM_AGENT_CONTAINER}" \
    "$(jq -nc --arg raw "${_STATUS_JSON:0:1000}" '{raw_output:$raw}')"

pbm_resolve_backup_location "$DB_NAMESPACE"

_CONFIGURED=false
_IN_SYNC=null
_CURRENT_STORAGE=null
if _CONFIG_JSON=$(pbm_get_config_json "$PBM_POD" "$PBM_AGENT_CONTAINER") \
    && printf '%s' "$_CONFIG_JSON" | jq -e '.storage.s3.bucket // empty' >/dev/null 2>&1; then
  _CONFIGURED=true
  _CURRENT_STORAGE=$(pbm_redact_config "$_CONFIG_JSON" | jq -c '.storage.s3 | {endpointUrl, bucket, prefix, region}')
  if pbm_storage_matches "$_CONFIG_JSON"; then _IN_SYNC=true; else _IN_SYNC=false; fi
fi
log_debug "pbm-status" "storage configured=${_CONFIGURED} in_sync=${_IN_SYNC}"

_RUNNING=$(pbm_current_op "$_STATUS_JSON")
_PITR_ENABLED=false
pbm_pitr_enabled "$_STATUS_JSON" && _PITR_ENABLED=true

log_info "pbm-status" "storage configured=${_CONFIGURED} pitr=${_PITR_ENABLED} running_op=$(jq -r 'if .==null then "none" else (.type // "unknown") end' <<< "$_RUNNING")"

jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg sts "$PBM_STS" \
  --arg agent_container "$PBM_AGENT_CONTAINER" \
  --argjson status "$_STATUS_JSON" \
  --argjson configured "$_CONFIGURED" \
  --argjson in_sync "$_IN_SYNC" \
  --argjson current_storage "$_CURRENT_STORAGE" \
  --arg endpoint "$PBM_ENDPOINT" --arg bucket "$PBM_BUCKET" --arg prefix "$PBM_PREFIX" \
  --argjson pitr_enabled "$_PITR_ENABLED" \
  --argjson running "$_RUNNING" \
  '{namespace: $namespace, sts: $sts, agent_container: $agent_container,
    agents: ($status.cluster // []),
    storage: {
      configured: $configured,
      in_sync: $in_sync,
      current: $current_storage,
      resolved: {endpointUrl: $endpoint, bucket: $bucket, prefix: $prefix}
    },
    pitr: {
      enabled: $pitr_enabled,
      running: ($status.pitr.run // false),
      chunk_ranges: [$status.backups.pitrChunks.pitrChunks[]?.range]
    },
    running: $running,
    snapshots: {
      count: ([$status.backups.snapshot[]?] | length),
      latest: ([$status.backups.snapshot[]? | select(.status == "done")] | sort_by(.restoreTo // 0) | last)
    }}' \
  > "$AQSH_RESULT_FILE"
