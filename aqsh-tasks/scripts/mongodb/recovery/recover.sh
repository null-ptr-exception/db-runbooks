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
#   RECOVERY_TARGET_POD   — pod to recover, e.g. "mongodb-2"
#   FORCE_WIPE            — "true" to bypass 100GB gate (default: false)
#   RECOVERY_WAIT_TIMEOUT — seconds to wait for pod restart+Running (default 300)
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
_TIMEOUT="${RECOVERY_WAIT_TIMEOUT:-300}"
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

log_info "recovery-recover" "Orchestrated recovery for pod ${_TARGET} in namespace ${DB_NAMESPACE}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"
recovery_resolve_data_paths "$_TARGET" "$_MONGO_USER" "$_MONGO_PASS"

# Determine replica count for partition restore
_REPLICAS=$(kubectl -n "${DB_NAMESPACE}" get statefulset "${_STS}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null) || _REPLICAS=3
[[ -z "$_REPLICAS" || ! "$_REPLICAS" =~ ^[0-9]+$ ]] && _REPLICAS=3

result=$(recovery_recover "$_STS" "$_TARGET" "$_CM" "$_MONGO_USER" "$_MONGO_PASS" "$_REPLICAS" "$_TIMEOUT") || {
  printf '%s\n' "$result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
  exit 1
}

printf '%s\n' "$result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
