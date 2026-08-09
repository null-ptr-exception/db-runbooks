#!/usr/bin/env bats
# =============================================================================
# Integration tests for the MongoDB oplog gateway task API
# (oplog/status, oplog/resize) — see docs/mongodb/oplog.md.
#
# Self-contained, own throwaway 3-replica RS in namespace "mongo-oplog" (same
# inline StatefulSet pattern as fcv.bats/reconfig.bats, applied to a fresh
# namespace instead of the shared mongo-1 so this file never depends on
# what another file in the same bats invocation did to mongo-1 first).
# 3 replicas because oplog/resize's whole point — resizing every current
# member, not just the primary — only means anything with more than one.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  PNS="mongo-oplog"
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

  # Grant aqsh's SA the same ClusterRole within this throwaway namespace —
  # RoleBinding only, no ClusterRole change (resourceNames already cover
  # "mongodb"/"mongodb-credentials" regardless of namespace).
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

  echo "Waiting for 3-replica RS rollout in ${PNS}..."
  kubectl --context "$ctx" -n "$PNS" rollout status statefulset/mongodb --timeout=300s

  _init_mongodb_rs "$PNS" "$ctx" 3
  _wait_for_mongodb_primary "$PNS" "$ctx" 180

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
  kubectl --context "kind-cluster-a" delete namespace "mongo-oplog" --ignore-not-found 2>/dev/null || true
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

run_oplog_task() {
  local endpoint="$1" body="$2" max_wait="${3:-300}"
  http_post "${AQSH_URL}/tasks/oplog%2F${endpoint}" "$body"
  [[ "$HTTP_CODE" == "202" ]] || { echo "submit ${endpoint} got HTTP ${HTTP_CODE}: ${HTTP_BODY}" >&2; return 1; }
  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task_any "$AQSH_URL" "$task_id" "$max_wait" || return 1
  RESULT_DATA=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  export RESULT_DATA
}

_init_mongodb_rs() {
  local namespace="$1" ctx="${2:-$CTX_A}" replicas="${3:-3}"
  echo "Initializing MongoDB replica set rs0 in ${namespace} (${replicas} members)..."
  kubectl --context "$ctx" -n "$namespace" wait pod mongodb-0 \
    --for=condition=Ready --timeout=120s || {
    echo "mongodb-0 not ready after 120s" >&2
    return 1
  }
  local members="" prio
  for i in $(seq 0 $((replicas - 1))); do
    prio=1
    [[ "$i" -eq 0 ]] && prio=2
    members+="{_id:${i},host:'mongodb-${i}.mongodb.${namespace}.svc.cluster.local:27017',priority:${prio}},"
  done
  members="${members%,}"
  kubectl --context "$ctx" -n "$namespace" exec mongodb-0 -- mongosh --quiet --norc \
    "mongodb://localhost:27017/admin" \
    --eval "
      try {
        var r = rs.initiate({_id: 'rs0', members: [${members}]});
        print('RS initiate: ' + JSON.stringify(r));
      } catch(e) {
        if (e.codeName === 'AlreadyInitialized') { print('RS already initialized'); }
        else { print('RS init error: ' + e.message); quit(1); }
      }
    " || {
    echo "RS initiate failed" >&2
    return 1
  }
  echo "RS initiated — allowing time for primary election..."
  sleep 8
}

_wait_for_mongodb_primary() {
  local namespace="$1" ctx="${2:-$CTX_A}" max_wait="${3:-120}"
  local elapsed=0
  while ((elapsed < max_wait)); do
    local pod
    pod=$(kubectl --context "$ctx" -n "$namespace" get pod -l app=mongodb \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$pod" ]]; then
      local rs_check='try {
        var s = rs.status();
        var p = s.members && s.members.find(function(m){ return m.state===1 && m.health===1; });
        if (p) { quit(0); }
      } catch(e) {}
      quit(1);'
      if kubectl --context "$ctx" -n "$namespace" exec "$pod" -- mongosh --quiet --norc \
        "mongodb://localhost:27017/admin?serverSelectionTimeoutMS=2000" \
        --eval "$rs_check" >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo "MongoDB primary not ready in namespace ${namespace} after ${max_wait}s" >&2
  return 1
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

# run a mongosh eval on a specific pod with root credentials; echoes last line.
_mongo_eval_pod() {
  local pod="$1" js="$2" ctx="${3:-$CTX_A}"
  local user pass
  { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds "$PNS" "$ctx")
  kubectl --context "$ctx" -n "$PNS" exec "$pod" -- mongosh --quiet --norc \
    "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=5000" \
    --eval "$js" 2>/dev/null | tail -1 | tr -d '\r'
}

# current logSizeMB as observed directly on a specific pod (ground truth).
_current_oplog_size_mb() {
  local pod="$1"
  _mongo_eval_pod "$pod" "print(Math.round(db.getReplicationInfo().logSizeMB))"
}

# ── oplog/status ─────────────────────────────────────────────────────────────

@test "oplog/status reports every current replica-set member" {
  run_oplog_task "status" "{\"namespace\":\"${PNS}\"}"
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.sts')" "mongodb"
  assert_equal "$(echo "$RESULT_DATA" | jq '.members | length')" "3"
  # Every member has the expected shape and a positive size.
  local i
  for i in 0 1 2; do
    [[ "$(echo "$RESULT_DATA" | jq -r ".members[$i].host")" == mongodb-*."$PNS"* ]]
    [[ "$(echo "$RESULT_DATA" | jq -r ".members[$i].size_mb")" -gt 0 ]]
  done
  # min_window_hours is present and numeric.
  echo "$RESULT_DATA" | jq -e '.min_window_hours | numbers' >/dev/null
}

# ── oplog/resize gating ──────────────────────────────────────────────────────

@test "oplog/resize default dry_run previews without changing anything" {
  local before
  before=$(_current_oplog_size_mb mongodb-0)

  run_oplog_task "resize" "{\"namespace\":\"${PNS}\",\"target_size_mb\":\"2500\"}"
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "DRY_RUN_READY"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.changed')" "false"
  assert_equal "$(echo "$RESULT_DATA" | jq '.members | length')" "3"
  assert_equal "$(_current_oplog_size_mb mongodb-0)" "$before"
}

@test "oplog/resize rejects dry_run=true with confirm=true" {
  run_oplog_task "resize" "{\"namespace\":\"${PNS}\",\"target_size_mb\":\"2500\",\"dry_run\":\"true\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"
}

@test "oplog/resize rejects dry_run=false without confirm" {
  run_oplog_task "resize" "{\"namespace\":\"${PNS}\",\"target_size_mb\":\"2500\",\"dry_run\":\"false\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"
}

# ── oplog/resize execution ───────────────────────────────────────────────────

@test "oplog/resize confirmed resizes every member" {
  run_oplog_task "resize" "{\"namespace\":\"${PNS}\",\"target_size_mb\":\"2500\",\"dry_run\":\"false\",\"confirm\":\"true\"}" 300
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "OPLOG_RESIZED"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.changed')" "true"
  assert_equal "$(echo "$RESULT_DATA" | jq '[.members[].ok] | all')" "true"

  # Ground truth: every member's own logSizeMB, not just the task's own report.
  local pod size
  for pod in mongodb-0 mongodb-1 mongodb-2; do
    size=$(_current_oplog_size_mb "$pod")
    # replSetResizeOplog rounds internally; allow a small tolerance.
    (( size >= 2400 && size <= 2600 )) || {
      echo "member ${pod} logSizeMB=${size}, expected ~2500" >&2
      false
    }
  done
}
