setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  deploy_mongodb "mongo-1"
}

setup() {
  load '../test_helper/common_setup'
}

teardown_file() {
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" delete ns mongo-1 --ignore-not-found
}

_task_result_data() {
  echo "$TASK_RESPONSE" | jq -c '
    .result.data as $data |
    (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))
  '
}

_root_user() {
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 get secret mongodb-credentials -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d
}

_root_pass() {
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 get secret mongodb-credentials -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d
}

_mongo_exec() {
  local js="$1"
  local user pass
  user="$(_root_user)"
  pass="$(_root_pass)"
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 exec mongodb-0 -- \
    mongosh --quiet --norc "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin" --eval "$js"
}

_mongo_exec_as() {
  local auth_db="$1"
  local username="$2"
  local password="$3"
  local js="$4"

  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 exec mongodb-0 -- \
    mongosh --quiet --norc \
      --username "$username" \
      --password "$password" \
      --authenticationDatabase "$auth_db" \
      "$auth_db" \
      --eval "$js"
}

_cleanup_account() {
  local username="$1"
  _mongo_exec "try { db.getSiblingDB('admin').dropUser('${username}'); } catch (e) { /* ignore missing user */ }"
  _mongo_exec "db.getSiblingDB('admin').getCollection('run_account_policies').deleteOne({username:'${username}', auth_db:'admin'});"
}

_submit_task() {
  local path="$1"
  local payload="$2"
  local task_id

  http_post "${MONGODB_AQSH_URL}/tasks/${path}" "$payload"
  assert_equal "$HTTP_CODE" "202"

  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [ -n "$task_id" ]
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"
}

_submit_task_allow_failure() {
  local path="$1"
  local payload="$2"
  local task_id

  http_post "${MONGODB_AQSH_URL}/tasks/${path}" "$payload"
  assert_equal "$HTTP_CODE" "202"

  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [ -n "$task_id" ]
  wait_for_task "$MONGODB_AQSH_URL" "$task_id" || true
}

@test "create-account creates run user and policy" {
  _cleanup_account "qa_temp_user"

  local payload
  payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_temp_user",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    dry_run: "false",
    confirm: "true",
    request_id: "test-create-001",
    requested_by: "bats"
  }')

  _submit_task "create-account" "$payload"

  local result status user_exists policy_status
  result="$(_task_result_data)"
  status=$(echo "$result" | jq -r '.status')
  [ "$status" = "CREATED" ] || [ "$status" = "RECREATED" ]

  user_exists=$(_mongo_exec "const u=db.getSiblingDB('admin').getUser('qa_temp_user'); print(u ? 'yes' : 'no');" | tail -1)
  [ "$user_exists" = "yes" ]

  policy_status=$(_mongo_exec "const d=db.getSiblingDB('admin').getCollection('run_account_policies').findOne({username:'qa_temp_user', auth_db:'admin'}); print(d ? d.status : 'missing');" | tail -1)
  [ "$policy_status" = "ACTIVE" ]
}

@test "delete-account removes user" {
  _cleanup_account "qa_delete_user"

  local create_payload
  create_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_delete_user",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    dry_run: "false",
    confirm: "true"
  }')
  _submit_task "create-account" "$create_payload"

  local delete_payload
  delete_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_delete_user",
    delete_reason: "bats-cleanup"
  }')
  _submit_task "delete-account" "$delete_payload"

  local user_exists
  user_exists=$(_mongo_exec "const u=db.getSiblingDB('admin').getUser('qa_delete_user'); print(u ? 'yes' : 'no');" | tail -1)
  [ "$user_exists" = "no" ]
}

