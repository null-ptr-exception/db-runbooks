#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/restart.sh
# aqsh task: rolling restart of a MariaDB StatefulSet.
#
# MariaDB operator uses OnDelete updateStrategy — k8s_sts_restart detects
# this automatically and waits using kubectl wait instead of rollout status.
#
# Inputs (injected by aqsh from tasks.yaml):
#   DB_NAMESPACE          — target namespace, e.g. "mariadb-1"
#   MARIADB_STS_NAME      — StatefulSet name (default: mariadb)
#   MARIADB_POD_SELECTOR  — pod label selector for OnDelete wait
#                           (default: app.kubernetes.io/name=mariadb)
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"

STS_NAME="${MARIADB_STS_NAME:-mariadb}"
POD_SELECTOR="${MARIADB_POD_SELECTOR:-app.kubernetes.io/name=${STS_NAME}}"
export K8S_NAMESPACE="${DB_NAMESPACE}"

log_info "mariadb-restart" "Restarting StatefulSet '${STS_NAME}' in namespace '${DB_NAMESPACE}'"

result=$(k8s_sts_restart "$STS_NAME" "$POD_SELECTOR")
ready=$(echo "$result"    | grep -o '"ready":[0-9]*'    | grep -o '[0-9]*$')
replicas=$(echo "$result" | grep -o '"replicas":[0-9]*' | grep -o '[0-9]*$')

log_info "mariadb-restart" "Done: ${ready:-0}/${replicas:-0} ready"

jq -n \
  --arg  namespace   "$DB_NAMESPACE" \
  --arg  statefulset "$STS_NAME" \
  --argjson replicas "${ready:-0}" \
  '{namespace: $namespace, statefulset: $statefulset, replicas: $replicas}' \
  > "$AQSH_RESULT_FILE"
