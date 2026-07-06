#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/fcv/set.sh
# aqsh task: set featureCompatibilityVersion on the replica-set PRIMARY,
# gated dry_run -> confirm. The target is validated against the running
# binary's compatibility table (a binary of series X.Y only accepts FCV in
# {previous-series, X.Y}) — an out-of-range target fails with INVALID_TARGET,
# never a silent no-op. See docs/mongodb/fcv.md.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE        — target namespace, e.g. "mongo-1"
#   FCV_TARGET_VERSION  — requested FCV, e.g. "6.0"
#   DRY_RUN             — default "true": validate + preview, change nothing
#   CONFIRM             — must be "true" when DRY_RUN is "false"
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
_TARGET="${FCV_TARGET_VERSION:?FCV_TARGET_VERSION is required}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"

# ── Gate (same triad as account tasks) ───────────────────────────────────────
if bool_enabled "$DRY_RUN" && bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true with dry_run=true is not supported"
fi
if ! bool_enabled "$DRY_RUN" && ! bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true is required when dry_run=false"
fi
# Belt-and-braces after the tasks.yaml pattern check.
if [[ ! "$_TARGET" =~ ^[0-9]+\.[0-9]+$ ]]; then
  fail_task "INVALID_INPUT" "target_version must look like X.Y (got '${_TARGET}')"
fi

# ── Resolve deployment naming + credentials (3-tier, no task-input tier) ─────
_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "")
_CRED_ROW=$(recovery_resolve_credentials \
  "${MONGO_CRED_SECRET_DEFAULT:-}" \
  "${MONGO_CRED_USER_DEFAULT:-}" \
  "${MONGO_CRED_USER_KEY_DEFAULT:-}" \
  "${MONGO_CRED_PASS_KEY_DEFAULT:-}" \
  "$_STS")
IFS=$'\x1f' read -r _SECRET _DIRECT_USER _USER_KEY _PASS_KEY <<< "$_CRED_ROW"

log_info "fcv-set" "STS=${_STS} namespace=${DB_NAMESPACE} target=${_TARGET} dry_run=${DRY_RUN}"
log_debug "fcv-set" "resolved credentials: secret=${_SECRET} user_key=${_USER_KEY:-<direct>} pass_key=${_PASS_KEY}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"

_PROBE=$(_fcv_probe_pod "$_STS") \
  || fail_task "NO_PRIMARY" "no Ready/Running pod found for StatefulSet ${_STS} in ${DB_NAMESPACE}"
log_debug "fcv-set" "probe pod: ${_PROBE}"

_PRIMARY=$(_recovery_primary_host "$_STS" "$_MONGO_USER" "$_MONGO_PASS") \
  || fail_task "NO_PRIMARY" "replica set for StatefulSet ${_STS} has no reachable PRIMARY"
log_debug "fcv-set" "primary: ${_PRIMARY}"

# ── Read live version + FCV ──────────────────────────────────────────────────
_INFO=$(fcv_read_info "$_PROBE" "$_PRIMARY" "$_MONGO_USER" "$_MONGO_PASS") \
  || fail_task "FCV_READ_FAILED" "could not read version/FCV from primary ${_PRIMARY}"

_SERVER_VERSION=$(jq -r '.version' <<< "$_INFO")
_FCV=$(jq -r '.fcv' <<< "$_INFO")
_PENDING_FCV=$(jq -r '.targetFcv // empty' <<< "$_INFO")

_SERIES=$(fcv_binary_series "$_SERVER_VERSION") \
  || fail_task "UNSUPPORTED_SERVER_VERSION" "cannot parse server version '${_SERVER_VERSION}'"
_ALLOWED=$(fcv_allowed_targets "$_SERIES") \
  || fail_task "UNSUPPORTED_SERVER_VERSION" \
    "no known FCV compatibility mapping for MongoDB ${_SERVER_VERSION} (series ${_SERIES})"
log_debug "fcv-set" "server=${_SERVER_VERSION} series=${_SERIES} fcv=${_FCV} pending=${_PENDING_FCV:-<none>} allowed targets: ${_ALLOWED}"

# ── Validate target ──────────────────────────────────────────────────────────
_ALLOWED_OK="false"
for _v in $_ALLOWED; do
  [[ "$_v" == "$_TARGET" ]] && _ALLOWED_OK="true"
done
if [[ "$_ALLOWED_OK" != "true" ]]; then
  fail_task "INVALID_TARGET" \
    "target FCV ${_TARGET} is not allowed for MongoDB ${_SERVER_VERSION}; allowed: ${_ALLOWED}" \
    "$(jq -nc --arg server_version "$_SERVER_VERSION" --arg current_fcv "$_FCV" \
      --arg allowed "$_ALLOWED" \
      '{server_version:$server_version, current_fcv:$current_fcv, allowed_targets:($allowed|split(" "))}')"
fi

