#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/recovery/reset.sh
# aqsh task: Clear the wipe-target ConfigMap entry and restore the StatefulSet
# partition to the replica count (locked state — no auto-restart).
#
# Run this as soon as the target pod enters Running state after a wipe to
# prevent the init container from wiping data again on any future pod restart.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE       — target namespace, e.g. "mongo-1"
#
# sts_name/recovery_configmap are not task inputs (see CLAUDE.md
# "Configuration Layers") — they resolve internal config (/etc/aqsh/config/
# mongodb.env) -> live cluster auto-detect (single StatefulSet in the
# namespace) -> hardcoded literal fallback.
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb-recovery.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
# mongodb-recovery.sh (sourced above) already loads /etc/aqsh/config/mongodb.env
# before this point — see its header comment for why it must run there.
_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}")
_CM=$(recovery_resolve_configmap "${RECOVERY_CONFIGMAP_DEFAULT:-}" "$_STS")

log_info "recovery-reset" "Resetting recovery state for STS ${_STS} in namespace ${DB_NAMESPACE}"

# Determine replica count to restore partition to locked state
_REPLICAS=$(kubectl -n "${DB_NAMESPACE}" get statefulset "${_STS}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null) || _REPLICAS=3
[[ -z "$_REPLICAS" || ! "$_REPLICAS" =~ ^[0-9]+$ ]] && _REPLICAS=3

log_info "recovery-reset" "Replica count: ${_REPLICAS} — partition will be set to ${_REPLICAS} (locked)"

result=$(recovery_reset "$_STS" "$_CM" "$_REPLICAS") || {
  printf '%s\n' "$result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
  exit 1
}

printf '%s\n' "$result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
