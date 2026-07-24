#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/pods/list.sh
# aqsh task: read-only listing of the live Kubernetes Pods belonging to this
# namespace's MariaDB instance (see docs/mariadb/pods.md). Pure k8s-API —
# never connects to mariadbd. Membership is exact: replica count from the
# MariaDB CR (or, for operator-less deployments, the same-named StatefulSet)
# generates the ordinal pod names — never a label-selector guess that could
# over-match auxiliary pods sharing the instance label
# (mariadb_list_member_pods, lib/mariadb.sh).
#
# The NAMESPACE is the only required input; the instance itself is
# auto-detected — never a task input (see CLAUDE.md "Configuration Layers").
# =============================================================================

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi

# Capture an optional platform override before mariadb.sh defaults MARIADB_NAME.
# It is not a task input; empty means auto-detect the namespace's instance.
MDB_INPUT="${MARIADB_NAME:-}"

# shellcheck source=../../lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"  # logging, response, k8s + generic helpers
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"
# shellcheck source=../../lib/pods.sh
source "${LIB_DIR}/pods.sh"

mdbt_load_config

OP="pods-list"

NAMESPACE="${DB_NAMESPACE:-}"          # the database identity — the only required input
mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"

mariadb_set_target "${K8S_CONTEXT:-}" "$NAMESPACE" "$MARIADB_RESOURCE" "$MDB_INPUT"

# Resolve which instance to list: platform override, else the namespace's
# single instance (CR or, for operator-less deployments, StatefulSet). Never
# guess across several — candidates are logged, not exposed publicly.
_on_ambiguous() {
  log_debug "$OP" "ambiguous instance candidates: ${1:-}"
  mdbt_fail "$OP" "database configuration is ambiguous" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2 "DATABASE_CONFIGURATION_AMBIGUOUS"
}
_on_none() {
  mdbt_fail "$OP" "database not found" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2 "DATABASE_NOT_FOUND"
}
if [[ -z "$MDB_INPUT" ]]; then
  mariadb_autodetect_target true _on_ambiguous _on_none   # sets MARIADB_NAME or exits
fi
log_debug "$OP" "resolved instance=${MARIADB_NAME} namespace=${NAMESPACE}"

MEMBER_PODS=""
if ! MEMBER_PODS="$(mariadb_list_member_pods)"; then
  mdbt_fail "$OP" "cannot resolve exact member pods for this instance" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1 "POD_TARGETS_UNRESOLVED"
fi
log_debug "$OP" "member pods: $(printf '%s' "$MEMBER_PODS" | tr '\n' ',')"

PODS_JSON="$(pods_status_json "$MEMBER_PODS")" \
  || mdbt_fail "$OP" "could not read pod status" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1 "PODS_LIST_FAILED"
COUNT="$(jq 'length' <<<"$PODS_JSON")"

log_info "$OP" "instance=${MARIADB_NAME} namespace=${NAMESPACE} ${COUNT} pod(s) reported"

mdbt_write_result "$(response_ok "$OP" "found ${COUNT} pod(s) for ${NAMESPACE}" "$(jq -n \
  --arg namespace "$NAMESPACE" \
  --arg instance "$MARIADB_NAME" \
  --argjson count "$COUNT" \
  --argjson pods "$PODS_JSON" \
  '{namespace:$namespace, instance:$instance, count:$count, pods:$pods}')")"
