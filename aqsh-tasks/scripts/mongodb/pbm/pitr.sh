#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/pbm/pitr.sh
# aqsh task: enable/disable PITR oplog slicing, gated dry_run -> confirm
# (state-changing config: disabling silently ends the recoverability
# window, enabling adds continuous storage traffic). Enabling requires at
# least one done base backup — PBM slices oplog only on top of a snapshot.
# oplog_span_min tunes the chunk interval (RPO granularity) and may be
# changed at any time, including while slicing runs. See docs/mongodb/pbm.md.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE       — target namespace
#   PBM_PITR_ENABLED   — required "true" | "false"
#   PBM_OPLOG_SPAN_MIN — optional chunk interval in minutes (PBM default 10)
#   DRY_RUN            — default "true"
#   CONFIRM            — must be "true" when DRY_RUN is "false"
#   LOG_LEVEL          — optional per-call log verbosity
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

_ENABLED="${PBM_PITR_ENABLED:?PBM_PITR_ENABLED is required}"
_SPAN="${PBM_OPLOG_SPAN_MIN:-}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"

# ── Gate ─────────────────────────────────────────────────────────────────────
if bool_enabled "$DRY_RUN" && bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true with dry_run=true is not supported"
fi
if ! bool_enabled "$DRY_RUN" && ! bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true is required when dry_run=false"
fi
# Belt-and-braces after the tasks.yaml pattern check.
if [[ "$_ENABLED" != "true" && "$_ENABLED" != "false" ]]; then
  fail_task "INVALID_INPUT" "enabled must be exactly 'true' or 'false' (got '${_ENABLED}')"
fi

pbm_task_init "pbm-pitr"

_STATUS_JSON=$(pbm_status_json "$PBM_POD" "$PBM_AGENT_CONTAINER") \
  || fail_task "PBM_CLI_ERROR" "pbm status failed in ${PBM_POD}/${PBM_AGENT_CONTAINER}" \
    "$(jq -nc --arg raw "${_STATUS_JSON:0:1000}" '{raw_output:$raw}')"
_CURRENT=false
pbm_pitr_enabled "$_STATUS_JSON" && _CURRENT=true

_HAS_BASE=false
if _LIST_JSON=$(pbm_list_json "$PBM_POD" "$PBM_AGENT_CONTAINER") \
    && pbm_has_done_base_backup "$_LIST_JSON"; then
  _HAS_BASE=true
fi
log_debug "pbm-pitr" "current=${_CURRENT} requested=${_ENABLED} span=${_SPAN:-<unchanged>} has_base_backup=${_HAS_BASE}"

_WOULD_FAIL=null
if [[ "$_ENABLED" == "true" && "$_HAS_BASE" == "false" ]]; then
  _WOULD_FAIL='"NO_BASE_BACKUP"'
fi

if bool_enabled "$DRY_RUN"; then
  log_info "pbm-pitr" "dry-run: current=${_CURRENT} requested=${_ENABLED}${_SPAN:+ span=${_SPAN}} would_fail=${_WOULD_FAIL} — no changes made"
  jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg sts "$PBM_STS" \
    --arg enabled "$_ENABLED" \
    --arg span "$_SPAN" \
    --argjson current "$_CURRENT" \
    --argjson would_fail "$_WOULD_FAIL" \
    '{dry_run: true, namespace: $namespace, sts: $sts,
      current: {enabled: $current},
      requested: ({enabled: ($enabled == "true")} + (if $span == "" then {} else {oplog_span_min: ($span | tonumber)} end)),
      would_change: (($enabled == "true") != $current or $span != ""),
      would_fail: $would_fail}
     + (if $would_fail == null then {} else {hint: "run pbm/backup first — PITR slices oplog on top of a done base snapshot"} end)' \
    > "$AQSH_RESULT_FILE"
  exit 0
fi

# ── confirm: execute ─────────────────────────────────────────────────────────
if [[ "$_ENABLED" == "true" ]]; then
  if [[ "$_HAS_BASE" == "false" ]]; then
    fail_task "NO_BASE_BACKUP" "cannot enable PITR: no completed base backup exists" \
      '{"hint":"run pbm/backup first — PITR slices oplog on top of a done base snapshot"}'
  fi
  pbm_require_storage "pbm-pitr"
fi

_OUT=$(pbm_pitr_set "$PBM_POD" "$PBM_AGENT_CONTAINER" "$_ENABLED" "$_SPAN") \
  || fail_task "PITR_SET_FAILED" "pbm config --set pitr.enabled=${_ENABLED} failed" \
    "$(jq -nc --arg raw "${_OUT:0:1000}" '{raw_output:$raw}')"

log_info "pbm-pitr" "PITR ${_ENABLED} confirmed (was ${_CURRENT})${_SPAN:+, oplogSpanMin=${_SPAN}}"

jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg sts "$PBM_STS" \
  --arg enabled "$_ENABLED" \
  --arg span "$_SPAN" \
  --argjson previous "$_CURRENT" \
  '{namespace: $namespace, sts: $sts, status: "done",
    pitr: ({enabled: ($enabled == "true"), previous_enabled: $previous}
      + (if $span == "" then {} else {oplog_span_min: ($span | tonumber)} end))}
   + (if $enabled == "true" then {note: "the covered window starts growing from the latest base backup; pbm/status shows chunk ranges as they flush"} else {note: "point-in-time coverage stopped at the newest flushed chunk"} end)' \
  > "$AQSH_RESULT_FILE"