@test "reconcile-expiry deletes unchanged expired account" {
  _cleanup_account "qa_expire_user"

  local create_payload
  create_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_expire_user",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    dry_run: "false",
    confirm: "true"
  }')
  _submit_task "create-account" "$create_payload"

  _mongo_exec "db.getSiblingDB('admin').getCollection('run_account_policies').updateOne({username:'qa_expire_user', auth_db:'admin'}, {\$set:{expires_at:'2000-01-01T00:00:00Z', status:'ACTIVE'}});"

  local reconcile_payload
  reconcile_payload=$(jq -nc '{namespace:"mongo-1"}')
  _submit_task "reconcile-expiry" "$reconcile_payload"

  local user_exists policy_status
  user_exists=$(_mongo_exec "const u=db.getSiblingDB('admin').getUser('qa_expire_user'); print(u ? 'yes' : 'no');" | tail -1)
  [ "$user_exists" = "no" ]

  policy_status=$(_mongo_exec "const d=db.getSiblingDB('admin').getCollection('run_account_policies').findOne({username:'qa_expire_user', auth_db:'admin'}); print(d ? d.status : 'missing');" | tail -1)
  [ "$policy_status" = "EXPIRED_DELETED" ]
}

@test "create-account encrypted payload can be decrypted and used" {
  if ! command -v gpg >/dev/null 2>&1; then
    skip "gpg is required for encrypted payload test"
  fi

  _cleanup_account "qa_encrypt_user"

  local gnupg_home recipient key_block_b64 payload
  local result status mode ciphertext decrypted ping_ok

  gnupg_home=$(mktemp -d)
  chmod 700 "$gnupg_home"
  recipient="bats-encrypted@example.com"

  GNUPGHOME="$gnupg_home" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "$recipient" rsa3072 encr 1d >/dev/null 2>&1

  key_block_b64=$(GNUPGHOME="$gnupg_home" gpg --batch --armor --export "$recipient" | base64 | tr -d '\n')

  payload=$(jq -nc \
    --arg pub "$key_block_b64" \
    '{
      namespace: "mongo-1",
      auth_db: "admin",
      username: "qa_encrypt_user",
      roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
      dry_run: "false",
      confirm: "true",
      password_delivery_mode: "encrypted_payload",
      recipient_pgp_pubkey: $pub
    }')

  _submit_task "create-account" "$payload"

  result="$(_task_result_data)"
  status=$(echo "$result" | jq -r '.status')
  [ "$status" = "CREATED" ] || [ "$status" = "RECREATED" ]

  mode=$(echo "$result" | jq -r '.delivery_payload.mode // empty')
  [ "$mode" = "encrypted_payload" ]

  ciphertext=$(echo "$result" | jq -r '.delivery_payload.ciphertext // empty')
  [ -n "$ciphertext" ]

  decrypted=$(printf '%s' "$ciphertext" | GNUPGHOME="$gnupg_home" gpg --batch --decrypt 2>/dev/null)
  [ -n "$decrypted" ]

  ping_ok=$(_mongo_exec_as "admin" "qa_encrypt_user" "$decrypted" "db.adminCommand({ping:1}).ok" | tail -1)
  [ "$ping_ok" = "1" ]

  rm -rf "$gnupg_home"
}

@test "reset-password encrypted payload can be decrypted and used" {
  if ! command -v gpg >/dev/null 2>&1; then
    skip "gpg is required for encrypted payload test"
  fi

  _cleanup_account "qa_reset_encrypt_user"

  local create_payload
  create_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_reset_encrypt_user",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    dry_run: "false",
    confirm: "true"
  }')
  _submit_task "create-account" "$create_payload"

  local gnupg_home recipient key_block_b64 payload
  local result mode ciphertext decrypted ping_ok

  gnupg_home=$(mktemp -d)
  chmod 700 "$gnupg_home"
  recipient="bats-reset-encrypted@example.com"

  GNUPGHOME="$gnupg_home" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "$recipient" rsa3072 encr 1d >/dev/null 2>&1

  key_block_b64=$(GNUPGHOME="$gnupg_home" gpg --batch --armor --export "$recipient" | base64 | tr -d '\n')

  payload=$(jq -nc --arg pub "$key_block_b64" '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_reset_encrypt_user",
    validity_days: "7",
    password_delivery_mode: "encrypted_payload",
    recipient_pgp_pubkey: $pub
  }')

  _submit_task "reset-password" "$payload"

  result="$(_task_result_data)"
  mode=$(echo "$result" | jq -r '.delivery_payload.mode // empty')
  [ "$mode" = "encrypted_payload" ]

  ciphertext=$(echo "$result" | jq -r '.delivery_payload.ciphertext // empty')
  [ -n "$ciphertext" ]

  decrypted=$(printf '%s' "$ciphertext" | GNUPGHOME="$gnupg_home" gpg --batch --decrypt 2>/dev/null)
  [ -n "$decrypted" ]

  ping_ok=$(_mongo_exec_as "admin" "qa_reset_encrypt_user" "$decrypted" "db.adminCommand({ping:1}).ok" | tail -1)
  [ "$ping_ok" = "1" ]

  rm -rf "$gnupg_home"
}

