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
EXTEND_DAYS="${EXTEND_DAYS:?EXTEND_DAYS is required}"
ALLOW_TERMINAL_OVERRIDE="${ALLOW_TERMINAL_OVERRIDE:-false}"

if ! [[ "$EXTEND_DAYS" =~ ^[0-9]+$ ]] || [[ "$EXTEND_DAYS" -lt 1 ]]; then
  fail_task "INVALID_INPUT" "extend_days must be a positive integer"
fi

precheck_rc=0
mongo_account_shared_precheck "true" "$DB_NAMESPACE" "$MONGO_STS_NAME" "$MONGO_CRED_SECRET" "$MONGO_CRED_USER_KEY" "$MONGO_CRED_PASS_KEY" "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME" || precheck_rc=$?
case "$precheck_rc" in
  0) ;;
  1) fail_task "PRECHECK_FAILED" "precheck failed" ;;
  2) fail_task "NOT_FOUND" "account not found" ;;
esac

policy_json=$(mongo_policy_get_json "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME" 2>/dev/null || echo "null")
if [[ "$(printf '%s' "$policy_json" | tr -d '[:space:]')" == "null" ]]; then
  fail_task "POLICY_NOT_FOUND" "policy record not found"
fi

status=$(echo "$policy_json" | jq -r '.status // empty')
if [[ "$status" == "EXPIRED_DELETED" || "$status" == "CANCELLED" ]]; then
  fail_task "STATE_BLOCKED" "cannot extend a terminal policy state"
fi

if [[ "$status" == "CHANGED" || "$status" == "PERMANENT" ]] && ! bool_enabled "$ALLOW_TERMINAL_OVERRIDE"; then
  fail_task "STATE_BLOCKED" "cannot extend expiry for changed/permanent account without override"
fi

expires_at="$(iso_utc_after_days "$EXTEND_DAYS")"
now_utc="$(iso_utc_now)"

# Step 1: Update MongoDB first (must succeed)
esc_db=$(_escape_js_string "$ACCOUNT_AUTH_DB")
esc_user=$(_escape_js_string "$ACCOUNT_USERNAME")
esc_exp=$(_escape_js_string "$expires_at")
js="const u = db.getSiblingDB('${esc_db}').getUser('${esc_user}', {showCredentials:false, showPrivileges:false}); const current = (u && u.customData) ? u.customData : {}; current.temp_account = true; current.expires_at='${esc_exp}'; db.getSiblingDB('${esc_db}').updateUser('${esc_user}', {customData: current}); JSON.stringify({ok:1})"
_mongosh_eval "admin" "$js" >/dev/null 2>&1 || fail_task "MONGODB_UPDATE_FAILED" "cannot update mongodb customdata"

# Step 2: Update policy after MongoDB succeeds
policy_set=$(jq -nc --arg status "ACTIVE" --arg expires_at "$expires_at" --arg updated_at "$now_utc" '{status:$status, expires_at:$expires_at, updated_at:$updated_at}')
mongo_policy_upsert "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME" "$policy_set" '{}' >/dev/null 2>&1 || fail_task "POLICY_WRITE_FAILED" "cannot update policy"

write_task_result "$(jq -n \
  --arg status "ACTIVE" \
  --arg reason_code "EXPIRY_EXTENDED" \
  --arg summary "account expiry extended" \
  --arg namespace "$DB_NAMESPACE" \
  --arg auth_db "$ACCOUNT_AUTH_DB" \
  --arg username "$ACCOUNT_USERNAME" \
  --arg expires_at "$expires_at" \
  '{status:$status, reason_code:$reason_code, summary:$summary, namespace:$namespace, auth_db:$auth_db, username:$username, expires_at:$expires_at}')"
