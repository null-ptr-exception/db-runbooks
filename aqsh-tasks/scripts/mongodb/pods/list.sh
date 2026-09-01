#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/pods/list.sh
# aqsh task: read-only listing of the live Kubernetes Pods belonging to the
# StatefulSet backing this namespace's MongoDB deployment (see
# docs/mongodb/pods.md). Pure k8s-API — never connects to mongod, so it works
# even when the whole replica set is down. Membership is exact
# (ownerReferences), never a label/name guess, and works unchanged for both
# Bitnami and official-image deployments since it never inspects the image.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE — target namespace, e.g. "mongo-1"
#   LOG_LEVEL    — optional per-call log verbosity
#
# sts_name is not a task input (see AGENTS.md "Configuration Layers") — it
# resolves internal config -> live cluster auto-detect (exactly one
# StatefulSet in the namespace) -> hardcoded literal fallback, the same
# resolver ops/list.sh already uses.
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb-recovery.sh"
source "${LIB_DIR}/mongodb-account.sh"
source "${LIB_DIR}/pods.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
log_set_level "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT:-INFO}}"

_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "")
log_debug "pods-list" "resolved StatefulSet=${_STS} namespace=${DB_NAMESPACE}"

_MEMBER_NAMES=$(_k8s_sts_owned_pod_names "$_STS") \
  || fail_task "PODS_LIST_FAILED" "could not list pods for StatefulSet ${_STS} in ${DB_NAMESPACE}"
log_debug "pods-list" "member pods: $(printf '%s' "$_MEMBER_NAMES" | tr '\n' ',' )"

_PODS_JSON=$(pods_status_json "$_MEMBER_NAMES") \
  || fail_task "PODS_LIST_FAILED" "could not read pod status in ${DB_NAMESPACE}"

log_info "pods-list" "STS=${_STS} namespace=${DB_NAMESPACE} $(jq 'length' <<<"$_PODS_JSON") pod(s) reported"

jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg instance "$_STS" \
  --argjson pods "$_PODS_JSON" \
  '{namespace:$namespace, instance:$instance, count:($pods|length), pods:$pods}' \
  >"$AQSH_RESULT_FILE"
