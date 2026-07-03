#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/reconfig/apply.sh
# aqsh task: execute a planned replica-set reconfig.
#
# Re-runs every plan gate against the live cluster, verifies the caller's
# plan_hash still matches the live configVersion/term (CAS — refuses when
# the config moved since plan), then executes ONE rs.reconfig per op so the
# MongoDB 4.4+ single-voting-change rule always holds. block findings are
# never overridable; warn findings require override_reason. Writes an audit
# entry (pre/post config snapshots) to the reconfig audit ConfigMap.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE         — target namespace
#   RECONFIG_OPS_JSON    — same ops array that was planned
#   RECONFIG_PLAN_HASH   — plan_hash returned by reconfig/plan
#   OVERRIDE_REASON      — required when the plan is warn-level
#   REQUESTED_BY / REQUEST_ID — audit fields (free text)
#
# sts_name/credential secret/user/keys are not task inputs (see CLAUDE.md
# "Configuration Layers").
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
_PLAN_HASH="${RECONFIG_PLAN_HASH:-}"
_OVERRIDE_REASON="${OVERRIDE_REASON:-}"
_REQUESTED_BY="${REQUESTED_BY:-}"
_REQUEST_ID="${REQUEST_ID:-}"

_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "")
_CRED_ROW=$(recovery_resolve_credentials \
  "${MONGO_CRED_SECRET_DEFAULT:-}" \
  "${MONGO_CRED_USER_DEFAULT:-}" \
  "${MONGO_CRED_USER_KEY_DEFAULT:-}" \
  "${MONGO_CRED_PASS_KEY_DEFAULT:-}" \
  "$_STS")
IFS=$'\x1f' read -r _SECRET _DIRECT_USER _USER_KEY _PASS_KEY <<< "$_CRED_ROW"

log_info "reconfig-apply" "STS=${_STS} namespace=${DB_NAMESPACE} plan_hash=${_PLAN_HASH}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"

result=$(reconfig_apply "$_STS" "$_OPS_JSON" "$_PLAN_HASH" "$_OVERRIDE_REASON" \
  "$_REQUESTED_BY" "$_REQUEST_ID" "$_MONGO_USER" "$_MONGO_PASS") || {
  printf '%s\n' "$result" \
    | jq -c '{error: .message} + (.data // {})' > "$AQSH_RESULT_FILE"
  exit 1
}
printf '%s\n' "$result" | jq -c '.data' > "$AQSH_RESULT_FILE"
