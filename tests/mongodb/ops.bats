#!/usr/bin/env bats
# =============================================================================
# Integration tests for the MongoDB ops gateway task API
# (ops/list, ops/kill) — see docs/mongodb/ops.md.
#
# Self-contained, own throwaway 1-replica RS in namespace "mongo-ops" (a
# single member still elects itself PRIMARY, which is all these tasks need —
# unlike oplog/resize, currentOp/killOp semantics don't depend on member
# count). A single seed document + a `$where: sleep(...)` query is the
# standard MongoDB pattern for producing a controllable, genuinely
# long-running operation to list/kill without any special server flags.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  PNS="mongo-ops"
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

  # Seed one document in the SAME "test" database _start_slow_op queries
  # (_mongo_eval_pod's connection defaults to /admin — target "test"
  # explicitly via getSiblingDB regardless, or the collection is empty from
  # the slow query's point of view and $where never invokes its JS at all).
  _mongo_eval_pod mongodb-0 "db.getSiblingDB('test').seed.insertOne({marker:1})" "$ctx" >/dev/null
}

teardown_file() {
  kubectl --context "kind-cluster-a" delete namespace "mongo-ops" --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

# ---------------------------------------------------------------------------
# Helpers (same pattern as fcv.bats)
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

run_ops_task() {
  local endpoint="$1" body="$2" max_wait="${3:-120}"
  http_post "${AQSH_URL}/tasks/ops%2F${endpoint}" "$body"
  [[ "$HTTP_CODE" == "202" ]] || { echo "submit ${endpoint} got HTTP ${HTTP_CODE}: ${HTTP_BODY}" >&2; return 1; }
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

# Spawns a genuinely long-running operation in the background (the standard
# MongoDB $where-sleep pattern) — the query itself keeps running server-side
# for ${1} seconds regardless of this bash process. Logs to a per-test
# tmpfile so failures are diagnosable. Does NOT return until the op is
# actually visible in currentOp: `kubectl exec` + mongosh startup + auth is
# slow and variable enough (unlike a local mongosh call) that a fixed short
# sleep is not a reliable settle margin — poll instead of guessing.
_start_slow_op() {
  local sleep_secs="${1:-30}"
  local user pass
  { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds "$PNS" "$CTX_A")
  kubectl --context "$CTX_A" -n "$PNS" exec mongodb-0 -- mongosh --quiet --norc \
    "mongodb://${user}:${pass}@localhost:27017/test?authSource=admin&serverSelectionTimeoutMS=5000" \
    --eval "db.seed.find({\$where:'sleep(${sleep_secs}000); return true;'}).toArray()" \
    >"${BATS_TEST_TMPDIR}/slow_op.log" 2>&1 &
  disown

  local elapsed=0 found=""
  while ((elapsed < 20)); do
    found=$(_mongo_eval_pod mongodb-0 \
      "print(db.currentOp({active:true,ns:'test.seed'}).inprog.length)")
    [[ "$found" -gt 0 ]] 2>/dev/null && return 0
    sleep 1
    elapsed=$((elapsed + 1))
  done
  echo "slow op on test.seed never registered in currentOp after 20s" >&2
  cat "${BATS_TEST_TMPDIR}/slow_op.log" >&2
  return 1
}

# ── ops/list ─────────────────────────────────────────────────────────────────

@test "ops/list reports an active long-running operation with rich fields" {
  _start_slow_op 30

  run_ops_task "list" "{\"namespace\":\"${PNS}\"}"
  assert_equal "$TASK_STATUS" "completed"

  local match
  match=$(echo "$RESULT_DATA" | jq -c '.ops[] | select(.ns == "test.seed")')
  [[ -n "$match" ]] || { echo "no op on test.seed found in: $RESULT_DATA" >&2; false; }

  [[ "$(echo "$match" | jq -r '.op')" != "null" ]]
  [[ "$(echo "$match" | jq -r '.opid')" =~ ^[0-9]+$ ]]
  # secs_running may still be null this early in the op's life (MongoDB
  # doesn't always populate it in the first fraction of a second) — the
  # field being present at all (never a raw BSON Long/object) is what
  # matters here; min_secs_running's actual numeric behavior is proven by
  # the filtering test below instead.
  echo "$match" | jq -e 'has("secs_running")' >/dev/null

  # Best-effort cleanup so it doesn't linger for the rest of the suite.
  local opid
  opid=$(echo "$match" | jq -r '.opid')
  run_ops_task "kill" "{\"namespace\":\"${PNS}\",\"opid\":\"${opid}\",\"dry_run\":\"false\",\"confirm\":\"true\"}" || true
}

@test "ops/list min_secs_running filters out an operation that hasn't run long enough" {
  _start_slow_op 30

  run_ops_task "list" "{\"namespace\":\"${PNS}\",\"min_secs_running\":\"100\"}"
  assert_equal "$TASK_STATUS" "completed"
  local filtered_count
  filtered_count=$(echo "$RESULT_DATA" | jq '[.ops[] | select(.ns == "test.seed")] | length')
  assert_equal "$filtered_count" "0"

  run_ops_task "list" "{\"namespace\":\"${PNS}\",\"min_secs_running\":\"0\"}"
  assert_equal "$TASK_STATUS" "completed"
  local unfiltered_count
  unfiltered_count=$(echo "$RESULT_DATA" | jq '[.ops[] | select(.ns == "test.seed")] | length')
  assert_equal "$unfiltered_count" "1"

  local opid
  opid=$(echo "$RESULT_DATA" | jq -r '.ops[] | select(.ns == "test.seed") | .opid')
  run_ops_task "kill" "{\"namespace\":\"${PNS}\",\"opid\":\"${opid}\",\"dry_run\":\"false\",\"confirm\":\"true\"}" || true
}

# ── ops/kill gating ──────────────────────────────────────────────────────────

@test "ops/kill rejects dry_run=true with confirm=true" {
  run_ops_task "kill" "{\"namespace\":\"${PNS}\",\"opid\":\"1\",\"dry_run\":\"true\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"
}

@test "ops/kill reports OP_NOT_FOUND for an opid that isn't running" {
  run_ops_task "kill" "{\"namespace\":\"${PNS}\",\"opid\":\"999999999\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "OP_NOT_FOUND"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.killed')" "false"
}

# ── ops/kill execution ───────────────────────────────────────────────────────

@test "ops/kill dry_run previews an active operation without killing it" {
  _start_slow_op 30

  local opid
  run_ops_task "list" "{\"namespace\":\"${PNS}\"}"
  opid=$(echo "$RESULT_DATA" | jq -r '.ops[] | select(.ns == "test.seed") | .opid')
  [[ -n "$opid" && "$opid" != "null" ]]

  run_ops_task "kill" "{\"namespace\":\"${PNS}\",\"opid\":\"${opid}\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "DRY_RUN_READY"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.killed')" "false"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.op.opid')" "$opid"

  # Still running — dry-run must not have touched it.
  run_ops_task "list" "{\"namespace\":\"${PNS}\"}"
  local still_there
  still_there=$(echo "$RESULT_DATA" | jq "[.ops[] | select(.opid == ${opid})] | length")
  assert_equal "$still_there" "1"

  run_ops_task "kill" "{\"namespace\":\"${PNS}\",\"opid\":\"${opid}\",\"dry_run\":\"false\",\"confirm\":\"true\"}" || true
}

@test "ops/kill confirmed kills a running operation" {
  _start_slow_op 30

  local opid
  run_ops_task "list" "{\"namespace\":\"${PNS}\"}"
  opid=$(echo "$RESULT_DATA" | jq -r '.ops[] | select(.ns == "test.seed") | .opid')
  [[ -n "$opid" && "$opid" != "null" ]]

  run_ops_task "kill" "{\"namespace\":\"${PNS}\",\"opid\":\"${opid}\",\"dry_run\":\"false\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "OP_KILLED"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.killed')" "true"
}
