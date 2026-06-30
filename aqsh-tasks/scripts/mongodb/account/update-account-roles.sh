#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="${LIB_DIR:-/tasks/lib}"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-account.sh"

DB_NAMESPACE="${DB_NAMESPACE:?DB_NAMESPACE is required}"
[[ -f /etc/aqsh/config/mongodb.env ]] && source /etc/aqsh/config/mongodb.env
MONGO_STS_NAME="${MONGO_STS_NAME:-${MONGO_STS_NAME_DEFAULT:-mongodb}}"
MONGO_CRED_SECRET="${MONGO_CRED_SECRET:-${MONGO_CRED_SECRET_DEFAULT:-mongodb-credentials}}"
MONGO_CRED_USER_KEY="${MONGO_CRED_USER_KEY:-${MONGO_CRED_USER_KEY_DEFAULT:-MONGO_ROOT_USER}}"
MONGO_CRED_PASS_KEY="${MONGO_CRED_PASS_KEY:-${MONGO_CRED_PASS_KEY_DEFAULT:-MONGO_ROOT_PASS}}"
ACCOUNT_AUTH_DB="${ACCOUNT_AUTH_DB:-admin}"
ACCOUNT_USERNAME="${ACCOUNT_USERNAME:?ACCOUNT_USERNAME is required}"
ACCOUNT_ROLES_JSON="${ACCOUNT_ROLES_JSON:?ACCOUNT_ROLES_JSON is required}"

if ! echo "$ACCOUNT_ROLES_JSON" | jq -e 'type == "array" and length > 0 and all(.[]; has("role") and has("db"))' >/dev/null 2>&1; then
  fail_task "INVALID_INPUT" "roles_json must be a non-empty role array"
fi

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
    fail_task "STATE_BLOCKED" "cannot update roles in terminal policy state"
  fi
fi

esc_db=$(_escape_js_string "$ACCOUNT_AUTH_DB")
esc_user=$(_escape_js_string "$ACCOUNT_USERNAME")
esc_roles=$(_escape_js_string "$ACCOUNT_ROLES_JSON")
js="const roles = JSON.parse('${esc_roles}'); db.getSiblingDB('${esc_db}').updateUser('${esc_user}', {roles: roles}); JSON.stringify({ok:1})"
_mongosh_eval "admin" "$js" >/dev/null 2>&1 || fail_task "UPDATE_ROLES_FAILED" "cannot update account roles"

now_utc="$(iso_utc_now)"
policy_set=$(jq -nc --argjson roles "$ACCOUNT_ROLES_JSON" --arg updated_at "$now_utc" '{roles:$roles, updated_at:$updated_at}')
mongo_policy_upsert "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME" "$policy_set" '{}' >/dev/null 2>&1 || fail_task "POLICY_WRITE_FAILED" "cannot update policy"

write_task_result "$(jq -n \
  --arg status "UPDATED" \
  --arg reason_code "ROLES_UPDATED" \
  --arg summary "account roles updated" \
  --arg namespace "$DB_NAMESPACE" \
  --arg auth_db "$ACCOUNT_AUTH_DB" \
  --arg username "$ACCOUNT_USERNAME" \
  --argjson roles "$ACCOUNT_ROLES_JSON" \
  '{status:$status, reason_code:$reason_code, summary:$summary, namespace:$namespace, auth_db:$auth_db, username:$username, roles:$roles}')"
