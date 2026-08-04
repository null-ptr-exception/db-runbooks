#!/usr/bin/env bats
# =============================================================================
# Integration tests for the MongoDB MQL gateway task API
# (mql/read, mql/write) — see docs/mongodb/mql.md.
#
# Self-contained, own throwaway 1-replica RS in namespace "mongo-mql" (same
# fixture shape as ops.bats — a single member still elects itself PRIMARY,
# which is all these tasks need). recovery_resolve_sts_name/
# recovery_resolve_credentials (the auto-detect chain mql/read and mql/write
# reuse unchanged) already have their own dedicated Bitnami-vs-official
# coverage in recovery_autodetect*.bats; this file uses the same
# conventional MONGO_ROOT_USER/MONGO_ROOT_PASS fixture ops.bats/profiler.bats
# use, since re-proving that detection logic here would test code this
# feature doesn't touch, not the new mql dispatch logic itself.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  PNS="mongo-mql"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=2h)
  export CTX_A CTX_B NS PNS AQSH_URL TEST_POD TOKEN

  local ctx="$CTX_A"

  kubectl --context "$ctx" create namespace "$PNS" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  kubectl --context "$ctx" -n "$PNS" apply -f - <<RB_EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: aqsh-mongo-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aqsh-mongo-manager
subjects:
  - kind: ServiceAccount
    name: kube-auth-proxy
    namespace: mongo-core
RB_EOF

  kubectl --context "$ctx" -n "$PNS" apply -f - <<STS_EOF
apiVersion: v1
kind: Secret
metadata:
  name: mongodb-credentials
  namespace: ${PNS}
stringData:
  MONGO_ROOT_USER: "mongoadmin"
  MONGO_ROOT_PASS: "testpass123"
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: ${PNS}
spec:
  replicas: 1
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
---
apiVersion: v1
kind: Service
metadata:
  name: mongodb
  namespace: ${PNS}
spec:
  clusterIP: None
  selector:
    app: mongodb
  ports:
    - port: 27017
      targetPort: 27017
STS_EOF

  echo "Waiting for RS rollout in ${PNS}..."
  kubectl --context "$ctx" -n "$PNS" rollout status statefulset/mongodb --timeout=300s

  kubectl --context "$ctx" -n "$PNS" wait pod mongodb-0 --for=condition=Ready --timeout=120s
  kubectl --context "$ctx" -n "$PNS" exec mongodb-0 -- mongosh --quiet --norc \
    "mongodb://localhost:27017/admin" --eval "
      try {
        var r = rs.initiate({_id:'rs0', members:[{_id:0,host:'mongodb-0.mongodb.${PNS}.svc.cluster.local:27017'}]});
        print('RS initiate: ' + JSON.stringify(r));
      } catch(e) {
        if (e.codeName === 'AlreadyInitialized') { print('RS already initialized'); }
        else { print('RS init error: ' + e.message); quit(1); }
      }
    " || {
    echo "RS initiate failed" >&2
    return 1
  }
  sleep 8

  local mongo_user mongo_pass
  { IFS= read -r mongo_user; IFS= read -r mongo_pass; } < <(_mongo_creds "$PNS" "$ctx")
  local user_elapsed=0 user_ready=false
  while ((user_elapsed < 60)); do
    if kubectl --context "$ctx" -n "$PNS" exec mongodb-0 -- mongosh --quiet --norc \
      "mongodb://localhost:27017/admin" --eval "
        try {
          db.getSiblingDB('admin').createUser({user:'${mongo_user}', pwd:'${mongo_pass}', roles:[{role:'root',db:'admin'}]});
          print('root user created');
        } catch(e) {
          if (/already exists/.test(e.message)) { print('root user exists'); }
          else { throw e; }
        }" >/dev/null 2>&1; then
      user_ready=true
      break
    fi
    sleep 5
    user_elapsed=$((user_elapsed + 5))
  done
  if [[ "$user_ready" != true ]]; then
    echo "Failed to create/verify root user in ${PNS} after 60s" >&2
    return 1
  fi

  # Seed data for read/write tests.
  _mongo_eval_pod mongodb-0 "db.getSiblingDB('test').widgets.insertMany([{name:'a',qty:1},{name:'b',qty:2},{name:'c',qty:2}])" "$ctx" >/dev/null
}

