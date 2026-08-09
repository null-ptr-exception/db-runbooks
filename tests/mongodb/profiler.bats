#!/usr/bin/env bats
# =============================================================================
# Integration tests for the MongoDB profiler gateway task API
# (profiler/status, profiler/set) — see docs/mongodb/profiler.md.
#
# Self-contained, own throwaway 1-replica RS in namespace "mongo-profiler"
# (a single member still elects itself PRIMARY, which is all this task
# family needs to exercise the default target_pod resolution path).
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  PNS="mongo-profiler"
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
}

teardown_file() {
  kubectl --context "kind-cluster-a" delete namespace "mongo-profiler" --ignore-not-found 2>/dev/null || true
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
  local base_url="$1" task_id="$2" max_wait="${3:-120}"
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

run_profiler_task() {
  local endpoint="$1" body="$2" max_wait="${3:-120}"
  http_post "${AQSH_URL}/tasks/profiler%2F${endpoint}" "$body"
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

# Ground truth: current profiler level observed directly on mongodb-0.
_current_profiler_level() {
  _mongo_eval_pod mongodb-0 "print(db.getProfilingStatus().was)"
}

# ── profiler/status ──────────────────────────────────────────────────────────

@test "profiler/status reports the default level and slowms" {
  run_profiler_task "status" "{\"namespace\":\"${PNS}\"}"
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.level')" "0"
  echo "$RESULT_DATA" | jq -e '.slowms | numbers' >/dev/null
  echo "$RESULT_DATA" | jq -e '.sampleRate | numbers' >/dev/null
}

# ── profiler/set gating ──────────────────────────────────────────────────────

@test "profiler/set default dry_run previews without changing anything" {
  run_profiler_task "set" "{\"namespace\":\"${PNS}\",\"level\":\"1\",\"slowms\":\"50\"}"
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "DRY_RUN_READY"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.changed')" "false"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.requested.level')" "1"
  assert_equal "$(_current_profiler_level)" "0"
}

@test "profiler/set rejects dry_run=true with confirm=true" {
  run_profiler_task "set" "{\"namespace\":\"${PNS}\",\"level\":\"1\",\"dry_run\":\"true\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"
}

# Note: there is no "level outside 0-2" test here — the tasks.yaml pattern
# for `level` (`^[0-2]$`) already rejects it at submission (HTTP 400,
# before the script — and its own belt-and-braces range check — ever
# runs), the same "not worth double-testing a format guard" call fcv.bats
# makes for fcv/set's target_version pattern.

# ── profiler/set execution ───────────────────────────────────────────────────

@test "profiler/set confirmed changes the level" {
  run_profiler_task "set" "{\"namespace\":\"${PNS}\",\"level\":\"1\",\"slowms\":\"50\",\"dry_run\":\"false\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "PROFILER_SET"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.changed')" "true"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.current.level')" "1"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.current.slowms')" "50"
  assert_equal "$(_current_profiler_level)" "1"

  # Restore level 0 so later tests in this file see a clean baseline.
  run_profiler_task "set" "{\"namespace\":\"${PNS}\",\"level\":\"0\",\"dry_run\":\"false\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "completed"
}

@test "profiler/set at the current level completes as ALREADY_AT_TARGET" {
  run_profiler_task "set" "{\"namespace\":\"${PNS}\",\"level\":\"0\",\"dry_run\":\"false\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "ALREADY_AT_TARGET"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.changed')" "false"
  assert_equal "$(_current_profiler_level)" "0"
}

@test "profiler/set level=2 surfaces a high_impact_warning without blocking the preview" {
  run_profiler_task "set" "{\"namespace\":\"${PNS}\",\"level\":\"2\"}"
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "DRY_RUN_READY"
  [[ "$(echo "$RESULT_DATA" | jq -r '.high_impact_warning')" == *"level=2"* ]]
  assert_equal "$(_current_profiler_level)" "0"
}
