#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/recovery/pre-check.sh
# aqsh task: Run G1–G8 pre-flight gates and report results without making
# any changes.  Use this to verify conditions before running recovery/wipe.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE          — target namespace, e.g. "mongo-1"
#   RECOVERY_TARGET_POD   — pod to check gates for, e.g. "mongodb-2"
#   FORCE_WIPE            — set "true" to bypass 100GB G5 gate (default: false)
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

log_info "recovery-pre-check" "Running pre-flight gates for pod ${_TARGET} in namespace ${DB_NAMESPACE}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"
recovery_resolve_data_paths "$_TARGET" "$_MONGO_USER" "$_MONGO_PASS" "$_STS"

# Run all gates in report mode (never exits early — collects all results)
result=$(recovery_run_gates "$_STS" "$_TARGET" "$_CM" "$_MONGO_USER" "$_MONGO_PASS" "report") || true

log_info "recovery-pre-check" "Gates completed for pod ${_TARGET}"

# Write the data payload as the task result
printf '%s\n' "$result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
