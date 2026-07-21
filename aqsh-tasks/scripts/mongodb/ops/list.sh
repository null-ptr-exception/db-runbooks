#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/ops/list.sh
# aqsh task: read-only listing of currently active MongoDB operations on a
# single node — the elected PRIMARY by default, or an explicit target_pod.
# currentOp is per-node: an opid seen here means nothing on a different
# member (see docs/mongodb/ops.md). Executes nothing.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE      — target namespace, e.g. "mongo-1"
#   TARGET_POD        — optional; defaults to the elected PRIMARY
#   MIN_SECS_RUNNING  — optional int filter; 0 (default) means no filter
#   LOG_LEVEL         — optional per-call log verbosity
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
_MIN_SECS="${MIN_SECS_RUNNING:-0}"

if [[ ! "$_MIN_SECS" =~ ^[0-9]+$ ]]; then
  fail_task "INVALID_INPUT" "min_secs_running must be a non-negative integer (got '${_MIN_SECS}')"
fi

_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "$_TARGET_POD_INPUT")
_CRED_ROW=$(recovery_resolve_credentials \
  "${MONGO_CRED_SECRET_DEFAULT:-}" \
  "${MONGO_CRED_USER_DEFAULT:-}" \
  "${MONGO_CRED_USER_KEY_DEFAULT:-}" \
  "${MONGO_CRED_PASS_KEY_DEFAULT:-}" \
  "$_STS")
IFS=$'\x1f' read -r _SECRET _DIRECT_USER _USER_KEY _PASS_KEY <<<"$_CRED_ROW"

log_info "ops-list" "STS=${_STS} namespace=${DB_NAMESPACE} target_pod=${_TARGET_POD_INPUT:-<primary>} min_secs_running=${_MIN_SECS}"
log_debug "ops-list" "resolved credentials: secret=${_SECRET} user_key=${_USER_KEY:-<direct>} pass_key=${_PASS_KEY}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"

_PROBE=$(_ops_probe_pod "$_STS") \
  || fail_task "NO_PRIMARY" "no Ready/Running pod found for StatefulSet ${_STS} in ${DB_NAMESPACE}"
log_debug "ops-list" "probe pod: ${_PROBE}"

_TARGET_ROW=$(_ops_resolve_target "$_STS" "$_PROBE" "$_TARGET_POD_INPUT" "$_MONGO_USER" "$_MONGO_PASS") \
  || fail_task "NO_PRIMARY" "no target_pod given and no reachable PRIMARY for StatefulSet ${_STS} in ${DB_NAMESPACE}"
IFS=$'\x1f' read -r _EXEC_POD _DIRECT_HOST <<<"$_TARGET_ROW"
log_debug "ops-list" "exec_pod=${_EXEC_POD} direct_host=${_DIRECT_HOST:-<local>}"

_OPS_JSON=$(ops_list_current "$_EXEC_POD" "$_DIRECT_HOST" "$_MONGO_USER" "$_MONGO_PASS" "$_MIN_SECS") \
  || fail_task "OPS_READ_FAILED" "could not read currentOp from ${_TARGET_POD_INPUT:-primary} (${_EXEC_POD})"

log_info "ops-list" "$(jq 'length' <<<"$_OPS_JSON") active operation(s) reported"

jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg target_pod "${_TARGET_POD_INPUT:-$_EXEC_POD}" \
  --argjson min_secs_running "$_MIN_SECS" \
  --argjson ops "$_OPS_JSON" \
  '{namespace:$namespace, target_pod:$target_pod, min_secs_running:$min_secs_running,
    count:($ops|length), ops:$ops}' \
  >"$AQSH_RESULT_FILE"
