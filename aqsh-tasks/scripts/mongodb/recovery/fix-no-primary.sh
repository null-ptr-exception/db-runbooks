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
#   MONGO_STS_NAME          — StatefulSet name (default: mongodb)
#   MONGO_CRED_SECRET       — Secret name (default: mongodb-credentials)
#   MONGO_CRED_USER_KEY     — Secret key for username (default: MONGO_ROOT_USER)
#   MONGO_CRED_PASS_KEY     — Secret key for password (default: MONGO_ROOT_PASS)
#   RECOVERY_LEVEL          — diagnose | unfreeze | reconfig | force-primary
#   RECOVERY_FORCE_POD      — pod name required when level=force-primary
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-recovery.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
_STS="${MONGO_STS_NAME:-mongodb}"
_SECRET="${MONGO_CRED_SECRET:-mongodb-credentials}"
_USER_KEY="${MONGO_CRED_USER_KEY:-MONGO_ROOT_USER}"
_PASS_KEY="${MONGO_CRED_PASS_KEY:-MONGO_ROOT_PASS}"
_LEVEL="${RECOVERY_LEVEL:?RECOVERY_LEVEL is required (diagnose|unfreeze|reconfig|force-primary)}"
_FORCE_POD="${RECOVERY_FORCE_POD:-}"

log_info "recovery-fix-no-primary" "Level=${_LEVEL} STS=${_STS} namespace=${DB_NAMESPACE}"

_MONGO_USER=$(kubectl -n "${DB_NAMESPACE}" get secret "${_SECRET}" \
  -o jsonpath="{.data.${_USER_KEY}}" 2>/dev/null | base64 -d) || {
  jq -n --arg ns "${DB_NAMESPACE}" --arg s "${_SECRET}" \
    '{"status":"error","message":"Cannot read credentials from secret","namespace":$ns,"secret":$s}' \
    > "$AQSH_RESULT_FILE"; exit 1
}
_MONGO_PASS=$(kubectl -n "${DB_NAMESPACE}" get secret "${_SECRET}" \
  -o jsonpath="{.data.${_PASS_KEY}}" 2>/dev/null | base64 -d) || {
  jq -n --arg ns "${DB_NAMESPACE}" --arg s "${_SECRET}" \
    '{"status":"error","message":"Cannot read credentials from secret","namespace":$ns,"secret":$s}' \
    > "$AQSH_RESULT_FILE"; exit 1
}

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