# Transitional state: a prior setFCV was interrupted mid-flight. MongoDB's
# documented remediation is to re-run setFCV with either the pending target
# (finish the transition) or the stable version (roll it back) — any other
# target is refused.
if [[ -n "$_PENDING_FCV" && "$_TARGET" != "$_PENDING_FCV" && "$_TARGET" != "$_FCV" ]]; then
  fail_task "TRANSITIONAL_STATE" \
    "FCV is mid-transition (stable ${_FCV} -> pending ${_PENDING_FCV}); target must be ${_PENDING_FCV} to finish or ${_FCV} to roll back" \
    "$(jq -nc --arg stable "$_FCV" --arg pending "$_PENDING_FCV" \
      '{stable_fcv:$stable, pending_fcv:$pending}')"
fi

_DIRECTION=$(fcv_direction "$_FCV" "$_TARGET")
_WAS_TRANSITIONAL="false"
[[ -n "$_PENDING_FCV" ]] && _WAS_TRANSITIONAL="true"

# Already there (and not stuck mid-transition): completed no-op, not an error.
if [[ -z "$_PENDING_FCV" && "$_TARGET" == "$_FCV" ]]; then
  log_info "fcv-set" "FCV already at ${_TARGET}; nothing to do"
  write_task_result "$(jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg server_version "$_SERVER_VERSION" \
    --arg fcv "$_FCV" \
    --arg target_version "$_TARGET" \
    '{status:"ok", reason_code:"ALREADY_AT_TARGET",
      summary:("FCV is already " + $target_version + "; no change applied"),
      namespace:$namespace, server_version:$server_version,
      previous_fcv:$fcv, current_fcv:$fcv, target_version:$target_version,
      direction:"none", changed:false, was_transitional:false}')"
  exit 0
fi

# ── Dry-run preview ──────────────────────────────────────────────────────────
if bool_enabled "$DRY_RUN"; then
  log_info "fcv-set" "dry-run: would set FCV ${_FCV} -> ${_TARGET} (${_DIRECTION}) on ${_PRIMARY}"
  write_task_result "$(jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg server_version "$_SERVER_VERSION" \
    --arg fcv "$_FCV" \
    --arg target_version "$_TARGET" \
    --arg direction "$_DIRECTION" \
    --argjson was_transitional "$_WAS_TRANSITIONAL" \
    '{status:"DRY_RUN_READY", reason_code:"DRY_RUN_READY",
      summary:("Dry-run only. Would set FCV " + $fcv + " -> " + $target_version + " (" + $direction + ")."),
      namespace:$namespace, server_version:$server_version,
      previous_fcv:$fcv, current_fcv:$fcv, target_version:$target_version,
      direction:$direction, changed:false, would_change:true,
      was_transitional:$was_transitional}')"
  exit 0
fi

# ── Execute ──────────────────────────────────────────────────────────────────
_SERVER_MAJOR="${_SERIES%%.*}"
_SET_OUT=$(fcv_execute_set "$_PROBE" "$_PRIMARY" "$_MONGO_USER" "$_MONGO_PASS" \
  "$_TARGET" "$_SERVER_MAJOR") \
  || fail_task "SET_FCV_FAILED" \
    "setFeatureCompatibilityVersion(${_TARGET}) failed on primary ${_PRIMARY}" \
    "$(jq -nc --arg server_response "${_SET_OUT:-}" '{server_response:$server_response}')"

# Re-read and require convergence: "command returned ok" is not the same as
# "the FCV document finished flipping" — surface a still-transitional state
# instead of reporting success.
_INFO_AFTER=$(fcv_read_info "$_PROBE" "$_PRIMARY" "$_MONGO_USER" "$_MONGO_PASS") \
  || fail_task "SET_FCV_FAILED" \
    "setFCV command succeeded but re-reading FCV from ${_PRIMARY} failed — verify state with fcv/status"

_FCV_AFTER=$(jq -r '.fcv' <<< "$_INFO_AFTER")
_PENDING_AFTER=$(jq -r '.targetFcv // empty' <<< "$_INFO_AFTER")
if [[ -n "$_PENDING_AFTER" || "$_FCV_AFTER" != "$_TARGET" ]]; then
  fail_task "SET_FCV_FAILED" \
    "setFCV command returned ok but FCV did not finalize at ${_TARGET}" \
    "$(jq -nc --arg observed_fcv "$_FCV_AFTER" --arg observed_pending "$_PENDING_AFTER" \
      '{observed_fcv:$observed_fcv, observed_pending_fcv:(if $observed_pending == "" then null else $observed_pending end)}')"
fi

log_info "fcv-set" "FCV ${_FCV} -> ${_FCV_AFTER} (${_DIRECTION}) completed on ${_PRIMARY}"
write_task_result "$(jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg server_version "$_SERVER_VERSION" \
  --arg previous_fcv "$_FCV" \
  --arg current_fcv "$_FCV_AFTER" \
  --arg target_version "$_TARGET" \
  --arg direction "$_DIRECTION" \
  --argjson was_transitional "$_WAS_TRANSITIONAL" \
  '{status:"ok", reason_code:"FCV_SET",
    summary:("FCV changed " + $previous_fcv + " -> " + $current_fcv + " (" + $direction + ")."),
    namespace:$namespace, server_version:$server_version,
    previous_fcv:$previous_fcv, current_fcv:$current_fcv,
    target_version:$target_version, direction:$direction,
    changed:true, was_transitional:$was_transitional}')"
