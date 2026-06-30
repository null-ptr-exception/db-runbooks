#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/recovery/status.sh
# aqsh task: Show current recovery state — ConfigMap wipe-targets, StatefulSet
# partition, and pod phases.  Safe read-only operation.
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

log_info "recovery-status" "Querying recovery status for STS ${_STS} in namespace ${DB_NAMESPACE}"

result=$(recovery_get_status "$_STS" "$_CM") || true
printf '%s\n' "$result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
