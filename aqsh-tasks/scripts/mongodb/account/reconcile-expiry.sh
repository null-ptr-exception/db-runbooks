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

mongo_account_set_connection_from_root_secret "$DB_NAMESPACE" "$MONGO_STS_NAME" "$MONGO_CRED_SECRET" "$MONGO_CRED_USER_KEY" "$MONGO_CRED_PASS_KEY" \
  || fail_task "PRECHECK_FAILED" "cannot resolve primary or credentials"
mongo_account_connection_check || fail_task "PRECHECK_FAILED" "cannot connect to mongo"

esc_policy_db=$(_escape_js_string "$MONGO_POLICY_DB")
esc_policy_coll=$(_escape_js_string "$MONGO_POLICY_COLLECTION")
expired_json=$(_mongosh_eval "admin" "const now = new Date().toISOString(); const docs = db.getSiblingDB('${esc_policy_db}').getCollection('${esc_policy_coll}').find({status:'ACTIVE', expires_at:{\$lte: now}}).toArray(); JSON.stringify(docs);") || fail_task "QUERY_FAILED" "cannot query policies"

processed=0
changed=0
deleted=0
skipped=0

if [[ "$(echo "$expired_json" | jq 'length')" -eq 0 ]]; then
  write_task_result "$(jq -n '{status:"OK", reason_code:"NOOP", summary:"no active expired policies", processed:0, changed:0, deleted:0, skipped:0}')"
  exit 0
fi

while IFS= read -r row; do
  processed=$((processed + 1))
  username=$(echo "$row" | jq -r '.username')
  auth_db=$(echo "$row" | jq -r '.auth_db')
  initial_fp=$(echo "$row" | jq -r '.initial_cred_fingerprint // empty')

  if ! mongo_account_exists "$auth_db" "$username"; then
    now_utc=$(iso_utc_now)
    set_json=$(jq -nc --arg status "EXPIRED_DELETED" --arg deleted_at "$now_utc" --arg updated_at "$now_utc" --arg reason "USER_NOT_FOUND_AT_RECONCILE" '{status:$status, deleted_at:$deleted_at, updated_at:$updated_at, delete_reason:$reason}')
    mongo_policy_upsert "$auth_db" "$username" "$set_json" '{}' >/dev/null 2>&1 || true
    deleted=$((deleted + 1))
    continue
  fi

  current_fp=$(mongo_account_credentials_fingerprint "$auth_db" "$username" || true)
  now_utc=$(iso_utc_now)

  if [[ -n "$current_fp" && -n "$initial_fp" && "$current_fp" != "$initial_fp" ]]; then
    set_json=$(jq -nc --arg status "CHANGED" --arg changed_at "$now_utc" --arg updated_at "$now_utc" --arg last_fp "$current_fp" '{status:$status, changed_at:$changed_at, updated_at:$updated_at, last_cred_fingerprint:$last_fp}')
    mongo_policy_upsert "$auth_db" "$username" "$set_json" '{}' >/dev/null 2>&1 || true
    changed=$((changed + 1))
    continue
  fi

  if mongo_drop_user "$auth_db" "$username" >/dev/null 2>&1; then
    set_json=$(jq -nc --arg status "EXPIRED_DELETED" --arg deleted_at "$now_utc" --arg updated_at "$now_utc" --arg reason "EXPIRED_UNCHANGED_PASSWORD" '{status:$status, deleted_at:$deleted_at, updated_at:$updated_at, delete_reason:$reason}')
    mongo_policy_upsert "$auth_db" "$username" "$set_json" '{}' >/dev/null 2>&1 || true
    deleted=$((deleted + 1))
  else
    set_json=$(jq -nc --arg status "ERROR" --arg updated_at "$now_utc" --arg code "DELETE_FAILED" '{status:$status, updated_at:$updated_at, last_error_code:$code}')
    mongo_policy_upsert "$auth_db" "$username" "$set_json" '{}' >/dev/null 2>&1 || true
    skipped=$((skipped + 1))
  fi
done < <(echo "$expired_json" | jq -c '.[]')

write_task_result "$(jq -n \
  --arg status "OK" \
  --arg reason_code "RECONCILED" \
  --arg summary "expiry reconciliation completed" \
  --argjson processed "$processed" \
  --argjson changed "$changed" \
  --argjson deleted "$deleted" \
  --argjson skipped "$skipped" \
  '{status:$status, reason_code:$reason_code, summary:$summary, processed:$processed, changed:$changed, deleted:$deleted, skipped:$skipped}')"
