#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/reconfig/freeze.sh
# aqsh task: toggle the change-freeze annotation on the MongoDB StatefulSet.
#
# While frozen, reconfig/plan reports change_window=block and reconfig/apply
# refuses (block findings can never be overridden). force-dr deliberately
# ignores the freeze — a DR does not wait for a change window.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE   — target namespace
#   FREEZE_ENABLED — "true" | "false"
#   FREEZE_REASON  — free text, recorded in the annotation and audit log
#
# sts_name is not a task input (see CLAUDE.md "Configuration Layers").
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-recovery.sh"
source "${LIB_DIR}/mongodb-reconfig.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
_ENABLED="${FREEZE_ENABLED:?FREEZE_ENABLED is required (true|false)}"
_REASON="${FREEZE_REASON:-}"

if [[ "$_ENABLED" != "true" && "$_ENABLED" != "false" ]]; then
  jq -n --arg v "$_ENABLED" '{"error":"FREEZE_ENABLED must be true or false","value":$v}' \
    > "$AQSH_RESULT_FILE"
  exit 1
fi
if [[ "$_ENABLED" == "true" && -z "$_REASON" ]]; then
  jq -n '{"error":"FREEZE_REASON is required when enabling a freeze"}' > "$AQSH_RESULT_FILE"
  exit 1
fi

_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "")

log_info "reconfig-freeze" "STS=${_STS} namespace=${DB_NAMESPACE} enabled=${_ENABLED}"

result=$(reconfig_freeze "$_STS" "$_ENABLED" "$_REASON") || {
  printf '%s\n' "$result" \
    | jq -c '{error: .message} + (.data // {})' > "$AQSH_RESULT_FILE"
  exit 1
}
printf '%s\n' "$result" | jq -c '.data' > "$AQSH_RESULT_FILE"
