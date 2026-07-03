#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/reconfig/plan.sh
# aqsh task: read-only risk report for a proposed replica-set reconfig.
#
# Validates intent ops against LIVE cluster facts (rs.conf/rs.status + k8s
# topology) and returns a pass/warn/block report plus the plan_hash that
# reconfig/apply requires. Executes nothing.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE       — target namespace
#   RECONFIG_OPS_JSON  — JSON array of intent ops, e.g.
#                        [{"action":"set_votes","member":"mongodb-2","votes":0}]
#
# sts_name/credential secret/user/keys are not task inputs (see CLAUDE.md
# "Configuration Layers") — they resolve internal config -> live cluster
# auto-detect -> hardcoded literal fallback.
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-recovery.sh"
source "${LIB_DIR}/mongodb-reconfig.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
_OPS_JSON="${RECONFIG_OPS_JSON:?RECONFIG_OPS_JSON is required}"

_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "")
_CRED_ROW=$(recovery_resolve_credentials \
  "${MONGO_CRED_SECRET_DEFAULT:-}" \
  "${MONGO_CRED_USER_DEFAULT:-}" \
  "${MONGO_CRED_USER_KEY_DEFAULT:-}" \
  "${MONGO_CRED_PASS_KEY_DEFAULT:-}" \
  "$_STS")
IFS=$'\x1f' read -r _SECRET _DIRECT_USER _USER_KEY _PASS_KEY <<< "$_CRED_ROW"

log_info "reconfig-plan" "STS=${_STS} namespace=${DB_NAMESPACE}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"

result=$(reconfig_plan "$_STS" "$_OPS_JSON" "$_MONGO_USER" "$_MONGO_PASS") || {
  printf '%s\n' "$result" \
    | jq -c '{error: .message} + (.data // {})' > "$AQSH_RESULT_FILE"
  exit 1
}
printf '%s\n' "$result" | jq -c '.data' > "$AQSH_RESULT_FILE"