@test "delete-account blocks terminal or error policy state" {
  _cleanup_account "qa_delete_blocked_user"

  local create_payload
  create_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_delete_blocked_user",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    dry_run: "false",
    confirm: "true"
  }')
  _submit_task "create-account" "$create_payload"

  _mongo_exec "db.getSiblingDB('admin').getCollection('run_account_policies').updateOne({username:'qa_delete_blocked_user', auth_db:'admin'}, {\$set:{status:'ERROR', updated_at:new Date().toISOString()}})"

  local payload task_id
  payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_delete_blocked_user",
    delete_reason: "blocked-state-test"
  }')

  http_post "${MONGODB_AQSH_URL}/tasks/delete-account" "$payload"
  assert_equal "$HTTP_CODE" "202"

  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [ -n "$task_id" ]
  wait_for_task "$MONGODB_AQSH_URL" "$task_id" || true

  local result reason
  result="$(_task_result_data)"
  reason=$(echo "$result" | jq -r '.reason_code // empty')
  [ "$reason" = "STATE_BLOCKED" ]
}

@test "ban-account removes all roles" {
  _cleanup_account "qa_ban_user"

  local create_payload
  create_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_ban_user",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    dry_run: "false",
    confirm: "true"
  }')
  _submit_task "create-account" "$create_payload"

  local ban_payload
  ban_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_ban_user"
  }')
  _submit_task "ban-account" "$ban_payload"

  local result status policy_status
  result="$(_task_result_data)"
  status=$(echo "$result" | jq -r '.status')
  [ "$status" = "BANNED" ]

  policy_status=$(_mongo_exec "const d=db.getSiblingDB('admin').getCollection('run_account_policies').findOne({username:'qa_ban_user', auth_db:'admin'}); print(d ? d.status : 'missing');" | tail -1)
  [ "$policy_status" = "BANNED" ]
}

@test "extend-expiry updates expiration date" {
  _cleanup_account "qa_extend_user"

  local create_payload
  create_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_extend_user",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    dry_run: "false",
    confirm: "true",
    validity_days: "1"
  }')
  _submit_task "create-account" "$create_payload"

  local extend_payload
  extend_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_extend_user",
    extend_days: "10"
  }')
  _submit_task "extend-expiry" "$extend_payload"

  local result status expires_at
  result="$(_task_result_data)"
  status=$(echo "$result" | jq -r '.status')
  [ "$status" = "ACTIVE" ]

  expires_at=$(echo "$result" | jq -r '.expires_at // empty')
  [ -n "$expires_at" ]
}

@test "force-permanent sets policy to PERMANENT" {
  _cleanup_account "qa_force_user"

  local create_payload
  create_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_force_user",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    dry_run: "false",
    confirm: "true"
  }')
  _submit_task "create-account" "$create_payload"

  local force_payload
  force_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_force_user",
    forced_by: "bats"
  }')
  _submit_task "force-permanent" "$force_payload"

  local result status policy_status
  result="$(_task_result_data)"
  status=$(echo "$result" | jq -r '.status')
  [ "$status" = "PERMANENT" ]

  policy_status=$(_mongo_exec "const d=db.getSiblingDB('admin').getCollection('run_account_policies').findOne({username:'qa_force_user', auth_db:'admin'}); print(d ? d.status : 'missing');" | tail -1)
  [ "$policy_status" = "PERMANENT" ]
}

