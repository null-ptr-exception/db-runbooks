#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/oplog/status.sh
# aqsh task: read-only oplog size/window report across every current replica
# set member — oplog size and window are per-node state (replSetResizeOplog
# only resizes the node you run it against), so a single primary-only read
# would hide members with a different history. Executes nothing. See
# docs/mongodb/oplog.md.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE — target namespace, e.g. "mongo-1"
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
source "${LIB_DIR}/mongodb-oplog.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
log_set_level "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT:-INFO}}"

_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "")
_CRED_ROW=$(recovery_resolve_credentials \
  "${MONGO_CRED_SECRET_DEFAULT:-}" \
  "${MONGO_CRED_USER_DEFAULT:-}" \
  "${MONGO_CRED_USER_KEY_DEFAULT:-}" \
  "${MONGO_CRED_PASS_KEY_DEFAULT:-}" \
  "$_STS")
IFS=$'\x1f' read -r _SECRET _DIRECT_USER _USER_KEY _PASS_KEY <<<"$_CRED_ROW"

log_info "oplog-status" "STS=${_STS} namespace=${DB_NAMESPACE}"
log_debug "oplog-status" "resolved credentials: secret=${_SECRET} user_key=${_USER_KEY:-<direct>} pass_key=${_PASS_KEY}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"

_PROBE=$(_oplog_probe_pod "$_STS") \
  || fail_task "NO_PRIMARY" "no Ready/Running pod found for StatefulSet ${_STS} in ${DB_NAMESPACE}"
log_debug "oplog-status" "probe pod: ${_PROBE}"

_HOSTS=$(_oplog_member_hosts "$_PROBE" "$_MONGO_USER" "$_MONGO_PASS") \
  || fail_task "NO_PRIMARY" "could not read replica set member list from ${_PROBE}"
log_debug "oplog-status" "members: ${_HOSTS}"

_MEMBERS_JSON="[]"
for _host in $_HOSTS; do
  if _INFO=$(_oplog_member_info "$_PROBE" "$_host" "$_MONGO_USER" "$_MONGO_PASS"); then
    _MEMBERS_JSON=$(jq -c --argjson m "$_INFO" '. + [$m]' <<<"$_MEMBERS_JSON")
  else
    log_debug "oplog-status" "member ${_host} did not answer, skipping"
  fi
done

[[ "$_MEMBERS_JSON" == "[]" ]] && fail_task "NO_PRIMARY" "no replica set member answered an oplog status query"

_MIN_WINDOW=$(jq -r '[.[].window_hours] | min' <<<"$_MEMBERS_JSON")
log_info "oplog-status" "reported $(jq 'length' <<<"$_MEMBERS_JSON") member(s), min_window_hours=${_MIN_WINDOW}"

jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg sts "$_STS" \
  --argjson members "$_MEMBERS_JSON" \
  --argjson min_window_hours "$_MIN_WINDOW" \
  '{namespace:$namespace, sts:$sts, members:$members, min_window_hours:$min_window_hours}' \
  >"$AQSH_RESULT_FILE"
