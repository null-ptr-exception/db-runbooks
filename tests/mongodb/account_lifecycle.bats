#!/usr/bin/env bats

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"

  # Ensure MongoDB RS is healthy (3 replicas with a primary).
  # recovery.bats teardown or a previous interrupted run may have left the
  # cluster in a degraded state.
  _ensure_mongodb_rs_healthy

  # Resolve test-client pod on cluster-b
  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  # Create a token from cluster-b SA
  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  export CTX_A CTX_B NS AQSH_URL TEST_POD TOKEN
}

_ensure_mongodb_rs_healthy() {
  local ctx="kind-cluster-a"

  # Ensure the StatefulSet is in RS mode with 3 replicas.
  # The helm chart deploys standalone (replicas=1, no --replSet);
  # recovery.bats upgrades to RS mode but its teardown may leave a
  # degraded state. Apply the full RS-mode spec unconditionally.
  local current_replicas current_cmd
  current_replicas=$(kubectl --context "$ctx" -n mongo-1 get statefulset mongodb \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  current_cmd=$(kubectl --context "$ctx" -n mongo-1 get statefulset mongodb \
    -o jsonpath='{.spec.template.spec.containers[0].args[0]}' 2>/dev/null || echo "")

  if [[ "$current_replicas" -lt 3 || "$current_cmd" != "--replSet" ]]; then
    echo "MongoDB not in 3-replica RS mode (replicas=${current_replicas}, args[0]=${current_cmd}), upgrading..."
    kubectl --context "$ctx" -n mongo-1 apply -f - <<'RS_EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: mongo-1
spec:
  replicas: 3
  selector:
    matchLabels:
      app: mongodb
  serviceName: mongodb
  template:
    metadata:
      labels:
        app: mongodb
        app.kubernetes.io/name: mongodb
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
      containers:
        - name: mongodb
          image: mongo:7
          command: ["mongod"]
          args: ["--replSet", "rs0", "--bind_ip_all"]
          ports:
            - containerPort: 27017
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
            readOnlyRootFilesystem: false
          readinessProbe:
            exec:
              command: ["mongosh", "--quiet", "--norc", "--eval", "db.adminCommand('ping').ok"]
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          volumeMounts:
            - name: data
              mountPath: /data/db
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
RS_EOF
    kubectl --context "$ctx" -n mongo-1 \
      rollout status statefulset/mongodb --timeout=300s

    # Initialize the replica set if not already done
    local rs_ok=false
    local attempt
    for attempt in 1 2 3; do
      if kubectl --context "$ctx" -n mongo-1 exec mongodb-0 -- mongosh --quiet --norc \
        "mongodb://localhost:27017/admin" --eval "
          try {
            rs.initiate({_id:'rs0', members:[
              {_id:0, host:'mongodb-0.mongodb.mongo-1.svc.cluster.local:27017', priority:2},
              {_id:1, host:'mongodb-1.mongodb.mongo-1.svc.cluster.local:27017', priority:1},
              {_id:2, host:'mongodb-2.mongodb.mongo-1.svc.cluster.local:27017', priority:1}
            ]});
          } catch(e) {
            if (/AlreadyInitialized/.test(e.message)) { print('RS already initialized'); }
            else { throw e; }
          }"; then
        rs_ok=true
        break
      fi
      echo "RS initiate attempt $attempt failed, retrying in 5s..." >&2
      sleep 5
    done
    if [[ "$rs_ok" != "true" ]]; then
      echo "RS initiate failed after 3 attempts" >&2; return 1
    fi
  fi

  # Ensure mongodb-0 has priority 2 (recovery tests may have set all to 1).
  kubectl --context "$ctx" -n mongo-1 exec mongodb-0 -- mongosh --quiet --norc \
    "mongodb://localhost:27017/admin" --eval "
      try {
        var cfg = rs.conf();
        var needsReconfig = false;
        cfg.members.forEach(function(m) {
          var target = m.host.indexOf('mongodb-0') !== -1 ? 2 : 1;
          if (m.priority !== target) { m.priority = target; needsReconfig = true; }
        });
        if (needsReconfig) {
          cfg.version++;
          rs.reconfig(cfg, {force: true});
          print('Reconfigured RS priorities (mongodb-0 → 2)');
        } else {
          print('RS priorities OK');
        }
      } catch(e) { print('Priority reconfig skipped: ' + e.message); }
    " 2>/dev/null || true

  # Wait for mongodb-0 to become PRIMARY (priority=2 ensures this).
  # _mongo_exec connects to mongodb-0 directly, so it must be writable.
  local elapsed=0
  while (( elapsed < 120 )); do
    local role
    role=$(kubectl --context "$ctx" -n mongo-1 exec mongodb-0 -c mongodb -- \
      mongosh --quiet --norc --eval "try{var h=db.hello();print(h.isWritablePrimary?'PRIMARY':'OTHER');}catch(e){print('ERR');}" \
      2>/dev/null | tail -1 | tr -d '\r') || role="ERR"
    [[ "$role" == "PRIMARY" ]] && { echo "MongoDB RS healthy — mongodb-0 is PRIMARY"; return 0; }
    sleep 3; elapsed=$((elapsed + 3))
  done
  echo "WARNING: mongodb-0 did not become PRIMARY after 120s" >&2
  return 1
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

# --- Helpers ---

kexec() {
  kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"
}

http_post() {
  local url="$1" body="$2"
  local response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\\n%{http_code}' \
    -X POST '${url}' \
    -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Content-Type: application/json' \
    -d '${body}'")

  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-300}"
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE

    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && { echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2; return 1; }
    [[ -z "$status" && -n "$TASK_RESPONSE" ]] && { echo "Task ${task_id} invalid response: ${TASK_RESPONSE}" >&2; return 1; }

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

_task_result_data() {
  echo "$TASK_RESPONSE" | jq -c '
    .result.data as $data |
    (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))
  '
}

_root_user() {
  kubectl --context "$CTX_A" -n mongo-1 get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d
}

_root_pass() {
  kubectl --context "$CTX_A" -n mongo-1 get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d
}

_mongo_exec() {
  local js="$1"
  local user pass
  user="$(_root_user)"
  pass="$(_root_pass)"
  local rs_hosts="mongodb-0.mongodb.mongo-1.svc.cluster.local:27017,mongodb-1.mongodb.mongo-1.svc.cluster.local:27017,mongodb-2.mongodb.mongo-1.svc.cluster.local:27017"
  kubectl --context "$CTX_A" -n mongo-1 exec mongodb-0 -- \
    mongosh --quiet --norc \
      --host "rs0/${rs_hosts}" \
      --username="$user" \
      --password="$pass" \
      --authenticationDatabase "admin" \
      "admin" \
      --eval "$js"
}

_mongo_exec_as() {
  local auth_db="$1"
  local username="$2"
  local password="$3"
  local js="$4"
  local rs_hosts="mongodb-0.mongodb.mongo-1.svc.cluster.local:27017,mongodb-1.mongodb.mongo-1.svc.cluster.local:27017,mongodb-2.mongodb.mongo-1.svc.cluster.local:27017"

  kubectl --context "$CTX_A" -n mongo-1 exec mongodb-0 -- \
    mongosh --quiet --norc \
      --host "rs0/${rs_hosts}" \
      --username="$username" \
      --password="$password" \
      --authenticationDatabase="$auth_db" \
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

  http_post "${AQSH_URL}/tasks/${path}" "$payload"
  assert_equal "$HTTP_CODE" "202"

  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [ -n "$task_id" ]
  wait_for_task "$AQSH_URL" "$task_id"
}

_submit_task_allow_failure() {
  local path="$1"
  local payload="$2"
  local task_id

  http_post "${AQSH_URL}/tasks/${path}" "$payload"
  assert_equal "$HTTP_CODE" "202"

  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [ -n "$task_id" ]
  wait_for_task "$AQSH_URL" "$task_id" || true
}

# --- Tests ---

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

  http_post "${AQSH_URL}/tasks/delete-account" "$payload"
  assert_equal "$HTTP_CODE" "202"

  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [ -n "$task_id" ]
  wait_for_task "$AQSH_URL" "$task_id" || true

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

  _mongo_exec "db.getSiblingDB('admin').getCollection('run_account_policies').updateMany({username:{\$in:['qa_partial_1', 'qa_partial_2']}, auth_db:'admin'}, {\$set:{expires_at:'2000-01-01T00:00:00Z', status:'ACTIVE'}});"

  _mongo_exec "db.getSiblingDB('admin').dropUser('qa_partial_1');"

  local reconcile_payload
  reconcile_payload=$(jq -nc '{namespace:"mongo-1"}')
  _submit_task "reconcile-expiry" "$reconcile_payload"

  local result status processed
  result="$(_task_result_data)"
  status=$(echo "$result" | jq -r '.status')
  [ "$status" = "OK" ]

  processed=$(echo "$result" | jq -r '.processed // 0')
  [ "$processed" -ge 2 ]

  local user_exists
  user_exists=$(_mongo_exec "const u=db.getSiblingDB('admin').getUser('qa_partial_2'); print(u ? 'yes' : 'no');" | tail -1)
  [ "$user_exists" = "no" ]

  local policy_status
  policy_status=$(_mongo_exec "const d=db.getSiblingDB('admin').getCollection('run_account_policies').findOne({username:'qa_partial_1', auth_db:'admin'}); print(d ? d.status : 'missing');" | tail -1)
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
  [ "$reason_code" = "NOT_FOUND" ] || [ "$reason_code" = "ACCOUNT_NOT_FOUND" ] || [ "$reason_code" = "OPERATION_FAILED" ]
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
  [ "$reason_code" = "NOT_FOUND" ] || [ "$reason_code" = "ACCOUNT_NOT_FOUND" ] || [ "$reason_code" = "OPERATION_FAILED" ]
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
  [ "$reason_code" = "NOT_FOUND" ] || [ "$reason_code" = "ACCOUNT_NOT_FOUND" ] || [ "$reason_code" = "OPERATION_FAILED" ]
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
