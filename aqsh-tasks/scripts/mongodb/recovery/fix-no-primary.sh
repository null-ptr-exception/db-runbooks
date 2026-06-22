#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/recovery/fix-no-primary.sh
# aqsh task: Restore a primary when all RS members show SECONDARY (E1+E5).
#
# Four escalation levels (RECOVERY_LEVEL):
#   diagnose      — query each pod's RS state; report diagnosis + recommendation
#   unfreeze      — send rs.freeze(0) to all pods to allow elections
#   reconfig      — force rs.reconfig({force:true}) to reset priority/votes
#   force-primary — shrink RS to RECOVERY_FORCE_POD, elect, then re-add others
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE            — target namespace
#   RECOVERY_LEVEL          — diagnose | unfreeze | reconfig | force-primary
#   RECOVERY_FORCE_POD      — pod name required when level=force-primary
#
# sts_name/credential secret/user/keys are not task inputs (see CLAUDE.md
# "Configuration Layers") — they resolve internal config (/etc/aqsh/config/
# mongodb.env) -> live cluster auto-detect -> hardcoded literal fallback.
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-recovery.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
_LEVEL="${RECOVERY_LEVEL:?RECOVERY_LEVEL is required (diagnose|unfreeze|reconfig|force-primary)}"
_FORCE_POD="${RECOVERY_FORCE_POD:-}"

# mongodb-recovery.sh (sourced above) already loads /etc/aqsh/config/mongodb.env
# before this point — see its header comment for why it must run there.
# RECOVERY_FORCE_POD (only set when level=force-primary) doubles as a
# target_pod hint: when present it lets STS detection use the more reliable
# ownerReferences lookup instead of falling back to namespace-listing (which
# only resolves when exactly one StatefulSet exists — see
# recovery_resolve_sts_name / _recovery_detect_sts_name).
_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "$_FORCE_POD")
_CRED_ROW=$(recovery_resolve_credentials \
  "${MONGO_CRED_SECRET_DEFAULT:-}" \
  "${MONGO_CRED_USER_DEFAULT:-}" \
  "${MONGO_CRED_USER_KEY_DEFAULT:-}" \
  "${MONGO_CRED_PASS_KEY_DEFAULT:-}" \
  "$_STS")
IFS=$'\x1f' read -r _SECRET _DIRECT_USER _USER_KEY _PASS_KEY <<< "$_CRED_ROW"

log_info "recovery-fix-no-primary" "Level=${_LEVEL} STS=${_STS} namespace=${DB_NAMESPACE}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_SECRET}" "${_USER_KEY}" "${_PASS_KEY}" "${_DIRECT_USER}"

case "$_LEVEL" in
  diagnose)
    result=$(recovery_fix_diagnose "$_STS" "$_MONGO_USER" "$_MONGO_PASS") || {
      printf '%s\n' "$result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
      exit 1
    }
    ;;
  unfreeze)
    result=$(recovery_fix_unfreeze "$_STS" "$_MONGO_USER" "$_MONGO_PASS") || {
      printf '%s\n' "$result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
      exit 1
    }
    ;;
  reconfig)
    result=$(recovery_fix_reconfig "$_STS" "$_MONGO_USER" "$_MONGO_PASS") || {
      printf '%s\n' "$result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
      exit 1
    }
    ;;
  force-primary)
    [[ -z "$_FORCE_POD" ]] && {
      jq -n '{"status":"error","message":"RECOVERY_FORCE_POD is required when level=force-primary"}' \
        > "$AQSH_RESULT_FILE"; exit 1
    }
    result=$(recovery_fix_force_primary "$_STS" "$_FORCE_POD" "$_MONGO_USER" "$_MONGO_PASS") || {
      printf '%s\n' "$result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
      exit 1
    }
    ;;
  *)
    jq -n --arg lvl "$_LEVEL" \
      '{"status":"error","message":"Unknown RECOVERY_LEVEL","level":$lvl,"valid_levels":["diagnose","unfreeze","reconfig","force-primary"]}' \
      > "$AQSH_RESULT_FILE"; exit 1
    ;;
esac

printf '%s\n' "$result" | jq -c '.data // {"error":.message}' > "$AQSH_RESULT_FILE"
