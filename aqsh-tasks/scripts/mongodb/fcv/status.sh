#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/fcv/status.sh
# aqsh task: read-only featureCompatibilityVersion report — server binary
# version, current FCV, transitional state, and the FCV targets the running
# binary would accept. Executes nothing. See docs/mongodb/fcv.md.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE — target namespace, e.g. "mongo-1"
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
source "${LIB_DIR}/mongodb-fcv.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"

_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "")
_CRED_ROW=$(recovery_resolve_credentials \
  "${MONGO_CRED_SECRET_DEFAULT:-}" \
  "${MONGO_CRED_USER_DEFAULT:-}" \
  "${MONGO_CRED_USER_KEY_DEFAULT:-}" \
  "${MONGO_CRED_PASS_KEY_DEFAULT:-}" \
  "$_STS")
IFS=$'\x1f' read -r _SECRET _DIRECT_USER _USER_KEY _PASS_KEY <<< "$_CRED_ROW"

log_info "fcv-status" "STS=${_STS} namespace=${DB_NAMESPACE}"
log_debug "fcv-status" "resolved credentials: secret=${_SECRET} user_key=${_USER_KEY:-<direct>} pass_key=${_PASS_KEY}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"

_PROBE=$(_fcv_probe_pod "$_STS") \
  || fail_task "NO_PRIMARY" "no Ready/Running pod found for StatefulSet ${_STS} in ${DB_NAMESPACE}"
log_debug "fcv-status" "probe pod: ${_PROBE}"

_PRIMARY=$(_recovery_primary_host "$_STS" "$_MONGO_USER" "$_MONGO_PASS") \
  || fail_task "NO_PRIMARY" "replica set for StatefulSet ${_STS} has no reachable PRIMARY"
log_debug "fcv-status" "primary: ${_PRIMARY}"

_INFO=$(fcv_read_info "$_PROBE" "$_PRIMARY" "$_MONGO_USER" "$_MONGO_PASS") \
  || fail_task "FCV_READ_FAILED" "could not read version/FCV from primary ${_PRIMARY}"

_SERVER_VERSION=$(jq -r '.version' <<< "$_INFO")
_FCV=$(jq -r '.fcv' <<< "$_INFO")
_TARGET_FCV=$(jq -r '.targetFcv // empty' <<< "$_INFO")

# Read-only task: an unknown binary series is reported as a warning with an
# empty allowed_targets set, never a failure — fcv/set is where it fails hard.
_SERIES=$(fcv_binary_series "$_SERVER_VERSION") || _SERIES=""
_ALLOWED_JSON='[]'
_WARNING=""
if [[ -n "$_SERIES" ]] && _ALLOWED=$(fcv_allowed_targets "$_SERIES"); then
  _ALLOWED_JSON=$(printf '%s' "$_ALLOWED" | jq -Rc 'split(" ")')
  log_debug "fcv-status" "series=${_SERIES} allowed FCV targets: ${_ALLOWED}"
else
  _WARNING="UNSUPPORTED_SERVER_VERSION"
  log_debug "fcv-status" "no FCV mapping for server version ${_SERVER_VERSION} (series '${_SERIES}')"
fi

log_info "fcv-status" "server=${_SERVER_VERSION} fcv=${_FCV} transitional=$([[ -n "$_TARGET_FCV" ]] && echo true || echo false)"

jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg sts "$_STS" \
  --arg primary "$_PRIMARY" \
  --arg server_version "$_SERVER_VERSION" \
  --arg server_series "$_SERIES" \
  --arg fcv "$_FCV" \
  --arg target_fcv "$_TARGET_FCV" \
  --arg warning "$_WARNING" \
  --argjson allowed_targets "$_ALLOWED_JSON" \
  '{namespace:$namespace, sts:$sts, primary:$primary,
    server_version:$server_version, server_series:$server_series,
    fcv:$fcv,
    transitional:($target_fcv != ""),
    target_fcv:(if $target_fcv == "" then null else $target_fcv end),
    allowed_targets:$allowed_targets}
   + (if $warning == "" then {} else {warning:$warning} end)' \
  > "$AQSH_RESULT_FILE"
