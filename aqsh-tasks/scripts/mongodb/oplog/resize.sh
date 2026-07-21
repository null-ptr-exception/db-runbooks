#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/oplog/resize.sh
# aqsh task: resize the oplog across EVERY current replica-set member, gated
# dry_run -> confirm. replSetResizeOplog only resizes the node you run it
# against (MongoDB docs), so a primary-only resize would silently leave
# secondaries at their old size — this task enumerates rs.status() members
# and applies the change to each. Partial failure reports exactly which
# hosts succeeded/failed so the caller can retry precisely; MongoDB's own
# minimum-size floor is never hardcoded here — a too-small target simply
# fails per-member with the server's own error message. See
# docs/mongodb/oplog.md.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE    — target namespace, e.g. "mongo-1"
#   TARGET_SIZE_MB  — requested oplog size in MB
#   DRY_RUN         — default "true": preview per-member current vs target
#   CONFIRM         — must be "true" when DRY_RUN is "false"
#   LOG_LEVEL       — optional per-call log verbosity
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
_TARGET_MB="${TARGET_SIZE_MB:?TARGET_SIZE_MB is required}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"

# ── Gate (same triad as fcv/set) ─────────────────────────────────────────────
if bool_enabled "$DRY_RUN" && bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true with dry_run=true is not supported"
fi
if ! bool_enabled "$DRY_RUN" && ! bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true is required when dry_run=false"
fi
if [[ ! "$_TARGET_MB" =~ ^[0-9]+$ ]] || ((_TARGET_MB <= 0)); then
  fail_task "INVALID_INPUT" "target_size_mb must be a positive integer (got '${_TARGET_MB}')"
fi

# ── Resolve deployment naming + credentials (3-tier, no task-input tier) ────
_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "")
_CRED_ROW=$(recovery_resolve_credentials \
  "${MONGO_CRED_SECRET_DEFAULT:-}" \
  "${MONGO_CRED_USER_DEFAULT:-}" \
  "${MONGO_CRED_USER_KEY_DEFAULT:-}" \
  "${MONGO_CRED_PASS_KEY_DEFAULT:-}" \
  "$_STS")
IFS=$'\x1f' read -r _SECRET _DIRECT_USER _USER_KEY _PASS_KEY <<<"$_CRED_ROW"

log_info "oplog-resize" "STS=${_STS} namespace=${DB_NAMESPACE} target_mb=${_TARGET_MB} dry_run=${DRY_RUN}"
log_debug "oplog-resize" "resolved credentials: secret=${_SECRET} user_key=${_USER_KEY:-<direct>} pass_key=${_PASS_KEY}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"

_PROBE=$(_oplog_probe_pod "$_STS") \
  || fail_task "NO_PRIMARY" "no Ready/Running pod found for StatefulSet ${_STS} in ${DB_NAMESPACE}"
log_debug "oplog-resize" "probe pod: ${_PROBE}"

_HOSTS=$(_oplog_member_hosts "$_PROBE" "$_MONGO_USER" "$_MONGO_PASS") \
  || fail_task "NO_PRIMARY" "could not read replica set member list from ${_PROBE}"
log_debug "oplog-resize" "members: ${_HOSTS}"

# ── Preview (per-member current size) ────────────────────────────────────────
_PREVIEW_JSON="[]"
for _host in $_HOSTS; do
  if _INFO=$(_oplog_member_info "$_PROBE" "$_host" "$_MONGO_USER" "$_MONGO_PASS"); then
    _PREVIEW_JSON=$(jq -c --argjson m "$_INFO" '. + [$m + {reachable:true}]' <<<"$_PREVIEW_JSON")
  else
    log_debug "oplog-resize" "member ${_host} did not answer during preview"
    _PREVIEW_JSON=$(jq -c --arg host "$_host" '. + [{host:$host, reachable:false}]' <<<"$_PREVIEW_JSON")
  fi
done
[[ "$_PREVIEW_JSON" == "[]" ]] && fail_task "NO_PRIMARY" "no replica set member answered an oplog status query"

if bool_enabled "$DRY_RUN"; then
  log_info "oplog-resize" "dry-run: would resize [${_HOSTS}] to ${_TARGET_MB}MB"
  jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --argjson target_size_mb "$_TARGET_MB" \
    --argjson members "$_PREVIEW_JSON" \
    '{status:"DRY_RUN_READY", reason_code:"DRY_RUN_READY",
      summary:("Dry-run only. Would resize the oplog to " + ($target_size_mb|tostring)
        + "MB on " + ($members|length|tostring) + " member(s)."),
      namespace:$namespace, target_size_mb:$target_size_mb,
      members:$members, changed:false, would_change:true}' \
    >"$AQSH_RESULT_FILE"
  exit 0
fi

# ── Execute (per member) ─────────────────────────────────────────────────────
_RESULTS_JSON="[]"
_FAILED="false"
for _host in $_HOSTS; do
  if _OUT=$(_oplog_resize_member "$_PROBE" "$_host" "$_MONGO_USER" "$_MONGO_PASS" "$_TARGET_MB"); then
    log_info "oplog-resize" "resized ${_host} -> ${_TARGET_MB}MB"
    _RESULTS_JSON=$(jq -c --arg host "$_host" '. + [{host:$host, ok:true}]' <<<"$_RESULTS_JSON")
  else
    log_error "oplog-resize" "resize failed on ${_host}: ${_OUT}"
    _RESULTS_JSON=$(jq -c --arg host "$_host" --arg err "$_OUT" \
      '. + [{host:$host, ok:false, error:$err}]' <<<"$_RESULTS_JSON")
    _FAILED="true"
  fi
done

if [[ "$_FAILED" == "true" ]]; then
  fail_task "OPLOG_RESIZE_PARTIAL_FAILURE" \
    "resize to ${_TARGET_MB}MB failed on one or more members" \
    "$(jq -nc --argjson members "$_RESULTS_JSON" '{members:$members}')"
fi

log_info "oplog-resize" "resized all [${_HOSTS}] to ${_TARGET_MB}MB"
jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --argjson target_size_mb "$_TARGET_MB" \
  --argjson members "$_RESULTS_JSON" \
  '{status:"ok", reason_code:"OPLOG_RESIZED",
    summary:("Oplog resized to " + ($target_size_mb|tostring) + "MB on all members."),
    namespace:$namespace, target_size_mb:$target_size_mb,
    members:$members, changed:true}' \
  >"$AQSH_RESULT_FILE"
