#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/recovery/wipe.sh
# aqsh task: Run G1–G8 gates then set wipe-target and trigger a rolling
# update for the target pod so the init container clears corrupted data.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE          — target namespace, e.g. "mongo-1"
#   MONGO_STS_NAME        — StatefulSet name (default: mongodb)
#   RECOVERY_TARGET_POD   — pod to wipe, e.g. "mongodb-2"
#   RECOVERY_CONFIGMAP    — recovery ConfigMap name (default: mongodb-recovery-config)
#   MONGO_CRED_SECRET     — Secret name (default: mongodb-credentials)
#   MONGO_CRED_USER       — Username value (optional; if set, MONGO_CRED_USER_KEY is ignored)
#   MONGO_CRED_USER_KEY   — Secret key for username (default: MONGO_ROOT_USER)
#   MONGO_CRED_PASS_KEY   — Secret key for password (default: MONGO_ROOT_PASS)
#   FORCE_WIPE            — "true" to bypass 100GB gate (default: false)
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-recovery.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
# mongodb-recovery.sh (sourced above) already loads /etc/aqsh/config/mongodb.env
# before this point — see its header comment for why it must run there.
_STS="${MONGO_STS_NAME:-${MONGO_STS_NAME_DEFAULT:-mongodb}}"
_CM="${RECOVERY_CONFIGMAP:-${RECOVERY_CONFIGMAP_DEFAULT:-mongodb-recovery-config}}"
_SECRET="${MONGO_CRED_SECRET:-${MONGO_CRED_SECRET_DEFAULT:-mongodb-credentials}}"
_DIRECT_USER="${MONGO_CRED_USER:-${MONGO_CRED_USER_DEFAULT:-}}"
_USER_KEY="${MONGO_CRED_USER_KEY:-${MONGO_CRED_USER_KEY_DEFAULT:-MONGO_ROOT_USER}}"
_PASS_KEY="${MONGO_CRED_PASS_KEY:-${MONGO_CRED_PASS_KEY_DEFAULT:-MONGO_ROOT_PASS}}"
_TARGET="${RECOVERY_TARGET_POD:?RECOVERY_TARGET_POD is required (e.g. mongodb-2)}"
export FORCE_WIPE="${FORCE_WIPE:-false}"

log_info "recovery-wipe" "Starting wipe for pod ${_TARGET} in namespace ${DB_NAMESPACE}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"

# --- Phase 1: run gates (gate mode — exits on first blocking failure) ---
log_info "recovery-wipe" "Running pre-flight gates (gate mode)"
gates_result=$(recovery_run_gates "$_STS" "$_TARGET" "$_CM" "$_MONGO_USER" "$_MONGO_PASS" "gate") || {
  printf '%s\n' "$gates_result" | jq -c '.data // {"error":.message,"gates_status":"failed"}' \
    > "$AQSH_RESULT_FILE"
  exit 1
}

# --- Phase 2: apply wipe ---
log_info "recovery-wipe" "All gates passed — applying wipe for pod ${_TARGET}"
wipe_result=$(recovery_wipe_pod "$_STS" "$_TARGET" "$_CM") || {
  printf '%s\n' "$wipe_result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
  exit 1
}

log_info "recovery-wipe" "Wipe initiated for pod ${_TARGET}"
printf '%s\n' "$wipe_result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
