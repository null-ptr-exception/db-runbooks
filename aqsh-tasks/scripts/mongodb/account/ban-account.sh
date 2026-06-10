#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="${LIB_DIR:-/tasks/lib}"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-account.sh"

DB_NAMESPACE="${DB_NAMESPACE:?DB_NAMESPACE is required}"
MONGO_STS_NAME="${MONGO_STS_NAME:-mongodb}"
MONGO_CRED_SECRET="${MONGO_CRED_SECRET:-mongodb-credentials}"
MONGO_CRED_USER_KEY="${MONGO_CRED_USER_KEY:-MONGO_ROOT_USER}"
MONGO_CRED_PASS_KEY="${MONGO_CRED_PASS_KEY:-MONGO_ROOT_PASS}"
ACCOUNT_AUTH_DB="${ACCOUNT_AUTH_DB:-admin}"
ACCOUNT_USERNAME="${ACCOUNT_USERNAME:?ACCOUNT_USERNAME is required}"
BAN_REASON="${BAN_REASON:-SECURITY_POLICY}"

precheck_rc=0
mongo_account_shared_precheck "true" "$DB_NAMESPACE" "$MONGO_STS_NAME" "$MONGO_CRED_SECRET" "$MONGO_CRED_USER_KEY" "$MONGO_CRED_PASS_KEY" "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME" || precheck_rc=$?
case "$precheck_rc" in
  0) ;;
  1) fail_task "PRECHECK_FAILED" "precheck failed" ;;
  2) fail_task "NOT_FOUND" "account not found" ;;
esac

policy_status=""
if policy_status=$(mongo_policy_status "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME" 2>/dev/null); then
  if [[ "$policy_status" == "EXPIRED_DELETED" || "$policy_status" == "CANCELLED" ]]; then
    fail_task "STATE_BLOCKED" "cannot ban account in terminal policy state"
  fi
fi

esc_db=$(_escape_js_string "$ACCOUNT_AUTH_DB")
esc_user=$(_escape_js_string "$ACCOUNT_USERNAME")
js="db.getSiblingDB('${esc_db}').updateUser('${esc_user}', {roles: []}); JSON.stringify({ok:1})"
_mongosh_eval "admin" "$js" >/dev/null 2>&1 || fail_task "BAN_FAILED" "cannot update account roles for ban"

now_utc="$(iso_utc_now)"
policy_set=$(jq -nc --arg status "BANNED" --arg updated_at "$now_utc" --arg banned_at "$now_utc" --arg ban_reason "$BAN_REASON" '{status:$status, updated_at:$updated_at, banned_at:$banned_at, ban_reason:$ban_reason}')
mongo_policy_upsert "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME" "$policy_set" '{}' >/dev/null 2>&1 || fail_task "POLICY_WRITE_FAILED" "cannot update policy"

write_task_result "$(jq -n \
  --arg status "BANNED" \
  --arg reason_code "ACCOUNT_BANNED" \
  --arg summary "account banned by removing roles" \
  --arg namespace "$DB_NAMESPACE" \
  --arg auth_db "$ACCOUNT_AUTH_DB" \
  --arg username "$ACCOUNT_USERNAME" \
  --arg ban_reason "$BAN_REASON" \
  '{status:$status, reason_code:$reason_code, summary:$summary, namespace:$namespace, auth_db:$auth_db, username:$username, ban_reason:$ban_reason}')"
