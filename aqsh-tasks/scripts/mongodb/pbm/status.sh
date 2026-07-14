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
source "${LIB_DIR}/mongodb-pbm-physical.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
log_set_level "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT:-INFO}}"

pbm_task_init "pbm-status"

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

# Without a storage config `pbm status` errors and agents cannot register
# (field-verified) — a fresh deployment must still get a useful status
# report, so degrade gracefully instead of failing. A status failure WITH
# a config present is a real error.
_NOTE=""
if ! _STATUS_JSON=$(pbm_status_json "$PBM_POD" "$PBM_AGENT_CONTAINER"); then
  if [[ "$_CONFIGURED" == "true" ]]; then
    fail_task "PBM_CLI_ERROR" "pbm status failed in ${PBM_POD}/${PBM_AGENT_CONTAINER}" \
      "$(jq -nc --arg raw "${_STATUS_JSON:0:1000}" '{raw_output:$raw}')"
  fi
  log_info "pbm-status" "pbm status unavailable and storage unconfigured — reporting the fresh-deployment view"
  _STATUS_JSON='{}'
  _NOTE="PBM storage is not configured yet — agents register once pbm/backup (auto-ensure) or pbm/config applies it"
fi
log_debug "pbm-status" "storage configured=${_CONFIGURED} in_sync=${_IN_SYNC}"

_RUNNING=$(pbm_current_op "$_STATUS_JSON")
_PITR_ENABLED=false
pbm_pitr_enabled "$_STATUS_JSON" && _PITR_ENABLED=true

# Physical-readiness report (every probe fails SOFT — status stays
# read-only and must never fail because a prerequisite is absent).
_ENGINE="unknown"
_AGENT_VOLUME=false
_TAKEOVER_LEFTOVER=false
if _STS_JSON=$(_pbm_phys_get_sts_json "$PBM_STS"); then
  if _MONGOD_C=$(pbm_phys_detect_mongod_container "$_STS_JSON" "$PBM_AGENT_CONTAINER"); then
    _ENGINE=$(pbm_phys_detect_engine "$PBM_POD" "$_MONGOD_C") || _ENGINE="unknown"
    pbm_phys_agent_volume_ok "$_STS_JSON" "$PBM_AGENT_CONTAINER" "$_MONGOD_C" >/dev/null && _AGENT_VOLUME=true
  fi
  pbm_phys_in_progress "$_STS_JSON" && _TAKEOVER_LEFTOVER=true
fi
log_debug "pbm-status" "physical readiness: engine=${_ENGINE} agent_data_volume=${_AGENT_VOLUME} takeover_leftover=${_TAKEOVER_LEFTOVER}"

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
  --arg engine "$_ENGINE" \
  --argjson agent_volume "$_AGENT_VOLUME" \
  --argjson takeover_leftover "$_TAKEOVER_LEFTOVER" \
  --arg note "$_NOTE" \
  '{namespace: $namespace, sts: $sts, agent_container: $agent_container,
    physical_ready: {engine: $engine, psmdb: ($engine | startswith("psmdb:")), agent_data_volume: $agent_volume},
    physical_restore_in_progress: $takeover_leftover,
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
    }}
   + (if $note == "" then {} else {note: $note} end)' \
  > "$AQSH_RESULT_FILE"