@test "reconcile-expiry preserves account with changed password as CHANGED" {
  _cleanup_account "qa_changed_user"

  local create_payload
  create_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_changed_user",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    dry_run: "false",
    confirm: "true"
  }')
  _submit_task "create-account" "$create_payload"

  # Manually change the password to trigger CHANGED state
  local old_fp
  old_fp=$(_mongo_exec "const d=db.getSiblingDB('admin').getCollection('run_account_policies').findOne({username:'qa_changed_user', auth_db:'admin'}); print(d ? d.initial_cred_fingerprint : 'missing');" | tail -1)

  _mongo_exec "db.getSiblingDB('admin').updateUser('qa_changed_user', {pwd:'different_password_123'});"
  _mongo_exec "db.getSiblingDB('admin').getCollection('run_account_policies').updateOne({username:'qa_changed_user', auth_db:'admin'}, {\$set:{expires_at:'2000-01-01T00:00:00Z', status:'ACTIVE'}});"

  local reconcile_payload
  reconcile_payload=$(jq -nc '{namespace:"mongo-1"}')
  _submit_task "reconcile-expiry" "$reconcile_payload"

  local user_exists policy_status
  user_exists=$(_mongo_exec "const u=db.getSiblingDB('admin').getUser('qa_changed_user'); print(u ? 'yes' : 'no');" | tail -1)
  [ "$user_exists" = "yes" ]

  policy_status=$(_mongo_exec "const d=db.getSiblingDB('admin').getCollection('run_account_policies').findOne({username:'qa_changed_user', auth_db:'admin'}); print(d ? d.status : 'missing');" | tail -1)
  [ "$policy_status" = "CHANGED" ]
}

@test "reconcile-expiry continues on partial errors" {
  # Create two expired accounts
  _cleanup_account "qa_partial_1"
  _cleanup_account "qa_partial_2"

  local create_payload
  create_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_partial_1",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    dry_run: "false",
    confirm: "true"
  }')
  _submit_task "create-account" "$create_payload"

  create_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_partial_2",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    dry_run: "false",
    confirm: "true"
  }')
  _submit_task "create-account" "$create_payload"

  # Set both as expired
  _mongo_exec "db.getSiblingDB('admin').getCollection('run_account_policies').updateMany({username:{\$in:['qa_partial_1', 'qa_partial_2']}, auth_db:'admin'}, {\$set:{expires_at:'2000-01-01T00:00:00Z', status:'ACTIVE'}});"

  # Simulate error condition: drop first account's user but leave policy intact
  # This creates a mismatch that should be handled gracefully during reconciliation
  _mongo_exec "db.getSiblingDB('admin').dropUser('qa_partial_1');"

  local reconcile_payload
  reconcile_payload=$(jq -nc '{namespace:"mongo-1"}')
  _submit_task "reconcile-expiry" "$reconcile_payload"

  local result status processed
  result="$(_task_result_data)"
  status=$(echo "$result" | jq -r '.status')
  [ "$status" = "OK" ]

  # Should have processed both accounts (first failed gracefully, second succeeded)
  processed=$(echo "$result" | jq -r '.processed // 0')
  [ "$processed" -ge 2 ]

  # Second account should be deleted (not in error state)
  local user_exists
  user_exists=$(_mongo_exec "const u=db.getSiblingDB('admin').getUser('qa_partial_2'); print(u ? 'yes' : 'no');" | tail -1)
  [ "$user_exists" = "no" ]

  # First account should still have policy record (even though user was already deleted)
  local policy_status
  policy_status=$(_mongo_exec "const d=db.getSiblingDB('admin').getCollection('run_account_policies').findOne({username:'qa_partial_1', auth_db:'admin'}); print(d ? d.status : 'missing');" | tail -1)
  # Status should be EXPIRED_DELETED (reconciliation continues despite error)
  [ "$policy_status" = "EXPIRED_DELETED" ]
}

@test "create-account rejects invalid validity_days" {
  local payload
  payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_invalid_days",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    validity_days: "-5",
    dry_run: "false",
    confirm: "true"
  }')

  _submit_task_allow_failure "create-account" "$payload"

  local result reason_code
  result="$(_task_result_data)"
  reason_code=$(echo "$result" | jq -r '.reason_code // empty')
  [ "$reason_code" = "INVALID_INPUT" ]
}

@test "create-account rejects non-numeric validity_days" {
  local payload
  payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_non_numeric",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    validity_days: "invalid",
    dry_run: "false",
    confirm: "true"
  }')

  _submit_task_allow_failure "create-account" "$payload"

  local result reason_code
  result="$(_task_result_data)"
  reason_code=$(echo "$result" | jq -r '.reason_code // empty')
  [ "$reason_code" = "INVALID_INPUT" ]
}

