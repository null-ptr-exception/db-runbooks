#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/recovery/recover.sh
# aqsh task: ONE-CALL orchestrated recovery for a corrupted pod.
#
# Runs the full workflow automatically:
#   pre-flight gates (G1–G8)  →  wipe  →  wait for pod restart+Running  →  reset
#
# This closes the dangerous manual race where wipe-targets must be cleared the
# instant the pod is Running but before initial sync completes.  Initial sync
# itself is NOT awaited; monitor it afterwards with recovery/status.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE          — target namespace, e.g. "mongo-1"
#   MONGO_STS_NAME        — StatefulSet name (default: mongodb)
#   RECOVERY_TARGET_POD   — pod to recover, e.g. "mongodb-2"
#   RECOVERY_CONFIGMAP    — recovery ConfigMap name (default: mongodb-recovery-config)
#   MONGO_CRED_SECRET     — Secret name (default: mongodb-credentials)
#   MONGO_CRED_USER       — Username value (optional; if set, MONGO_CRED_USER_KEY is ignored)
#   MONGO_CRED_USER_KEY   — Secret key for username (default: MONGO_ROOT_USER)
#   MONGO_CRED_PASS_KEY   — Secret key for password (default: MONGO_ROOT_PASS)
#   FORCE_WIPE            — "true" to bypass 100GB gate (default: false)
#   RECOVERY_WAIT_TIMEOUT — seconds to wait for pod restart+Running (default 300)
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
_TIMEOUT="${RECOVERY_WAIT_TIMEOUT:-300}"
export FORCE_WIPE="${FORCE_WIPE:-false}"

log_info "recovery-recover" "Orchestrated recovery for pod ${_TARGET} in namespace ${DB_NAMESPACE}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"

# Determine replica count for partition restore
_REPLICAS=$(kubectl -n "${DB_NAMESPACE}" get statefulset "${_STS}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null) || _REPLICAS=3
[[ -z "$_REPLICAS" || ! "$_REPLICAS" =~ ^[0-9]+$ ]] && _REPLICAS=3

result=$(recovery_recover "$_STS" "$_TARGET" "$_CM" "$_MONGO_USER" "$_MONGO_PASS" "$_REPLICAS" "$_TIMEOUT") || {
  printf '%s\n' "$result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
  exit 1
}

printf '%s\n' "$result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
