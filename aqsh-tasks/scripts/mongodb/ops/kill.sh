#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/ops/kill.sh
# aqsh task: kill a running operation by opid on a single node — the
# elected PRIMARY by default, or an explicit target_pod. Gated
# dry_run -> confirm. opid is only meaningful on the same node it was
# observed on via ops/list — target_pod here must match the one used for
# that ops/list call. killOp only sets an interrupt flag (MongoDB does not
# guarantee immediate termination), so the post-kill state is reported
# honestly rather than asserted. See docs/mongodb/ops.md.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE — target namespace, e.g. "mongo-1"
#   TARGET_POD   — optional; defaults to the elected PRIMARY
#   OPID         — required; the operation id to kill
#   DRY_RUN      — default "true": look up the op, change nothing
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
source "${LIB_DIR}/mongodb-ops.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
log_set_level "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT:-INFO}}"
_TARGET_POD_INPUT="${TARGET_POD:-}"
_OPID="${OPID:?OPID is required}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"

# ── Gate (same triad as fcv/set) ─────────────────────────────────────────────
if bool_enabled "$DRY_RUN" && bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true with dry_run=true is not supported"
fi
if ! bool_enabled "$DRY_RUN" && ! bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true is required when dry_run=false"
fi
if [[ ! "$_OPID" =~ ^[0-9]+$ ]]; then
  fail_task "INVALID_INPUT" "opid must be a non-negative integer (got '${_OPID}')"
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

log_info "ops-kill" "STS=${_STS} namespace=${DB_NAMESPACE} target_pod=${_TARGET_POD_INPUT:-<primary>} opid=${_OPID} dry_run=${DRY_RUN}"
log_debug "ops-kill" "resolved credentials: secret=${_SECRET} user_key=${_USER_KEY:-<direct>} pass_key=${_PASS_KEY}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"

_PROBE=$(_ops_probe_pod "$_STS") \
  || fail_task "NO_PRIMARY" "no Ready/Running pod found for StatefulSet ${_STS} in ${DB_NAMESPACE}"
log_debug "ops-kill" "probe pod: ${_PROBE}"

_TARGET_ROW=$(_ops_resolve_target "$_STS" "$_PROBE" "$_TARGET_POD_INPUT" "$_MONGO_USER" "$_MONGO_PASS") \
  || fail_task "NO_PRIMARY" "no target_pod given and no reachable PRIMARY for StatefulSet ${_STS} in ${DB_NAMESPACE}"
IFS=$'\x1f' read -r _EXEC_POD _DIRECT_HOST <<<"$_TARGET_ROW"
log_debug "ops-kill" "exec_pod=${_EXEC_POD} direct_host=${_DIRECT_HOST:-<local>}"

_BEFORE=$(ops_get_one "$_EXEC_POD" "$_DIRECT_HOST" "$_MONGO_USER" "$_MONGO_PASS" "$_OPID") \
  || fail_task "OPS_READ_FAILED" "could not read currentOp for opid ${_OPID} from ${_TARGET_POD_INPUT:-primary} (${_EXEC_POD})"

_TARGET_DISPLAY="${_TARGET_POD_INPUT:-$_EXEC_POD}"

if [[ "$_BEFORE" == "null" ]]; then
  log_info "ops-kill" "opid ${_OPID} not found on ${_TARGET_DISPLAY} (already finished or never existed)"
  write_task_result "$(jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg target_pod "$_TARGET_DISPLAY" \
    --argjson opid "$_OPID" \
    '{status:"ok", reason_code:"OP_NOT_FOUND",
      summary:("No active operation with opid " + ($opid|tostring) + " on " + $target_pod + "."),
      namespace:$namespace, target_pod:$target_pod, opid:$opid, killed:false}')"
  exit 0
fi

if bool_enabled "$DRY_RUN"; then
  log_info "ops-kill" "dry-run: would kill opid ${_OPID} on ${_TARGET_DISPLAY}"
  write_task_result "$(jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg target_pod "$_TARGET_DISPLAY" \
    --argjson opid "$_OPID" \
    --argjson op "$_BEFORE" \
    '{status:"DRY_RUN_READY", reason_code:"DRY_RUN_READY",
      summary:("Dry-run only. Would kill opid " + ($opid|tostring) + " on " + $target_pod + "."),
      namespace:$namespace, target_pod:$target_pod, opid:$opid,
      op:$op, killed:false, would_kill:true}')"
  exit 0
fi

# ── Execute ──────────────────────────────────────────────────────────────────
_KILL_OUT=$(ops_kill "$_EXEC_POD" "$_DIRECT_HOST" "$_MONGO_USER" "$_MONGO_PASS" "$_OPID") \
  || fail_task "KILL_FAILED" \
    "killOp(${_OPID}) failed on ${_TARGET_DISPLAY}" \
    "$(jq -nc --arg server_response "${_KILL_OUT:-}" '{server_response:$server_response}')"

# Best-effort re-check — killOp is fire-and-forget, so "still visible" right
# after a successful command is expected, not a failure signal.
_AFTER=$(ops_get_one "$_EXEC_POD" "$_DIRECT_HOST" "$_MONGO_USER" "$_MONGO_PASS" "$_OPID" 2>/dev/null) || _AFTER="null"

log_info "ops-kill" "killOp(${_OPID}) completed on ${_TARGET_DISPLAY}; still_visible=$([[ "$_AFTER" == "null" ]] && echo false || echo true)"
write_task_result "$(jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg target_pod "$_TARGET_DISPLAY" \
  --argjson opid "$_OPID" \
  --argjson op_before "$_BEFORE" \
  --argjson still_visible "$([[ "$_AFTER" == "null" ]] && echo false || echo true)" \
  '{status:"ok", reason_code:"OP_KILLED",
    summary:("killOp(" + ($opid|tostring) + ") issued on " + $target_pod + "."),
    namespace:$namespace, target_pod:$target_pod, opid:$opid,
    op_before:$op_before, killed:true,
    still_visible_immediately_after:$still_visible}')"
