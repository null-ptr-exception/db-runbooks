#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/profiler/set.sh
# aqsh task: set the query profiler level/threshold on a single node — the
# elected PRIMARY by default, or an explicit target_pod. Gated
# dry_run -> confirm. The profiler level is per-node state, so this only
# ever affects one member at a time (see docs/mongodb/profiler.md).
# level=2 profiles every operation and has a real performance cost — dry-run
# surfaces a non-fatal high_impact_warning in that case, but never blocks.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE — target namespace, e.g. "mongo-1"
#   TARGET_POD   — optional; defaults to the elected PRIMARY
#   LEVEL        — required; 0 (off), 1 (slow ops only), or 2 (all ops)
#   SLOWMS       — optional, default 100; threshold in ms for level 1
#   SAMPLE_RATE  — optional, default 1.0; fraction of ops to profile (0-1)
#   DRY_RUN      — default "true": preview current vs requested, change nothing
#   CONFIRM      — must be "true" when DRY_RUN is "false"
#   LOG_LEVEL    — optional per-call log verbosity
#
# sts_name/credential secret/user/keys are not task inputs (see CLAUDE.md
# "Configuration Layers") — they resolve internal config -> live cluster
# auto-detect -> hardcoded literal fallback.
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-recovery.sh"
source "${LIB_DIR}/mongodb-account.sh"
source "${LIB_DIR}/mongodb-profiler.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
log_set_level "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT:-INFO}}"
_TARGET_POD_INPUT="${TARGET_POD:-}"
_LEVEL="${LEVEL:?LEVEL is required}"
_SLOWMS="${SLOWMS:-100}"
_SAMPLE_RATE="${SAMPLE_RATE:-1}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"

# ── Gate (same triad as fcv/set) ─────────────────────────────────────────────
if bool_enabled "$DRY_RUN" && bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true with dry_run=true is not supported"
fi
if ! bool_enabled "$DRY_RUN" && ! bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true is required when dry_run=false"
fi
if [[ ! "$_LEVEL" =~ ^[0-2]$ ]]; then
  fail_task "INVALID_INPUT" "level must be 0, 1, or 2 (got '${_LEVEL}')"
fi
if [[ ! "$_SLOWMS" =~ ^[0-9]+$ ]]; then
  fail_task "INVALID_INPUT" "slowms must be a non-negative integer (got '${_SLOWMS}')"