teardown_file() {
  kubectl --context "kind-cluster-a" delete namespace "mongo-mql" --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

# ---------------------------------------------------------------------------
# Helpers (same pattern as ops.bats)
# ---------------------------------------------------------------------------

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

wait_for_task_any() {
  local base_url="$1" task_id="$2" max_wait="${3:-300}"
  local elapsed=0 status
  while ((elapsed < max_wait)); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE
    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    if [[ "$status" == "completed" || "$status" == "failed" ]]; then
      TASK_STATUS="$status"
      export TASK_STATUS
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "Task ${task_id} still not terminal after ${max_wait}s (status: ${status})" >&2
  return 1
}

# family: "read" or "write" — POSTs to /tasks/mql%2F<family> with a body
# built by jq (so filter/update/document(s) — themselves JSON-as-a-string
# task inputs — are always correctly double-encoded, never hand-escaped).
run_mql_task() {
  local family="$1" body="$2" max_wait="${3:-120}"
  http_post "${AQSH_URL}/tasks/mql%2F${family}" "$body"
  [[ "$HTTP_CODE" == "202" ]] || { echo "submit mql/${family} got HTTP ${HTTP_CODE}: ${HTTP_BODY}" >&2; return 1; }
  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task_any "$AQSH_URL" "$task_id" "$max_wait" || return 1
  RESULT_DATA=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  export RESULT_DATA
}

_mongo_creds() {
  local namespace="$1" ctx="${2:-$CTX_A}"
  local user pass
  user=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  pass=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)
  printf '%s\n%s\n' "$user" "$pass"
}

_mongo_eval_pod() {
  local pod="$1" js="$2" ctx="${3:-$CTX_A}"
  local user pass
  { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds "$PNS" "$ctx")
  kubectl --context "$ctx" -n "$PNS" exec "$pod" -- mongosh --quiet --norc \
    "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=5000" \
    --eval "$js" 2>/dev/null | tail -1 | tr -d '\r'
}

# ── mql/read ─────────────────────────────────────────────────────────────────

@test "mql/read find returns matching documents" {
  local body
  body=$(jq -nc --arg ns "$PNS" --arg filter '{"qty":2}' \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"find", filter:$filter}')
  run_mql_task "read" "$body"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "QUERY_OK"
  local count
  count=$(echo "$RESULT_DATA" | jq '.result | length')
  assert_equal "$count" "2"
}

@test "mql/read count returns a count" {
  local body
  body=$(jq -nc --arg ns "$PNS" \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"count"}')
  run_mql_task "read" "$body"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.result.count')" "3"
}

@test "mql/read aggregate runs a pipeline" {
  local body
  body=$(jq -nc --arg ns "$PNS" --arg pipeline '[{"$group":{"_id":"$qty","n":{"$sum":1}}},{"$sort":{"_id":1}}]' \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"aggregate", pipeline:$pipeline}')
  run_mql_task "read" "$body"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.result[0]._id')" "1"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.result[1].n')" "2"
}

@test "mql/read distinct returns unique values" {
  local body
  body=$(jq -nc --arg ns "$PNS" \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"distinct", distinct_field:"qty"}')
  run_mql_task "read" "$body"
  assert_equal "$TASK_STATUS" "completed"
  local sorted
  sorted=$(echo "$RESULT_DATA" | jq -c '.result.values | sort')
  assert_equal "$sorted" "[1,2]"
}

@test "mql/read distinct without distinct_field is rejected" {
  local body
  body=$(jq -nc --arg ns "$PNS" \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"distinct"}')
  run_mql_task "read" "$body"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"
}

@test "mql/read refuses the admin database" {
  local body
  body=$(jq -nc --arg ns "$PNS" \
    '{namespace:$ns, database:"admin", collection:"system.users", operation:"find"}')
  run_mql_task "read" "$body"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "PROTECTED_DATABASE"
}

