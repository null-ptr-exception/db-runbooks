#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/recovery/wipe.sh
# aqsh task: Run G1–G8 gates then set wipe-target and trigger a rolling
# update for the target pod so the init container clears corrupted data.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE          — target namespace, e.g. "mongo-1"
#   RECOVERY_TARGET_POD   — pod to wipe, e.g. "mongodb-2"
#   FORCE_WIPE            — "true" to bypass 100GB gate (default: false)
#
# sts_name/recovery_configmap/credential secret-and-keys/data-and-mount-path
# are not task inputs (see CLAUDE.md "Configuration Layers") — they resolve
# internal config (/etc/aqsh/config/mongodb.env) -> live cluster auto-detect
# -> hardcoded literal fallback.
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-recovery.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
_TARGET="${RECOVERY_TARGET_POD:?RECOVERY_TARGET_POD is required (e.g. mongodb-2)}"
export FORCE_WIPE="${FORCE_WIPE:-false}"

# mongodb-recovery.sh (sourced above) already loads /etc/aqsh/config/mongodb.env
# before this point — see its header comment for why it must run there.
_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "$_TARGET")
_CM=$(recovery_resolve_configmap "${RECOVERY_CONFIGMAP_DEFAULT:-}" "$_STS")
_CRED_ROW=$(recovery_resolve_credentials \
  "${MONGO_CRED_SECRET_DEFAULT:-}" \
  "${MONGO_CRED_USER_DEFAULT:-}" \
  "${MONGO_CRED_USER_KEY_DEFAULT:-}" \
  "${MONGO_CRED_PASS_KEY_DEFAULT:-}" \
  "$_STS")
IFS=$'\x1f' read -r _SECRET _DIRECT_USER _USER_KEY _PASS_KEY <<< "$_CRED_ROW"

log_info "recovery-wipe" "Starting wipe for pod ${_TARGET} in namespace ${DB_NAMESPACE}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"
recovery_resolve_data_paths "$_TARGET" "$_MONGO_USER" "$_MONGO_PASS"

# --- Phase 1: run gates (gate mode — exits on first blocking failure) ---
# G1 self-heals a missing init container here (see CLAUDE.md "Auto-detect
# tier"); _AUTO_PATCHED carries that into the final output below so a
# caller doesn't need to separately inspect the StatefulSet to know.
log_info "recovery-wipe" "Running pre-flight gates (gate mode)"
gates_result=$(recovery_run_gates "$_STS" "$_TARGET" "$_CM" "$_MONGO_USER" "$_MONGO_PASS" "gate") || {
  printf '%s\n' "$gates_result" | jq -c '.data // {"error":.message,"gates_status":"failed"}' \
    > "$AQSH_RESULT_FILE"
  exit 1
}
_AUTO_PATCHED=$(printf '%s' "$gates_result" | jq -r '.data.auto_patched // false')

# --- Phase 2: apply wipe ---
log_info "recovery-wipe" "All gates passed — applying wipe for pod ${_TARGET}"
wipe_result=$(recovery_wipe_pod "$_STS" "$_TARGET" "$_CM") || {
  printf '%s\n' "$wipe_result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
  exit 1
}

log_info "recovery-wipe" "Wipe initiated for pod ${_TARGET}"
printf '%s\n' "$wipe_result" | jq -c --argjson auto_patched "$_AUTO_PATCHED" \
  '(.data // {"error":.message}) + {"auto_patched": $auto_patched}' > "$AQSH_RESULT_FILE"
