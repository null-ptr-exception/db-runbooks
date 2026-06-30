#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/restart.sh
# aqsh task: rolling restart of a MongoDB StatefulSet.
#
# Inputs (injected by aqsh from tasks.yaml):
#   DB_NAMESPACE      — target namespace, e.g. "mongo-1"
#   MONGO_STS_NAME    — StatefulSet name (default: mongodb)
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"

[[ -f /etc/aqsh/config/mongodb.env ]] && source /etc/aqsh/config/mongodb.env
STS_NAME="${MONGO_STS_NAME:-${MONGO_STS_NAME_DEFAULT:-mongodb}}"
export K8S_NAMESPACE="${DB_NAMESPACE}"

log_info "mongo-restart" "Restarting StatefulSet '${STS_NAME}' in namespace '${DB_NAMESPACE}'"

result=$(k8s_sts_restart "$STS_NAME")
ready=$(echo "$result"    | grep -o '"ready":[0-9]*'    | grep -o '[0-9]*$')
replicas=$(echo "$result" | grep -o '"replicas":[0-9]*' | grep -o '[0-9]*$')

log_info "mongo-restart" "Done: ${ready:-0}/${replicas:-0} ready"

jq -n \
  --arg  namespace   "$DB_NAMESPACE" \
  --arg  statefulset "$STS_NAME" \
  --argjson replicas "${replicas:-0}" \
  '{namespace: $namespace, statefulset: $statefulset, replicas: $replicas}' \
  > "$AQSH_RESULT_FILE"