@test "mql/read refuses a system.* collection even in a non-system database" {
  local body
  body=$(jq -nc --arg ns "$PNS" \
    '{namespace:$ns, database:"test", collection:"system.foo", operation:"find"}')
  run_mql_task "read" "$body"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"
}

# ── mql/write gating ─────────────────────────────────────────────────────────

@test "mql/write rejects dry_run=true with confirm=true" {
  local body
  body=$(jq -nc --arg ns "$PNS" --arg doc '{"name":"x"}' \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"insert_one", document:$doc, dry_run:"true", confirm:"true"}')
  run_mql_task "write" "$body"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"
}

@test "mql/write rejects dry_run=false without confirm" {
  local body
  body=$(jq -nc --arg ns "$PNS" --arg doc '{"name":"x"}' \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"insert_one", document:$doc, dry_run:"false"}')
  run_mql_task "write" "$body"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"
}

@test "mql/write insert_many rejects an empty documents array" {
  local body
  body=$(jq -nc --arg ns "$PNS" --arg docs '[]' \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"insert_many", documents:$docs}')
  run_mql_task "write" "$body"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"
}

@test "mql/write refuses the local database" {
  local body
  body=$(jq -nc --arg ns "$PNS" --arg filter '{}' \
    '{namespace:$ns, database:"local", collection:"startup_log", operation:"delete_many", filter:$filter}')
  run_mql_task "write" "$body"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "PROTECTED_DATABASE"
}

# ── mql/write execution ──────────────────────────────────────────────────────

@test "mql/write insert_one previews then inserts, verified by mql/read" {
  local body
  body=$(jq -nc --arg ns "$PNS" --arg doc '{"name":"inserted-one","qty":9}' \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"insert_one", document:$doc}')
  run_mql_task "write" "$body"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "DRY_RUN_READY"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.preview.would_insert.name')" "inserted-one"

  body=$(jq -nc --arg ns "$PNS" --arg doc '{"name":"inserted-one","qty":9}' \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"insert_one", document:$doc, dry_run:"false", confirm:"true"}')
  run_mql_task "write" "$body"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "WRITE_OK"
  [[ "$(echo "$RESULT_DATA" | jq -r '.result.insertedId')" != "null" ]]

  body=$(jq -nc --arg ns "$PNS" --arg filter '{"name":"inserted-one"}' \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"count", filter:$filter}')
  run_mql_task "read" "$body"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.result.count')" "1"
}

@test "mql/write update_one previews matched_count then updates, verified by mql/read" {
  local body
  body=$(jq -nc --arg ns "$PNS" --arg filter '{"name":"a"}' --arg update '{"$set":{"qty":100}}' \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"update_one", filter:$filter, update:$update}')
  run_mql_task "write" "$body"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "DRY_RUN_READY"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.preview.matched_count')" "1"

  body=$(jq -nc --arg ns "$PNS" --arg filter '{"name":"a"}' --arg update '{"$set":{"qty":100}}' \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"update_one", filter:$filter, update:$update, dry_run:"false", confirm:"true"}')
  run_mql_task "write" "$body"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "WRITE_OK"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.result.modifiedCount')" "1"

  body=$(jq -nc --arg ns "$PNS" --arg filter '{"name":"a"}' \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"find", filter:$filter}')
  run_mql_task "read" "$body"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.result[0].qty')" "100"
}

@test "mql/write delete_one previews then deletes, verified by mql/read" {
  local body
  body=$(jq -nc --arg ns "$PNS" --arg filter '{"name":"inserted-one"}' \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"delete_one", filter:$filter}')
  run_mql_task "write" "$body"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "DRY_RUN_READY"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.preview.matched_count')" "1"

  body=$(jq -nc --arg ns "$PNS" --arg filter '{"name":"inserted-one"}' \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"delete_one", filter:$filter, dry_run:"false", confirm:"true"}')
  run_mql_task "write" "$body"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "WRITE_OK"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.result.deletedCount')" "1"

  body=$(jq -nc --arg ns "$PNS" --arg filter '{"name":"inserted-one"}' \
    '{namespace:$ns, database:"test", collection:"widgets", operation:"count", filter:$filter}')
  run_mql_task "read" "$body"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.result.count')" "0"
}
