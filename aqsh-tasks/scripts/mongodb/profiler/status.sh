#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/profiler/status.sh
# aqsh task: read-only query profiler level/threshold report for a single
# node — the elected PRIMARY by default, or an explicit target_pod. The
# profiler level is per-node state (see docs/mongodb/profiler.md). Executes
# nothing.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE — target namespace, e.g. "mongo-1"
#   TARGET_POD   — optional; defaults to the elected PRIMARY
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

_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "$_TARGET_POD_INPUT")
_CRED_ROW=$(recovery_resolve_credentials \
  "${MONGO_CRED_SECRET_DEFAULT:-}" \
  "${MONGO_CRED_USER_DEFAULT:-}" \
  "${MONGO_CRED_USER_KEY_DEFAULT:-}" \
  "${MONGO_CRED_PASS_KEY_DEFAULT:-}" \
  "$_STS")
IFS=$'\x1f' read -r _SECRET _DIRECT_USER _USER_KEY _PASS_KEY <<<"$_CRED_ROW"

log_info "profiler-status" "STS=${_STS} namespace=${DB_NAMESPACE} target_pod=${_TARGET_POD_INPUT:-<primary>}"
log_debug "profiler-status" "resolved credentials: secret=${_SECRET} user_key=${_USER_KEY:-<direct>} pass_key=${_PASS_KEY}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"

_PROBE=$(_profiler_probe_pod "$_STS") \
  || fail_task "NO_PRIMARY" "no Ready/Running pod found for StatefulSet ${_STS} in ${DB_NAMESPACE}"
log_debug "profiler-status" "probe pod: ${_PROBE}"

_TARGET_ROW=$(_profiler_resolve_target "$_STS" "$_PROBE" "$_TARGET_POD_INPUT" "$_MONGO_USER" "$_MONGO_PASS") \
  || fail_task "NO_PRIMARY" "no target_pod given and no reachable PRIMARY for StatefulSet ${_STS} in ${DB_NAMESPACE}"
IFS=$'\x1f' read -r _EXEC_POD _DIRECT_HOST <<<"$_TARGET_ROW"
log_debug "profiler-status" "exec_pod=${_EXEC_POD} direct_host=${_DIRECT_HOST:-<local>}"

_STATUS=$(profiler_get_status "$_EXEC_POD" "$_DIRECT_HOST" "$_MONGO_USER" "$_MONGO_PASS") \
  || fail_task "PROFILER_READ_FAILED" "could not read profiling status from ${_TARGET_POD_INPUT:-primary} (${_EXEC_POD})"

log_info "profiler-status" "level=$(jq -r '.level' <<<"$_STATUS") slowms=$(jq -r '.slowms' <<<"$_STATUS") sampleRate=$(jq -r '.sampleRate' <<<"$_STATUS")"

jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg target_pod "${_TARGET_POD_INPUT:-$_EXEC_POD}" \
  --argjson profiling "$_STATUS" \
  '{namespace:$namespace, target_pod:$target_pod} + $profiling' \
  >"$AQSH_RESULT_FILE"
