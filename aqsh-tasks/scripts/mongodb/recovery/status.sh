#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/recovery/status.sh
# aqsh task: Show current recovery state — ConfigMap wipe-targets, StatefulSet
# partition, and pod phases.  Safe read-only operation.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE       — target namespace, e.g. "mongo-1"
#   MONGO_STS_NAME     — StatefulSet name (default: mongodb)
#   RECOVERY_CONFIGMAP — recovery ConfigMap name (default: mongodb-recovery-config)
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb-recovery.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
_STS="${MONGO_STS_NAME:-mongodb}"
_CM="${RECOVERY_CONFIGMAP:-mongodb-recovery-config}"

log_info "recovery-status" "Querying recovery status for STS ${_STS} in namespace ${DB_NAMESPACE}"

result=$(recovery_get_status "$_STS" "$_CM") || true
printf '%s\n' "$result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
