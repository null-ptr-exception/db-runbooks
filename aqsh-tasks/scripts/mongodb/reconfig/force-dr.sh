#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/reconfig/force-dr.sh
# aqsh task: break-glass forced reconfig for a site-loss DR.
#
# Independent endpoint from reconfig/apply on purpose — different inputs,
# different (stricter) preconditions, and it is the ONLY task that runs
# rs.reconfig({force:true}) on a live incident:
#   P1 no elected primary anywhere in the set
#   P2 surviving healthy votes below majority (force is genuinely needed)
#   P3 every unreachable voting member unheard-of for >= the deployment's
#      RECONFIG_DR_MIN_UNREACHABLE_SECONDS_DEFAULT (from rs.status()
#      lastHeartbeatRecv — live-derived, never cached)
#
# Two-step: dry_run=true (default) evaluates preconditions and returns the
# suggested config (lost members -> votes:0, priority:0 — never deleted) plus
# a plan_hash; confirm=true re-verifies everything and executes. incident_id
# is a mandatory audit field — verifying it against a ticketing system is the
# calling platform's job, not this task's.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE — target namespace
#   INCIDENT_ID  — incident reference (required, audited)
#   DRY_RUN      — default "true"
#   CONFIRM      — default "false"; requires DRY_RUN=false
#   RECONFIG_PLAN_HASH — plan_hash from the dry_run (required on confirm)
#   REQUESTED_BY — audit field (free text)
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
_INCIDENT_ID="${INCIDENT_ID:?INCIDENT_ID is required}"
_DRY_RUN="${DRY_RUN:-true}"
_CONFIRM="${CONFIRM:-false}"
_PLAN_HASH="${RECONFIG_PLAN_HASH:-}"
_REQUESTED_BY="${REQUESTED_BY:-}"

# Same dry_run/confirm contract as mongodb/account/create-account.sh
if [[ "$_DRY_RUN" == "true" && "$_CONFIRM" == "true" ]]; then
  jq -n '{"error":"confirm=true with dry_run=true is not supported"}' > "$AQSH_RESULT_FILE"
  exit 1
fi
if [[ "$_DRY_RUN" != "true" && "$_CONFIRM" != "true" ]]; then
  jq -n '{"error":"confirm=true is required when dry_run=false"}' > "$AQSH_RESULT_FILE"
  exit 1
fi
_MODE="dry_run"
[[ "$_CONFIRM" == "true" ]] && _MODE="confirm"

_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "")
_CRED_ROW=$(recovery_resolve_credentials \
  "${MONGO_CRED_SECRET_DEFAULT:-}" \
  "${MONGO_CRED_USER_DEFAULT:-}" \
  "${MONGO_CRED_USER_KEY_DEFAULT:-}" \
  "${MONGO_CRED_PASS_KEY_DEFAULT:-}" \
  "$_STS")
IFS=$'\x1f' read -r _SECRET _DIRECT_USER _USER_KEY _PASS_KEY <<< "$_CRED_ROW"

log_info "reconfig-force-dr" "STS=${_STS} namespace=${DB_NAMESPACE} mode=${_MODE} incident=${_INCIDENT_ID}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"

result=$(reconfig_force_dr "$_STS" "$_INCIDENT_ID" "$_MODE" "$_PLAN_HASH" \
  "$_REQUESTED_BY" "$_MONGO_USER" "$_MONGO_PASS") || {
  printf '%s\n' "$result" \
    | jq -c '{error: .message} + (.data // {})' > "$AQSH_RESULT_FILE"
  exit 1
}
printf '%s\n' "$result" | jq -c '.data' > "$AQSH_RESULT_FILE"
