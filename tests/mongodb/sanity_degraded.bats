#!/usr/bin/env bats
# =============================================================================
# e2e: sanity-check against a genuinely degraded replica set.
#
# The healthy-path sanity tests live in mongodb.bats; this file covers the
# degraded branches end-to-end: lose a member (scale 3→2 while rs.conf still
# lists 3), assert sanity reports critical, restore, assert it recovers.
# Self-contained like reconfig.bats: own 3-replica RS setup.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=1h)

  export CTX_A CTX_B NS AQSH_URL TEST_POD TOKEN

  local ctx="$CTX_A"

  # 3-replica RS (same inline STS as reconfig.bats / recovery.bats)
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

  _init_mongodb_rs "mongo-1" "$ctx" 3
  _wait_for_mongodb_primary "mongo-1" "$ctx" 180

  local mongo_user mongo_pass
  { IFS= read -r mongo_user; IFS= read -r mongo_pass; } < <(_mongo_creds "mongo-1" "$ctx")
  local user_elapsed=0 user_ready=false
  while (( user_elapsed < 60 )); do
    if kubectl --context "$ctx" -n mongo-1 exec mongodb-0 -- mongosh --quiet --norc \
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
    sleep 5; user_elapsed=$((user_elapsed + 5))
  done
  [[ "$user_ready" == true ]] || { echo "root user bootstrap failed" >&2; return 1; }
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

teardown_file() {
  # Restore full replica count no matter where a test stopped.
  local ctx="kind-cluster-a"
  kubectl --context "$ctx" -n mongo-1 patch statefulset mongodb --type=merge \
    -p '{"spec":{"replicas":3}}' 2>/dev/null || true
  kubectl --context "$ctx" -n mongo-1 \
    rollout status statefulset/mongodb --timeout=180s 2>/dev/null || true
  _wait_for_mongodb_primary "mongo-1" "$ctx" 120 || true
}

# ── helpers (same pattern as reconfig.bats) ──────────────────────────────────

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
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

# run sanity-check and export SANITY_STATUS / SANITY_FAIL / SANITY_WARN
run_sanity() {
  http_post "${AQSH_URL}/tasks/sanity-check" '{"namespace":"mongo-1"}'
  [[ "$HTTP_CODE" == "202" ]] || { echo "sanity submit got HTTP ${HTTP_CODE}" >&2; return 1; }
  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 300 || return 1
  local data
  data=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  SANITY_STATUS=$(echo "$data" | jq -r '.status // "unknown"')
  SANITY_FAIL=$(echo "$data" | jq -r '.fail // -1')
  SANITY_WARN=$(echo "$data" | jq -r '.warn // -1')
  export SANITY_STATUS SANITY_FAIL SANITY_WARN
}

_init_mongodb_rs() {
  local namespace="$1" ctx="${2:-$CTX_A}" replicas="${3:-3}"
  kubectl --context "$ctx" -n "$namespace" wait pod mongodb-0 \
    --for=condition=Ready --timeout=120s || return 1
  local members="" prio
  for i in $(seq 0 $((replicas - 1))); do
    prio=1; [[ "$i" -eq 0 ]] && prio=2
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
    " || return 1
  sleep 8
}

_wait_for_mongodb_primary() {
  local namespace="$1" ctx="${2:-$CTX_A}" max_wait="${3:-120}"
  local elapsed=0
  while (( elapsed < max_wait )); do
    local pod
    pod=$(kubectl --context "$ctx" -n "$namespace" get pod -l app=mongodb \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$pod" ]]; then
      if kubectl --context "$ctx" -n "$namespace" exec "$pod" -- mongosh --quiet --norc \
        "mongodb://localhost:27017/admin?serverSelectionTimeoutMS=2000" \
        --eval 'var s=rs.status(); if (s.members && s.members.some(function(m){return m.state===1 && m.health===1;})) quit(0); quit(1);' \
        >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 3; elapsed=$((elapsed + 3))
  done
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

_mongo0_eval() {
  local js="$1" ctx="${2:-$CTX_A}"
  local user pass
  { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds "mongo-1" "$ctx")
  kubectl --context "$ctx" -n mongo-1 exec mongodb-0 -- mongosh --quiet --norc \
    "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=5000" \
    --eval "$js" 2>/dev/null | tail -1 | tr -d '\r'
}

# ── tests ────────────────────────────────────────────────────────────────────

@test "sanity-check on a healthy 3-member RS is not critical" {
  run_sanity
  echo "healthy: status=${SANITY_STATUS} warn=${SANITY_WARN} fail=${SANITY_FAIL}" >&2
  assert [ "$SANITY_STATUS" != "critical" ]
  assert_equal "$SANITY_FAIL" "0"
}

@test "sanity-check reports critical while an RS member is down, recovers after restore" {
  local ctx="$CTX_A"

  # ── degrade: lose mongodb-2 while rs.conf still lists 3 members ──────────
  kubectl --context "$ctx" -n mongo-1 patch statefulset mongodb --type=merge \
    -p '{"spec":{"replicas":2}}'
  kubectl --context "$ctx" -n mongo-1 wait pod mongodb-2 --for=delete \
    --timeout=120s || true

  # wait until the survivors actually see the member as unhealthy
  local elapsed=0 down="0"
  while (( elapsed < 90 )); do
    down=$(_mongo0_eval "
      try { print(rs.status().members.filter(function(m){ return m.health !== 1; }).length); }
      catch(e) { print('0'); }")
    [[ "$down" == "1" ]] && break
    sleep 5; elapsed=$((elapsed + 5))
  done
  assert_equal "$down" "1"

  run_sanity
  echo "degraded: status=${SANITY_STATUS} warn=${SANITY_WARN} fail=${SANITY_FAIL}" >&2
  assert_equal "$SANITY_STATUS" "critical"
  assert [ "$SANITY_FAIL" -ge 1 ]

  # ── restore: scale back and wait for the member to rejoin healthily ──────
  kubectl --context "$ctx" -n mongo-1 patch statefulset mongodb --type=merge \
    -p '{"spec":{"replicas":3}}'
  kubectl --context "$ctx" -n mongo-1 rollout status statefulset/mongodb --timeout=300s

  elapsed=0
  local healthy="0"
  while (( elapsed < 180 )); do
    healthy=$(_mongo0_eval "
      try { print(rs.status().members.filter(function(m){ return m.health === 1; }).length); }
      catch(e) { print('0'); }")
    [[ "$healthy" == "3" ]] && break
    sleep 5; elapsed=$((elapsed + 5))
  done
  assert_equal "$healthy" "3"

  run_sanity
  echo "restored: status=${SANITY_STATUS} warn=${SANITY_WARN} fail=${SANITY_FAIL}" >&2
  assert [ "$SANITY_STATUS" != "critical" ]
  assert_equal "$SANITY_FAIL" "0"
}
