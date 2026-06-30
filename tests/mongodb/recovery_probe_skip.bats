#!/usr/bin/env bats
# =============================================================================
# Regression: G4 / G8 must not select a broken or not-Ready pod as probe.
#
# Before the fix _recovery_gate_g4 / _recovery_gate_g8 / _recovery_primary_host
# all iterated pods checking only phase==Running, without skipping the
# recovery target or pods whose Ready condition is False.  When the
# lowest-ordinal pod (mongodb-0) was broken it was selected first as probe,
# exec into its dead mongod failed, and G4 returned OPLOG_QUERY_FAILED.
#
# Fix: all three helpers now prefer Ready==True pods and skip target_pod.
#
# Setup: namespace mongo-probe-skip, 3 members, mongodb-2 has priority=2 so
# it wins the primary election deterministically.  This makes mongodb-0 a
# secondary — a valid wipe target at the lowest ordinal, which is the exact
# position that triggered the original bug (pod list is sorted mongodb-0 first).
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  ANS="mongo-probe-skip"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=1h)
  export CTX_A CTX_B NS ANS AQSH_URL TEST_POD TOKEN

  local ctx="$CTX_A"
  kubectl --context "$ctx" create namespace "$ANS" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  kubectl --context "$ctx" -n "$ANS" create secret generic mongodb-credentials \
    --from-literal=MONGO_ROOT_USER=mongoadmin --from-literal=MONGO_ROOT_PASS=testpass123 \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  kubectl --context "$ctx" -n "$ANS" apply -f - <<'RB_EOF'
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

  kubectl --context "$ctx" -n "$ANS" apply -f - <<STS_EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: ${ANS}
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
          env:
            - name: MONGO_INITDB_ROOT_USERNAME
              valueFrom:
                secretKeyRef:
                  name: mongodb-credentials
                  key: MONGO_ROOT_USER
            - name: MONGO_INITDB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mongodb-credentials
                  key: MONGO_ROOT_PASS
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
  namespace: ${ANS}
spec:
  clusterIP: None
  selector:
    app: mongodb
  ports:
    - port: 27017
      targetPort: 27017
STS_EOF

  kubectl --context "$ctx" -n "$ANS" rollout status statefulset/mongodb --timeout=300s

  # mongodb-2 gets priority=2 → deterministic primary.
  # mongodb-0 (lowest ordinal) becomes secondary — the exact probe-selection
  # position that triggered OPLOG_QUERY_FAILED before the fix.
  kubectl --context "$ctx" -n "$ANS" exec mongodb-0 -- mongosh --quiet --norc \
    "mongodb://localhost:27017/admin" --eval "
      try {
        rs.initiate({_id:'rs0',members:[
          {_id:0,host:'mongodb-0.mongodb.${ANS}.svc.cluster.local:27017',priority:1},
          {_id:1,host:'mongodb-1.mongodb.${ANS}.svc.cluster.local:27017',priority:1},
          {_id:2,host:'mongodb-2.mongodb.${ANS}.svc.cluster.local:27017',priority:2}
        ]});
      } catch(e) {
        if (e.codeName==='AlreadyInitialized') { print('already initialized'); }
        else { throw e; }
      }" || { echo "rs.initiate failed" >&2; return 1; }
  sleep 8
  _wait_for_primary "$ANS" "$ctx" 180

  local user pass elapsed=0
  user=$(kubectl --context "$ctx" -n "$ANS" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  pass=$(kubectl --context "$ctx" -n "$ANS" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)
  while (( elapsed < 60 )); do
    kubectl --context "$ctx" -n "$ANS" exec mongodb-2 -- mongosh --quiet --norc \
      "mongodb://localhost:27017/admin" --eval "
        try {
          db.getSiblingDB('admin').createUser(
            {user:'${user}',pwd:'${pass}',roles:[{role:'root',db:'admin'}]});
        } catch(e) { if (!/already exists/.test(e.message)) throw e; }" \
      >/dev/null 2>&1 && break
    sleep 5; elapsed=$((elapsed+5))
  done

  kubectl --context "$ctx" -n "$ANS" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: mongodb-recovery-config
  namespace: ${ANS}
data:
  wipe-targets: ""
  recovery-version: "0"
EOF
}

