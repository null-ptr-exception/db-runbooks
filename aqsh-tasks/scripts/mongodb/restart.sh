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

if [[ -n "${MONGO_STS_NAME:-}" ]]; then
  log_debug "mongo-restart" "sts_name from task input: ${MONGO_STS_NAME}"
elif [[ -n "${MONGO_STS_NAME_DEFAULT:-}" ]]; then
  log_debug "mongo-restart" "sts_name from internal config (MONGO_STS_NAME_DEFAULT): ${MONGO_STS_NAME_DEFAULT}"
else
  log_debug "mongo-restart" "sts_name: using hardcoded literal 'mongodb'"
fi
STS_NAME="${MONGO_STS_NAME:-${MONGO_STS_NAME_DEFAULT:-mongodb}}"
export K8S_NAMESPACE="${DB_NAMESPACE}"

log_info "mongo-restart" "Restarting StatefulSet '${STS_NAME}' in namespace '${DB_NAMESPACE}'"

result=$(k8s_sts_restart "$STS_NAME")
strategy=$(echo "$result" | grep -o '"strategy":"[^"]*"' | cut -d'"' -f4)
ready=$(echo "$result"    | grep -o '"ready":[0-9]*'    | grep -o '[0-9]*$')
replicas=$(echo "$result" | grep -o '"replicas":[0-9]*' | grep -o '[0-9]*$')

log_info "mongo-restart" "Done: ${ready:-0}/${replicas:-0} ready"

jq -n \
  --arg  namespace   "$DB_NAMESPACE" \
  --arg  statefulset "$STS_NAME" \
  --arg  strategy    "${strategy:-RollingUpdate}" \
  --argjson ready    "${ready:-0}" \
  --argjson replicas "${replicas:-0}" \
  '{namespace: $namespace, statefulset: $statefulset, strategy: $strategy, ready: $ready, replicas: $replicas}' \
  > "$AQSH_RESULT_FILE"
