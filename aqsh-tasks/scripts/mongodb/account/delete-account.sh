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
DELETE_REASON="${DELETE_REASON:-MANUAL_DELETE}"

precheck_rc=0
mongo_account_shared_precheck "true" "$DB_NAMESPACE" "$MONGO_STS_NAME" "$MONGO_CRED_SECRET" "$MONGO_CRED_USER_KEY" "$MONGO_CRED_PASS_KEY" "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME" || precheck_rc=$?
case "$precheck_rc" in
  0) ;;
  1) fail_task "PRECHECK_FAILED" "precheck failed" ;;
  2) fail_task "NOT_FOUND" "account not found" ;;
esac

mongo_drop_user "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME" >/dev/null 2>&1 || fail_task "DELETE_FAILED" "cannot drop account"

now_utc="$(iso_utc_now)"
policy_set=$(jq -nc --arg status "CANCELLED" --arg updated_at "$now_utc" --arg deleted_at "$now_utc" --arg delete_reason "$DELETE_REASON" '{status:$status, updated_at:$updated_at, deleted_at:$deleted_at, delete_reason:$delete_reason}')
mongo_policy_upsert "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME" "$policy_set" '{}' >/dev/null 2>&1 || true

write_task_result "$(jq -n \
  --arg status "DELETED" \
  --arg reason_code "ACCOUNT_DELETED" \
  --arg summary "account deleted" \
  --arg namespace "$DB_NAMESPACE" \
  --arg auth_db "$ACCOUNT_AUTH_DB" \
  --arg username "$ACCOUNT_USERNAME" \
  --arg delete_reason "$DELETE_REASON" \
  '{status:$status, reason_code:$reason_code, summary:$summary, namespace:$namespace, auth_db:$auth_db, username:$username, delete_reason:$delete_reason}')"
