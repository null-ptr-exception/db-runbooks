#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/recovery/pre-check.sh
# aqsh task: Run G1–G8 pre-flight gates and report results without making
# any changes.  Use this to verify conditions before running recovery/wipe.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE          — target namespace, e.g. "mongo-1"
#   MONGO_STS_NAME        — StatefulSet name (default: mongodb)
#   RECOVERY_TARGET_POD   — pod to check gates for, e.g. "mongodb-2"
#   RECOVERY_CONFIGMAP    — recovery ConfigMap name (default: mongodb-recovery-config)
#   MONGO_CRED_SECRET     — Secret name (default: mongodb-credentials)
#   MONGO_CRED_USER       — Username value (optional; if set, MONGO_CRED_USER_KEY is ignored)
#   MONGO_CRED_USER_KEY   — Secret key for username (default: MONGO_ROOT_USER)
#   MONGO_CRED_PASS_KEY   — Secret key for password (default: MONGO_ROOT_PASS)
#   FORCE_WIPE            — set "true" to bypass 100GB G5 gate (default: false)
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-recovery.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
_STS="${MONGO_STS_NAME:-mongodb}"
_CM="${RECOVERY_CONFIGMAP:-mongodb-recovery-config}"
_SECRET="${MONGO_CRED_SECRET:-mongodb-credentials}"
_DIRECT_USER="${MONGO_CRED_USER:-}"
_USER_KEY="${MONGO_CRED_USER_KEY:-MONGO_ROOT_USER}"
_PASS_KEY="${MONGO_CRED_PASS_KEY:-MONGO_ROOT_PASS}"
_TARGET="${RECOVERY_TARGET_POD:?RECOVERY_TARGET_POD is required (e.g. mongodb-2)}"
export FORCE_WIPE="${FORCE_WIPE:-false}"

log_info "recovery-pre-check" "Running pre-flight gates for pod ${_TARGET} in namespace ${DB_NAMESPACE}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"

# Run all gates in report mode (never exits early — collects all results)
result=$(recovery_run_gates "$_STS" "$_TARGET" "$_CM" "$_MONGO_USER" "$_MONGO_PASS" "report") || true

log_info "recovery-pre-check" "Gates completed for pod ${_TARGET}"

# Write the data payload as the task result
printf '%s\n' "$result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