teardown_file() {
  kubectl --context "kind-cluster-a" delete namespace "mongo-probe-skip" \
    --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

# ---------------------------------------------------------------------------
kexec() { kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"; }

http_post() {
  local url="$1" body="$2" response
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
    [[ "$status" == "failed"    ]] && { echo "Task failed: $TASK_RESPONSE" >&2; return 1; }
    sleep 5; elapsed=$((elapsed+5))
  done
  echo "Task timed out after ${max_wait}s" >&2; return 1
}

_wait_for_primary() {
  local namespace="$1" ctx="${2:-$CTX_A}" max_wait="${3:-120}" elapsed=0
  while (( elapsed < max_wait )); do
    local pod
    pod=$(kubectl --context "$ctx" -n "$namespace" get pod -l app=mongodb \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -n "$pod" ]] && kubectl --context "$ctx" -n "$namespace" exec "$pod" -- \
      mongosh --quiet --norc \
      "mongodb://localhost:27017/admin?serverSelectionTimeoutMS=2000" \
      --eval "try{var s=rs.status();var p=s.members&&s.members.find(function(m){return m.state===1&&m.health===1;});if(p){quit(0);}quit(1);}catch(e){quit(1);}" \
      >/dev/null 2>&1 && return 0
    sleep 3; elapsed=$((elapsed+3))
  done
  echo "Primary not ready in ${namespace} after ${max_wait}s" >&2; return 1
}

_wait_for_rs_healthy() {
  local namespace="$1" target_pod="$2" ctx="${3:-$CTX_A}" max_wait="${4:-180}"
  local user pass
  user=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  pass=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)
  local probe_pod p
  for p in mongodb-2 mongodb-1 mongodb-0; do
    [[ "$p" != "$target_pod" ]] && { probe_pod="$p"; break; }
  done
  local elapsed=0 state=""
  while (( elapsed < max_wait )); do
    state=$(kubectl --context "$ctx" -n "$namespace" exec "$probe_pod" -- \
      mongosh --quiet --norc \
      "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=5000" \
      --eval "try{var m=rs.status().members.filter(function(x){return x.name.indexOf('${target_pod}')!==-1;})[0];print(m?m.stateStr+','+m.health:'NONE,0');}catch(e){print('ERR,0');}" \
      2>/dev/null | tail -1 | tr -d '\r') || state="ERR,0"
    [[ "$state" == "SECONDARY,1" || "$state" == "PRIMARY,1" ]] && return 0
    sleep 5; elapsed=$((elapsed+5))
  done
  echo "${target_pod} not healthy after ${max_wait}s (last: ${state})" >&2; return 1
}

# ---------------------------------------------------------------------------

@test "G4 and G8 skip a not-Ready lowest-ordinal target pod when selecting probe" {
  # mongodb-0 is the lowest-ordinal secondary — the first pod returned by the
  # label-selector list. Before the fix all three helpers (_recovery_primary_host,
  # _recovery_gate_g4, _recovery_gate_g8) used phase==Running only, so a broken
  # mongodb-0 was selected as probe and the oplog query failed with
  # OPLOG_QUERY_FAILED. The fix prefers Ready==True pods and skips target_pod.

  local target="mongodb-0"
  _wait_for_rs_healthy "$ANS" "$target" "$CTX_A" 120

  local target_uid_before
  target_uid_before=$(kubectl --context "$CTX_A" -n "$ANS" \
    get pod "$target" -o jsonpath='{.metadata.uid}')

  # Break mongodb-0: kill mongod and corrupt WiredTiger so it stays not-Ready
  kubectl --context "$CTX_A" -n "$ANS" exec "$target" -- \
    bash -c "kill -9 \$(pidof mongod 2>/dev/null) 2>/dev/null; \
             printf 'CORRUPTED' > /data/db/WiredTiger.wt; \
             printf 'CORRUPTED' > /data/db/WiredTiger" 2>/dev/null || true

  local elapsed=0 pod_ready
  while (( elapsed < 90 )); do
    pod_ready=$(kubectl --context "$CTX_A" -n "$ANS" get pod "$target" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [[ "$pod_ready" != "True" ]] && break
    sleep 3; elapsed=$((elapsed+3))
  done
  assert_equal "$pod_ready" "False"
  echo "Confirmed ${target} is not-Ready; calling recovery/recover" >&2

  http_post "${AQSH_URL}/tasks/recovery%2Frecover" \
    "{\"namespace\":\"${ANS}\",\"target_pod\":\"${target}\",\"wait_timeout\":\"300\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 480

  local result reached
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  reached=$(echo "$result" | jq -r '.reached_running // empty')

  # Primary assertion: recovery must complete — G4 must have used a healthy
  # probe (mongodb-1 or mongodb-2), not the broken target mongodb-0
  assert_equal "$reached" "true"

  local target_uid_after
  target_uid_after=$(kubectl --context "$CTX_A" -n "$ANS" \
    get pod "$target" -o jsonpath='{.metadata.uid}')
  [ "$target_uid_after" != "$target_uid_before" ]

  kubectl --context "$CTX_A" -n "$ANS" \
    wait pod "$target" --for=condition=Ready --timeout=180s >/dev/null 2>&1 || true
  _wait_for_rs_healthy "$ANS" "$target" "$CTX_A" 180
}