@test "create-account rejects missing recipient_pgp_pubkey for encrypted mode" {
  local payload
  payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_missing_key",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    dry_run: "false",
    confirm: "true",
    password_delivery_mode: "encrypted_payload"
  }')

  _submit_task_allow_failure "create-account" "$payload"

  local result reason_code
  result="$(_task_result_data)"
  reason_code=$(echo "$result" | jq -r '.reason_code // empty')
  [ "$reason_code" = "INVALID_INPUT" ]
}

@test "ban-account fails on non-existent account" {
  _cleanup_account "qa_nonexistent_ban"

  local ban_payload
  ban_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_nonexistent_ban"
  }')
  _submit_task_allow_failure "ban-account" "$ban_payload"

  local result reason_code
  result="$(_task_result_data)"
  reason_code=$(echo "$result" | jq -r '.reason_code // empty')
  [ "$reason_code" = "ACCOUNT_NOT_FOUND" ] || [ "$reason_code" = "OPERATION_FAILED" ]
}

@test "extend-expiry fails on non-existent account" {
  _cleanup_account "qa_nonexistent_extend"

  local extend_payload
  extend_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_nonexistent_extend",
    extend_days: "5"
  }')
  _submit_task_allow_failure "extend-expiry" "$extend_payload"

  local result reason_code
  result="$(_task_result_data)"
  reason_code=$(echo "$result" | jq -r '.reason_code // empty')
  [ "$reason_code" = "ACCOUNT_NOT_FOUND" ] || [ "$reason_code" = "OPERATION_FAILED" ]
}

@test "extend-expiry rejects invalid extend_days" {
  _cleanup_account "qa_invalid_extend"

  local create_payload
  create_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_invalid_extend",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    dry_run: "false",
    confirm: "true"
  }')
  _submit_task "create-account" "$create_payload"

  local extend_payload
  extend_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_invalid_extend",
    extend_days: "not_a_number"
  }')
  _submit_task_allow_failure "extend-expiry" "$extend_payload"

  local result reason_code
  result="$(_task_result_data)"
  reason_code=$(echo "$result" | jq -r '.reason_code // empty')
  [ "$reason_code" = "INVALID_INPUT" ]
}

@test "force-permanent fails on non-existent account" {
  _cleanup_account "qa_nonexistent_force"

  local force_payload
  force_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_nonexistent_force"
  }')
  _submit_task_allow_failure "force-permanent" "$force_payload"

  local result reason_code
  result="$(_task_result_data)"
  reason_code=$(echo "$result" | jq -r '.reason_code // empty')
  [ "$reason_code" = "ACCOUNT_NOT_FOUND" ] || [ "$reason_code" = "OPERATION_FAILED" ]
}

@test "reset-password rejects invalid validity_days" {
  _cleanup_account "qa_reset_invalid"

  local create_payload
  create_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_reset_invalid",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    dry_run: "false",
    confirm: "true"
  }')
  _submit_task "create-account" "$create_payload"

  local reset_payload
  reset_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_reset_invalid",
    validity_days: "0"
  }')
  _submit_task_allow_failure "reset-password" "$reset_payload"

  local result reason_code
  result="$(_task_result_data)"
  reason_code=$(echo "$result" | jq -r '.reason_code // empty')
  [ "$reason_code" = "INVALID_INPUT" ]
}

@test "reset-password rejects missing recipient_pgp_pubkey for encrypted mode" {
  _cleanup_account "qa_reset_no_key"

  local create_payload
  create_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_reset_no_key",
    roles_json: "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
    dry_run: "false",
    confirm: "true"
  }')
  _submit_task "create-account" "$create_payload"

  local reset_payload
  reset_payload=$(jq -nc '{
    namespace: "mongo-1",
    auth_db: "admin",
    username: "qa_reset_no_key",
    validity_days: "7",
    password_delivery_mode: "encrypted_payload"
  }')
  _submit_task_allow_failure "reset-password" "$reset_payload"

  local result reason_code
  result="$(_task_result_data)"
  reason_code=$(echo "$result" | jq -r '.reason_code // empty')
  [ "$reason_code" = "INVALID_INPUT" ]
}
