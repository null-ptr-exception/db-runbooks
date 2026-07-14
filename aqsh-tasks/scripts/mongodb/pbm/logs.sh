#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/pbm/logs.sh
# aqsh task: read-only PBM agent log stream — the tool for diagnosing a
# failed backup/restore by event name (e.g. event "backup/2026-07-10T05:23:41Z").
# Kept separate from pbm/status: this is the historical stream, status is
# the point-in-time snapshot. See docs/mongodb/pbm.md.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE     — target namespace
#   PBM_LOG_TAIL     — number of entries (default 50)
#   PBM_LOG_SEVERITY — optional D|I|W|E|F filter
#   PBM_LOG_EVENT    — optional event filter, e.g. "backup/<name>"
#   LOG_LEVEL        — optional per-call log verbosity
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

_TAIL="${PBM_LOG_TAIL:-50}"
_SEVERITY="${PBM_LOG_SEVERITY:-}"
_EVENT="${PBM_LOG_EVENT:-}"

pbm_task_init "pbm-logs"

_ENTRIES=$(pbm_logs_json "$PBM_POD" "$PBM_AGENT_CONTAINER" "$_TAIL" "$_SEVERITY" "$_EVENT") \
  || fail_task "PBM_CLI_ERROR" "pbm logs failed in ${PBM_POD}/${PBM_AGENT_CONTAINER}" \
    "$(jq -nc --arg raw "${_ENTRIES:0:1000}" '{raw_output:$raw}')"

log_info "pbm-logs" "returned $(jq -r 'if type == "array" then length else 0 end' <<< "$_ENTRIES") entries (tail=${_TAIL}${_SEVERITY:+ severity=${_SEVERITY}}${_EVENT:+ event=${_EVENT}})"

jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg sts "$PBM_STS" \
  --arg tail "$_TAIL" \
  --arg severity "$_SEVERITY" \
  --arg event "$_EVENT" \
  --argjson entries "$_ENTRIES" \
  '{namespace: $namespace, sts: $sts, tail: ($tail | tonumber), entries: $entries}
   + (if $severity == "" then {} else {severity: $severity} end)
   + (if $event == "" then {} else {event: $event} end)' \
  > "$AQSH_RESULT_FILE"