fi
if ! [[ "$_SAMPLE_RATE" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then
  fail_task "INVALID_INPUT" "sample_rate must be between 0 and 1 (got '${_SAMPLE_RATE}')"
fi

# ── Resolve deployment naming + credentials (3-tier, no task-input tier) ────
_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "$_TARGET_POD_INPUT")
_CRED_ROW=$(recovery_resolve_credentials \
  "${MONGO_CRED_SECRET_DEFAULT:-}" \
  "${MONGO_CRED_USER_DEFAULT:-}" \
  "${MONGO_CRED_USER_KEY_DEFAULT:-}" \
  "${MONGO_CRED_PASS_KEY_DEFAULT:-}" \
  "$_STS")
IFS=$'\x1f' read -r _SECRET _DIRECT_USER _USER_KEY _PASS_KEY <<<"$_CRED_ROW"

log_info "profiler-set" "STS=${_STS} namespace=${DB_NAMESPACE} target_pod=${_TARGET_POD_INPUT:-<primary>} level=${_LEVEL} slowms=${_SLOWMS} sample_rate=${_SAMPLE_RATE} dry_run=${DRY_RUN}"
log_debug "profiler-set" "resolved credentials: secret=${_SECRET} user_key=${_USER_KEY:-<direct>} pass_key=${_PASS_KEY}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"

_PROBE=$(_profiler_probe_pod "$_STS") \
  || fail_task "NO_PRIMARY" "no Ready/Running pod found for StatefulSet ${_STS} in ${DB_NAMESPACE}"
log_debug "profiler-set" "probe pod: ${_PROBE}"

_TARGET_ROW=$(_profiler_resolve_target "$_STS" "$_PROBE" "$_TARGET_POD_INPUT" "$_MONGO_USER" "$_MONGO_PASS") \
  || fail_task "NO_PRIMARY" "no target_pod given and no reachable PRIMARY for StatefulSet ${_STS} in ${DB_NAMESPACE}"
IFS=$'\x1f' read -r _EXEC_POD _DIRECT_HOST <<<"$_TARGET_ROW"
log_debug "profiler-set" "exec_pod=${_EXEC_POD} direct_host=${_DIRECT_HOST:-<local>}"

_CURRENT=$(profiler_get_status "$_EXEC_POD" "$_DIRECT_HOST" "$_MONGO_USER" "$_MONGO_PASS") \
  || fail_task "PROFILER_READ_FAILED" "could not read profiling status from ${_TARGET_POD_INPUT:-primary} (${_EXEC_POD})"

_CUR_LEVEL=$(jq -r '.level' <<<"$_CURRENT")
_CUR_SLOWMS=$(jq -r '.slowms' <<<"$_CURRENT")
_CUR_SAMPLE=$(jq -r '.sampleRate' <<<"$_CURRENT")
_TARGET_DISPLAY="${_TARGET_POD_INPUT:-$_EXEC_POD}"

_WARNING=""
[[ "$_LEVEL" == "2" ]] && _WARNING="level=2 profiles every operation and has a real performance cost; consider reverting to level=0/1 once diagnosis is done"

# Already there: completed no-op, not an error.
if [[ "$_CUR_LEVEL" == "$_LEVEL" && "$_CUR_SLOWMS" == "$_SLOWMS" && "$_CUR_SAMPLE" == "$_SAMPLE_RATE" ]]; then
  log_info "profiler-set" "already at level=${_LEVEL} slowms=${_SLOWMS} sample_rate=${_SAMPLE_RATE} on ${_TARGET_DISPLAY}; nothing to do"
  write_task_result "$(jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg target_pod "$_TARGET_DISPLAY" \
    --argjson current "$_CURRENT" \
    '{status:"ok", reason_code:"ALREADY_AT_TARGET",
      summary:"Profiler is already at the requested level/threshold; no change applied.",
      namespace:$namespace, target_pod:$target_pod, previous:$current, current:$current, changed:false}')"
  exit 0
fi

if bool_enabled "$DRY_RUN"; then
  log_info "profiler-set" "dry-run: would set level ${_CUR_LEVEL} -> ${_LEVEL} on ${_TARGET_DISPLAY}"
  write_task_result "$(jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg target_pod "$_TARGET_DISPLAY" \
    --argjson current "$_CURRENT" \
    --argjson requested "$(jq -nc --argjson level "$_LEVEL" --argjson slowms "$_SLOWMS" --argjson sampleRate "$_SAMPLE_RATE" \
      '{level:$level, slowms:$slowms, sampleRate:$sampleRate}')" \
    --arg warning "$_WARNING" \
    '{status:"DRY_RUN_READY", reason_code:"DRY_RUN_READY",
      summary:"Dry-run only. Would change the profiler settings shown below.",
      namespace:$namespace, target_pod:$target_pod,
      previous:$current, requested:$requested, changed:false, would_change:true}
     + (if $warning == "" then {} else {high_impact_warning:$warning} end)')"
  exit 0
fi

# ── Execute ──────────────────────────────────────────────────────────────────
_NEW_STATUS=$(profiler_set "$_EXEC_POD" "$_DIRECT_HOST" "$_MONGO_USER" "$_MONGO_PASS" "$_LEVEL" "$_SLOWMS" "$_SAMPLE_RATE") \
  || fail_task "PROFILER_SET_FAILED" \
    "setProfilingLevel(${_LEVEL}) failed on ${_TARGET_DISPLAY}" \
    "$(jq -nc --arg server_response "${_NEW_STATUS:-}" '{server_response:$server_response}')"

log_info "profiler-set" "level ${_CUR_LEVEL} -> $(jq -r '.level' <<<"$_NEW_STATUS") completed on ${_TARGET_DISPLAY}"
write_task_result "$(jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg target_pod "$_TARGET_DISPLAY" \
  --argjson previous "$_CURRENT" \
  --argjson current "$_NEW_STATUS" \
  --arg warning "$_WARNING" \
  '{status:"ok", reason_code:"PROFILER_SET",
    summary:"Profiler settings changed.",
    namespace:$namespace, target_pod:$target_pod,
    previous:$previous, current:$current, changed:true}
   + (if $warning == "" then {} else {high_impact_warning:$warning} end)')"
