#!/usr/bin/env bats
# =============================================================================
# Integration tests for the MongoDB recovery task API.
# Requires a deployed MongoDB RS cluster in mongo-1 namespace (3 replicas).
# These tests verify the task endpoints accept requests, execute, and return
# structured results.
#
# The suite's setup_suite.bash deploys mongo-1 as a single-replica standalone
# via helmfile. This setup_file upgrades it to a 3-replica RS, creates the root
# user, and patches the StatefulSet with the recovery init container.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"

  # Resolve test-client pod on cluster-b
  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  # Long-lived token: this file runs 2 full recovers + initial-sync waits
  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=2h)

  export CTX_A CTX_B NS AQSH_URL TEST_POD TOKEN

  local ctx="$CTX_A"

  # Upgrade to 3-replica RS: apply RS-mode StatefulSet inline.
  # mongo-1.yaml stays as single-replica standalone for the normal deploy.sh path;
  # recovery integration tests need a full RS to exercise G3/G7/replSetSyncFrom.
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

  echo "Waiting for 3-replica RS rollout in mongo-1..."
  kubectl --context "$ctx" -n mongo-1 \
    rollout status statefulset/mongodb --timeout=300s

  # Initialize replica set (member 0 has priority 2 → deterministic primary)
  _init_mongodb_rs "mongo-1" "$ctx" 3
  _wait_for_mongodb_primary "mongo-1" "$ctx" 180

  # Ensure the root user from mongodb-credentials actually exists in MongoDB.
  # Auth is not enforced here, but the recovery gates always authenticate and
  # MongoDB rejects auth for nonexistent users even with authorization off.
  # (It usually already exists: the standalone mongo-1.yaml entrypoint created
  # it on mongodb-0's PVC — do not rely on that accident.)
  local mongo_user mongo_pass
  mongo_user=$(kubectl --context "$ctx" -n mongo-1 get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  mongo_pass=$(kubectl --context "$ctx" -n mongo-1 get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)
  local user_elapsed=0 user_ready=false
  while (( user_elapsed < 60 )); do
    # createUser must run on the primary; retry until the election settles.
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
  if [[ "$user_ready" != true ]]; then
    echo "Failed to create/verify root user in mongo-1 after 60s" >&2
    return 1
  fi

  # Apply the recovery ConfigMap + data-recovery init container via the
  # canonical setup script — single source of truth shared with
  # docs/mongodb/recovery.md's One-Time Setup section.
  "${BATS_TEST_DIRNAME}/../../aqsh-tasks/scripts/mongodb/recovery/setup-data-recovery.sh" \
    --context "$ctx" --namespace mongo-1 --sts mongodb --profile standard

  echo "Waiting for MongoDB to stabilise after init-container patch..."
  kubectl --context "$ctx" -n mongo-1 \
    rollout status statefulset/mongodb --timeout=300s || true
  _wait_for_mongodb_primary "mongo-1" "$ctx" 120
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

teardown_file() {
  # Revert all setup_file STS mutations so other test files see a clean RS.
  # Do NOT delete the namespace — setup_suite owns that lifecycle.
  local ctx="kind-cluster-a"

  # Remove init container and recovery-config volume added by setup_file.
  # Use JSON patch to target by name so index doesn't matter.
  local ic_idx vol_idx
  ic_idx=$(kubectl --context "$ctx" -n mongo-1 get statefulset mongodb \
    -o jsonpath='{range .spec.template.spec.initContainers[*]}{.name}{"\n"}{end}' 2>/dev/null \
    | grep -n '^data-recovery$' | cut -d: -f1)
  if [[ -n "$ic_idx" ]]; then
    kubectl --context "$ctx" -n mongo-1 patch statefulset mongodb --type=json \
      -p "[{\"op\":\"remove\",\"path\":\"/spec/template/spec/initContainers/$((ic_idx-1))\"}]" \
      2>/dev/null || true
  fi
  vol_idx=$(kubectl --context "$ctx" -n mongo-1 get statefulset mongodb \
    -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' 2>/dev/null \
    | grep -n '^recovery-config-vol$' | cut -d: -f1)
  if [[ -n "$vol_idx" ]]; then
    kubectl --context "$ctx" -n mongo-1 patch statefulset mongodb --type=json \
      -p "[{\"op\":\"remove\",\"path\":\"/spec/template/spec/volumes/$((vol_idx-1))\"}]" \
      2>/dev/null || true
  fi

  # Reset partition to 0 but keep replicas=3 so the RS stays functional.
  kubectl --context "$ctx" -n mongo-1 \
    patch statefulset mongodb --type=merge -p \
    '{"spec":{"replicas":3,"updateStrategy":{"rollingUpdate":{"partition":0}}}}' \
    2>/dev/null || true

  kubectl --context "$ctx" -n mongo-1 \
    delete configmap mongodb-recovery-config --ignore-not-found 2>/dev/null || true

  # Wait for all pods to be ready so subsequent test files see a healthy RS.
  kubectl --context "$ctx" -n mongo-1 \
    rollout status statefulset/mongodb --timeout=120s 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helpers (same pattern as mongodb.bats / account_lifecycle.bats)
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

wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-540}"
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

# ---------------------------------------------------------------------------
# _init_mongodb_rs <namespace> [context] [replicas]
# Initializes a MongoDB replica set named rs0 using rs.initiate().
# Member 0 gets priority 2 for deterministic primary placement.
# ---------------------------------------------------------------------------
_init_mongodb_rs() {
  local namespace="$1" ctx="${2:-$CTX_A}" replicas="${3:-3}"
  echo "Initializing MongoDB replica set rs0 in ${namespace} (${replicas} members)..."
  kubectl --context "$ctx" -n "$namespace" wait pod mongodb-0 \
    --for=condition=Ready --timeout=120s || {
    echo "mongodb-0 not ready after 120s" >&2; return 1
  }
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
    " || { echo "RS initiate failed" >&2; return 1; }

  # Ensure mongodb-0 has priority 2 (previous recovery runs may have set all to 1).
  kubectl --context "$ctx" -n "$namespace" exec mongodb-0 -- mongosh --quiet --norc \
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
        }
      } catch(e) { print('Priority reconfig skipped: ' + e.message); }
    " 2>/dev/null || true

  echo "RS initiated — allowing time for primary election..."
  sleep 8
}

# ---------------------------------------------------------------------------
# _wait_for_mongodb_primary <namespace> [context] [max_wait]
# Waits until a MongoDB primary is available (tries without auth, then with).
# ---------------------------------------------------------------------------
_wait_for_mongodb_primary() {
  local namespace="$1" ctx="${2:-$CTX_A}" max_wait="${3:-120}"
  local elapsed=0
  while (( elapsed < max_wait )); do
    local pod
    pod=$(kubectl --context "$ctx" -n "$namespace" get pod -l app=mongodb \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$pod" ]]; then
      local rs_check='try {
        var s = rs.status();
        var p = s.members && s.members.find(function(m){ return m.state===1 && m.health===1; });
        if (p) { quit(0); }
      } catch(e) {}
      var h = db.hello();
      if (h && (h.isWritablePrimary || h.ismaster)) { quit(0); }
      quit(1);'
      if kubectl --context "$ctx" -n "$namespace" exec "$pod" -- mongosh --quiet --norc \
        "mongodb://localhost:27017/admin?serverSelectionTimeoutMS=2000" \
        --eval "$rs_check" >/dev/null 2>&1; then
        return 0
      fi
      local user pass
      user=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
        -o jsonpath='{.data.MONGO_ROOT_USER}' 2>/dev/null | base64 -d || true)
      pass=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
        -o jsonpath='{.data.MONGO_ROOT_PASS}' 2>/dev/null | base64 -d || true)
      if [[ -n "$user" && -n "$pass" ]]; then
        if kubectl --context "$ctx" -n "$namespace" exec "$pod" -- mongosh --quiet --norc \
          "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=2000" \
          --eval "$rs_check" >/dev/null 2>&1; then
          return 0
        fi
      fi
    fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  echo "MongoDB primary not ready in namespace ${namespace} after ${max_wait}s" >&2
  return 1
}

# ---------------------------------------------------------------------------
# _mongo_creds <namespace> [context]
# Echo "user pass" for the mongodb-credentials secret.
# ---------------------------------------------------------------------------
_mongo_creds() {
  # Outputs user on line 1, pass on line 2.  Callers must use:
  #   { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds ns ctx)
  # so passwords containing spaces are handled correctly.
  local namespace="$1" ctx="${2:-$CTX_A}"
  local user pass
  user=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  pass=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)
  printf '%s\n%s\n' "$user" "$pass"
}

# ---------------------------------------------------------------------------
# _stepdown_pod0 <namespace> [context] [stepdown_seconds]
# Force pod-0 to yield PRIMARY and wait until it transitions to SECONDARY.
# rs.stepDown drops the connection — suppress the exit error.
# ---------------------------------------------------------------------------
_stepdown_pod0() {
  local namespace="$1" ctx="${2:-$CTX_A}"
  local stepdown_secs="${3:-120}"
  local user pass
  { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds "$namespace" "$ctx")
  kubectl --context "$ctx" -n "$namespace" exec mongodb-0 -- mongosh --quiet --norc \
    "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin" \
    --eval "rs.stepDown(${stepdown_secs})" 2>/dev/null || true
  # Wait until pod-0 reports itself as non-primary
  local elapsed=0
  while (( elapsed < 60 )); do
    local role
    role=$(kubectl --context "$ctx" -n "$namespace" exec mongodb-0 -- mongosh --quiet --norc \
      "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=3000" \
      --eval "try{var h=db.hello();print((h.isWritablePrimary||h.ismaster)?'PRIMARY':'SECONDARY');}catch(e){print('ERR');}" \
      2>/dev/null | tail -1 | tr -d '\r') || role="ERR"
    [[ "$role" == "SECONDARY" ]] && return 0
    sleep 3; elapsed=$((elapsed + 3))
  done
  echo "_stepdown_pod0: pod-0 did not yield primary within 60s" >&2
  return 1
}

# ---------------------------------------------------------------------------
# _wait_for_pod0_primary <namespace> [context] [max_wait]
# Wait until pod-0 specifically re-elects as primary (priority=2 wins back).
# ---------------------------------------------------------------------------
_wait_for_pod0_primary() {
  local namespace="$1" ctx="${2:-$CTX_A}" max_wait="${3:-120}"
  local user pass
  { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds "$namespace" "$ctx")
  local elapsed=0
  while (( elapsed < max_wait )); do
    local role
    role=$(kubectl --context "$ctx" -n "$namespace" exec mongodb-0 -- mongosh --quiet --norc \
      "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=3000" \
      --eval "try{var h=db.hello();print((h.isWritablePrimary||h.ismaster)?'PRIMARY':'SECONDARY');}catch(e){print('ERR');}" \
      2>/dev/null | tail -1 | tr -d '\r') || role="ERR"
    [[ "$role" == "PRIMARY" ]] && return 0
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "_wait_for_pod0_primary: pod-0 did not become primary within ${max_wait}s" >&2
  return 1
}

# ---------------------------------------------------------------------------
# _find_primary_pod <namespace> [context]
# Return the name of the pod that is currently the RS primary.
# ---------------------------------------------------------------------------
_find_primary_pod() {
  local namespace="$1" ctx="${2:-$CTX_A}"
  local user pass
  { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds "$namespace" "$ctx")
  local pod
  for pod in mongodb-0 mongodb-1 mongodb-2; do
    local is_primary
    is_primary=$(kubectl --context "$ctx" -n "$namespace" exec "$pod" -- mongosh --quiet --norc \
      "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=3000" \
      --eval "try{var h=db.hello();print((h.isWritablePrimary||h.ismaster)?'1':'0');}catch(e){print('0');}" \
      2>/dev/null | tail -1 | tr -d '\r') || is_primary="0"
    [[ "$is_primary" == "1" ]] && { echo "$pod"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# _wait_for_rs_healthy <namespace> <target_pod> [context] [max_wait]
# Wait until target_pod appears in rs.status() as SECONDARY,1 or PRIMARY,1.
# Queries from a sibling pod so the check works even while target is restarting.
# ---------------------------------------------------------------------------
_wait_for_rs_healthy() {
  local namespace="$1" target_pod="$2"
  local ctx="${3:-$CTX_A}" max_wait="${4:-180}"
  local user pass
  { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds "$namespace" "$ctx")
  local probe_pod
  for p in mongodb-0 mongodb-1 mongodb-2; do
    [[ "$p" != "$target_pod" ]] && { probe_pod="$p"; break; }
  done
  local elapsed=0 state=""
  while (( elapsed < max_wait )); do
    state=$(kubectl --context "$ctx" -n "$namespace" exec "$probe_pod" -- mongosh --quiet --norc \
      "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=5000" \
      --eval "try{var m=rs.status().members.filter(function(x){return x.name.indexOf('${target_pod}')!==-1;})[0];print(m?m.stateStr+','+m.health:'NONE,0');}catch(e){print('ERR,0');}" \
      2>/dev/null | tail -1 | tr -d '\r') || state="ERR,0"
    echo "_wait_for_rs_healthy: ${target_pod} state=${state} elapsed=${elapsed}s" >&2
    [[ "$state" == "SECONDARY,1" || "$state" == "PRIMARY,1" ]] && return 0
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "_wait_for_rs_healthy: ${target_pod} did not become healthy within ${max_wait}s (last: ${state})" >&2
  return 1
}

# ── RS bootstrap idempotency: setup_file's own operations must not crash ────
#
# setup_file already runs rs.initiate() and createUser against mongo-1 on every
# load, but a failure there was previously silent (no return code checked).
# These tests pin down that re-running those two operations against state
# that's already initialised is safe and observable, instead of relying on
# setup_file's bootstrap succeeding by accident.

@test "rs.initiate() on an already-initialised RS in mongo-1 does not error" {
  _init_mongodb_rs "mongo-1" "$CTX_A" 3
}

@test "createUser on an existing root user in mongo-1 does not crash deploy" {
  local mongo_user mongo_pass
  { IFS= read -r mongo_user; IFS= read -r mongo_pass; } < <(_mongo_creds "mongo-1" "$CTX_A")

  # createUser must run on the primary. The previous test's _init_mongodb_rs
  # may have just force-reconfigured priorities (if a prior recovery run left
  # them desynced), which can briefly cost mongodb-0 its primary status while
  # the election resettles — wait for it to win back before the one-shot check.
  _wait_for_pod0_primary "mongo-1" "$CTX_A" 30

  local out
  out=$(kubectl --context "$CTX_A" -n mongo-1 exec mongodb-0 -- mongosh --quiet --norc \
    "mongodb://localhost:27017/admin" --eval "
      try {
        db.getSiblingDB('admin').createUser({
          user:'${mongo_user}',pwd:'${mongo_pass}',roles:[{role:'root',db:'admin'}]});
        print('created');
      } catch(e) {
        if (/already exists/.test(e.message)) { print('exists'); } else { throw e; }
      }" 2>/dev/null | tail -1 | tr -d '\r')
  echo "createUser result: $out" >&2
  [[ "$out" == "exists" || "$out" == "created" ]]
}

# ── recovery/status ───────────────────────────────────────────────────────────

@test "recovery/status returns 202 and completes successfully" {
  http_post "${AQSH_URL}/tasks/recovery%2Fstatus" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"
}

@test "recovery/status result includes STS and CM fields" {
  http_post "${AQSH_URL}/tasks/recovery%2Fstatus" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local sts cm_found pods
  sts=$(echo "$result" | jq -r '.sts // empty')
  cm_found=$(echo "$result" | jq -r '.configmap_found // empty')
  pods=$(echo "$result" | jq -r '.pods // empty')

  assert_equal "$sts" "mongodb"
  assert_equal "$cm_found" "true"
  [ -n "$pods" ]
}

@test "recovery/status shows 3 pods with phase info" {
  http_post "${AQSH_URL}/tasks/recovery%2Fstatus" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local pod_count
  pod_count=$(echo "$result" | jq '[.pods[]] | length' 2>/dev/null || echo "0")
  [ "$pod_count" -eq 3 ]
}

# ── recovery/pre-check ────────────────────────────────────────────────────────

@test "recovery/pre-check returns 202 for a secondary pod" {
  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"
}

@test "recovery/pre-check result contains 8 gates" {
  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local gate_count
  gate_count=$(echo "$result" | jq '[.gates[] | select(.gate)] | length' 2>/dev/null || echo "0")
  [ "$gate_count" -ge 8 ]
}

@test "recovery/pre-check G1 reports init container present after STS patch" {
  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g1_pass
  g1_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G1") | .pass' 2>/dev/null || echo "null")
  assert_equal "$g1_pass" "true"
}

@test "recovery/pre-check G2 reports ConfigMap present" {
  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g2_pass
  g2_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G2") | .pass' 2>/dev/null || echo "null")
  assert_equal "$g2_pass" "true"
}

@test "recovery/pre-check G3 reports healthy sync source and primary available" {
  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g3_pass
  g3_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G3") | .pass' 2>/dev/null || echo "null")
  assert_equal "$g3_pass" "true"
}

@test "recovery/pre-check G4 reports oplog window sufficient" {
  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g4_pass
  g4_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G4") | .pass' 2>/dev/null || echo "null")
  # G4 may pass clean or warn with OPLOG_RESIZE_NEEDED (pre-check is read-only
  # and never resizes), but must not be false on a fresh small cluster
  [ "$g4_pass" = "true" ]
}

@test "recovery/pre-check G5 reports data size within limit" {
  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g5_pass
  g5_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G5") | .pass' 2>/dev/null || echo "null")
  assert_equal "$g5_pass" "true"
}

@test "recovery/pre-check G6 reports PVC space sufficient" {
  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g6_pass
  g6_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G6") | .pass' 2>/dev/null || echo "null")
  # G6 may warn if df is unavailable, but must not block
  [ "$g6_pass" = "true" ]
}

# Wrong-profile / data_path-mismatch coverage (data_path was previously a
# task input, so a caller could trigger this on purpose) moved to
# tests/unit/mongodb/recovery.bats's mocked-kubectl G5/G6 path-mismatch
# tests — data_path/mount_path are no longer task inputs (see CLAUDE.md
# "Configuration Layers"), so there's no longer an API-level way to pass a
# mismatched path; the only way for a real deployment to hit this is a
# detection bug, which the live e2e detection tests (recovery_autodetect*
# .bats) already pressure-test as a positive case (data_mb > 0).

@test "recovery/pre-check G7 blocks when target is mongodb-0 (primary)" {
  # mongodb-0 is deterministically primary (priority 2 set in _init_mongodb_rs).
  # G7 checks db.hello().isWritablePrimary regardless of ordinal → TARGET_IS_PRIMARY.
  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-0"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 120 || true  # task completes even with gate failure

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g7_pass g7_code
  g7_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G7") | .pass' 2>/dev/null || echo "null")
  g7_code=$(echo "$result" | jq -r '.gates[] | select(.gate=="G7") | .code' 2>/dev/null || echo "null")
  assert_equal "$g7_pass" "false"
  assert_equal "$g7_code" "TARGET_IS_PRIMARY"
}

@test "recovery/pre-check G7 passes when target is a secondary (mongodb-2)" {
  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g7_pass
  g7_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G7") | .pass' 2>/dev/null || echo "null")
  assert_equal "$g7_pass" "true"
}

# credential_user/credential_user_key task-input override coverage removed:
# they're no longer task inputs (see CLAUDE.md "Configuration Layers"). The
# underlying _mongo_load_credentials direct_user mechanism they exercised is
# still covered — now via detection — by tests/unit/mongodb/recovery-detect
# .bats and the live e2e recovery_autodetect*.bats fixtures (literal-username
# detection paths).

@test "recovery/pre-check G8 reports no RECOVERING members on healthy cluster" {
  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g8_pass g8_warn
  g8_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G8") | .pass' 2>/dev/null || echo "null")
  g8_warn=$(echo "$result" | jq -r '.gates[] | select(.gate=="G8") | .warn' 2>/dev/null || echo "null")
  assert_equal "$g8_pass" "true"
  assert_equal "$g8_warn" "null"  # no warn on healthy cluster
}

# ── recovery/fix-no-primary (diagnose only — safe read-only) ──────────────────

@test "recovery/fix-no-primary diagnose returns 202 and completes" {
  http_post "${AQSH_URL}/tasks/recovery%2Ffix-no-primary" \
    '{"namespace":"mongo-1","level":"diagnose"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"
}

@test "recovery/fix-no-primary diagnose shows PRIMARY_EXISTS for healthy cluster" {
  http_post "${AQSH_URL}/tasks/recovery%2Ffix-no-primary" \
    '{"namespace":"mongo-1","level":"diagnose"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local diagnosis primary_count secondary_count
  diagnosis=$(echo "$result" | jq -r '.diagnosis // empty')
  primary_count=$(echo "$result" | jq -r '.primary_count // 0')
  secondary_count=$(echo "$result" | jq -r '.secondary_count // 0')
  assert_equal "$diagnosis" "PRIMARY_EXISTS"
  [ "$primary_count" -ge 1 ]
  [ "$secondary_count" -ge 2 ]  # 3-member RS has 2 secondaries
}

@test "recovery/fix-no-primary rejects unknown level" {
  # tasks.yaml declares a pattern for `level`, so aqsh must reject this at
  # submission time — anything else (202) is a config regression.
  http_post "${AQSH_URL}/tasks/recovery%2Ffix-no-primary" \
    '{"namespace":"mongo-1","level":"invalid-level"}'
  [ "$HTTP_CODE" != "202" ]
}

# ── recovery/reset (idempotent — safe to run on a clean cluster) ──────────────

@test "recovery/reset clears wipe-target and resets partition" {
  http_post "${AQSH_URL}/tasks/recovery%2Freset" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local wipe_targets
  wipe_targets=$(kubectl --context "$CTX_A" -n mongo-1 \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  assert_equal "$wipe_targets" ""
}

@test "recovery/reset result includes partition and sts fields" {
  http_post "${AQSH_URL}/tasks/recovery%2Freset" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local sts partition
  sts=$(echo "$result" | jq -r '.sts // empty')
  partition=$(echo "$result" | jq -r '.partition // empty')
  assert_equal "$sts" "mongodb"
  assert_equal "$partition" "3"
}

# ── recovery/recover (full end-to-end — wipes a secondary, verifies re-sync) ──

@test "recovery/recover wipes secondary mongodb-2 and it rejoins as healthy SECONDARY" {
  # Capture pre-wipe UID to prove the pod actually restarted
  local before_uid
  before_uid=$(kubectl --context "$CTX_A" -n mongo-1 \
    get pod mongodb-2 -o jsonpath='{.metadata.uid}')

  http_post "${AQSH_URL}/tasks/recovery%2Frecover" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2","wait_timeout":"300"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 540

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')

  # Orchestrator reports success
  local reached
  reached=$(echo "$result" | jq -r '.reached_running // empty')
  assert_equal "$reached" "true"

  # sync_source_set is timing-dependent on a freshly wiped member: the gates'
  # credentials only authenticate once initial sync has cloned admin.system.users,
  # so replSetSyncFrom usually fails (false) unless the tiny dataset syncs within
  # the retry window. Both outcomes are valid; recovery success must not depend on it.
  local sync_src_set
  sync_src_set=$(echo "$result" | jq -r 'if has("sync_source_set") then (.sync_source_set | tostring) else "MISSING" end')
  [ "$sync_src_set" != "MISSING" ]
  [[ "$sync_src_set" == "true" || "$sync_src_set" == "false" ]]

  # Pod was genuinely recreated (UID changed)
  local after_uid
  after_uid=$(kubectl --context "$CTX_A" -n mongo-1 \
    get pod mongodb-2 -o jsonpath='{.metadata.uid}')
  [ "$before_uid" != "$after_uid" ]

  # wipe-targets cleared by reset
  local wipe_targets
  wipe_targets=$(kubectl --context "$CTX_A" -n mongo-1 \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  assert_equal "$wipe_targets" ""

  # Wait for mongodb-2 to finish initial sync and rejoin RS
  kubectl --context "$CTX_A" -n mongo-1 wait pod mongodb-2 \
    --for=condition=Ready --timeout=180s >/dev/null 2>&1 || true

  local elapsed=0 state=""
  while (( elapsed < 180 )); do
    state=$(kubectl --context "$CTX_A" -n mongo-1 \
      exec mongodb-0 -- mongosh --quiet --norc \
      "mongodb://localhost:27017/admin" \
      --eval "var m=rs.status().members.filter(function(x){return x.name.indexOf('mongodb-2')!==-1;})[0]; print(m?m.stateStr+','+m.health:'NONE,0');" \
      2>/dev/null | tail -1 | tr -d '\r')
    [[ "$state" == "SECONDARY,1" || "$state" == "PRIMARY,1" ]] && break
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "mongodb-2 final RS state: ${state}"
  [[ "$state" == "SECONDARY,1" || "$state" == "PRIMARY,1" ]]
}

@test "recovery/recover result includes sync_source_set as boolean" {
  # Wait for mongodb-2 to be fully healthy before attempting a second recovery.
  # The previous test wiped mongodb-2; it may still be finishing initial sync.
  _wait_for_rs_healthy "mongo-1" "mongodb-2" "$CTX_A" 180

  http_post "${AQSH_URL}/tasks/recovery%2Frecover" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2","wait_timeout":"300"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 540

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local sync_src_set
  sync_src_set=$(echo "$result" | jq -r 'if has("sync_source_set") then (.sync_source_set | tostring) else "MISSING" end')
  [ "$sync_src_set" != "MISSING" ]
  [[ "$sync_src_set" == "true" || "$sync_src_set" == "false" ]]

  # Timing-dependent (see first recover test): true only if initial sync cloned
  # admin users within the replSetSyncFrom retry window.
  if [[ "$sync_src_set" == "true" ]]; then
    echo "sync_source_set=true — replSetSyncFrom executed successfully on real cluster"
  else
    echo "sync_source_set=false — replSetSyncFrom was retried but failed (non-fatal, recovery still succeeded)"
    local reached
    reached=$(echo "$result" | jq -r '.reached_running // empty')
    assert_equal "$reached" "true"
  fi
}

@test "recovery/status shows no active_recovery after recover" {
  http_post "${AQSH_URL}/tasks/recovery%2Fstatus" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local active_recovery wipe_targets
  # No `// empty` here: jq's // treats boolean false as falsy and would erase it
  active_recovery=$(echo "$result" | jq -r '.active_recovery')
  wipe_targets=$(echo "$result" | jq -r '.wipe_targets // empty')
  assert_equal "$active_recovery" "false"
  assert_equal "$wipe_targets" ""
}

# ── Missing required parameters ───────────────────────────────────────────────

@test "recovery/pre-check rejects request with missing target_pod" {
  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" '{"namespace":"mongo-1"}'
  [ "$HTTP_CODE" != "202" ]
}

@test "recovery/recover accepts request with missing target_pod (auto-detects broken pod)" {
  http_post "${AQSH_URL}/tasks/recovery%2Frecover" '{"namespace":"mongo-1"}'
  [ "$HTTP_CODE" = "202" ]
}

@test "recovery/wipe accepts request with missing target_pod (auto-detects broken pod)" {
  http_post "${AQSH_URL}/tasks/recovery%2Fwipe" '{"namespace":"mongo-1"}'
  [ "$HTTP_CODE" = "202" ]
}

@test "recovery/fix-no-primary rejects request with missing level" {
  http_post "${AQSH_URL}/tasks/recovery%2Ffix-no-primary" '{"namespace":"mongo-1"}'
  [ "$HTTP_CODE" != "202" ]
}

# ── recovery/recover — secondary pod-1 (Bitnami any-secondary scenario) ──────
#
# Complements the existing mongodb-2 test: exercises the same recovery path on
# pod-1 to confirm both non-primary ordinals are supported end-to-end.

@test "recovery/recover wipes secondary mongodb-1 and it rejoins as healthy member" {
  local ctx="$CTX_A"

  local before_uid
  before_uid=$(kubectl --context "$ctx" -n mongo-1 \
    get pod mongodb-1 -o jsonpath='{.metadata.uid}')

  http_post "${AQSH_URL}/tasks/recovery%2Frecover" \
    '{"namespace":"mongo-1","target_pod":"mongodb-1","wait_timeout":"300"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 540

  local result reached
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  reached=$(echo "$result" | jq -r '.reached_running // empty')
  assert_equal "$reached" "true"

  # Pod genuinely recreated
  local after_uid
  after_uid=$(kubectl --context "$ctx" -n mongo-1 \
    get pod mongodb-1 -o jsonpath='{.metadata.uid}')
  [ "$before_uid" != "$after_uid" ]

  # wipe-targets cleared
  local wipe_targets
  wipe_targets=$(kubectl --context "$ctx" -n mongo-1 \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  assert_equal "$wipe_targets" ""

  # Wait for mongodb-1 to rejoin RS
  kubectl --context "$ctx" -n mongo-1 \
    wait pod mongodb-1 --for=condition=Ready --timeout=180s >/dev/null 2>&1 || true
  _wait_for_rs_healthy "mongo-1" "mongodb-1" "$ctx" 180
}

# ── G7: primary detection is ordinal-agnostic (post-reconfig scenario) ────────
#
# Before the G7 fix, the gate short-circuited on non-pod-0 targets ("not pod-0,
# skip"). After the fix it always calls db.hello().isWritablePrimary.
#
# These two tests exercise the scenario where pod-0 has stepped down and another
# pod holds the PRIMARY role — the situation that arises after recovery_fix_reconfig
# resets all member priorities to 1.

@test "G7 blocks with TARGET_IS_PRIMARY when a non-pod-0 pod is the current primary" {
  local ctx="$CTX_A"

  # Force pod-0 to step down; pod-1 or pod-2 will be elected primary.
  _stepdown_pod0 "mongo-1" "$ctx" 120

  local primary_pod
  primary_pod=$(_find_primary_pod "mongo-1" "$ctx") || true
  # If the election hasn't settled yet, give it a few more seconds.
  if [[ -z "$primary_pod" || "$primary_pod" == "mongodb-0" ]]; then
    sleep 10
    primary_pod=$(_find_primary_pod "mongo-1" "$ctx") || true
  fi
  if [[ -z "$primary_pod" || "$primary_pod" == "mongodb-0" ]]; then
    skip "Could not elect a non-pod-0 primary within stepdown window"
  fi
  echo "New primary after stepdown: ${primary_pod}" >&2

  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    "{\"namespace\":\"mongo-1\",\"target_pod\":\"${primary_pod}\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 120 || true

  local result g7_pass g7_code
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  g7_pass=$(echo "$result"  | jq -r '.gates[] | select(.gate=="G7") | .pass' 2>/dev/null || echo "null")
  g7_code=$(echo "$result"  | jq -r '.gates[] | select(.gate=="G7") | .code' 2>/dev/null || echo "null")
  echo "G7 targeting ${primary_pod} (non-pod-0 primary): pass=${g7_pass} code=${g7_code}" >&2
  assert_equal "$g7_pass"  "false"
  assert_equal "$g7_code"  "TARGET_IS_PRIMARY"
}

@test "G7 passes for pod-0 when it is not the current primary (stepped down)" {
  # pod-0 should still be secondary from the previous test's stepdown.
  # G7 must return pass=true: Running but not PRIMARY → safe to wipe.
  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-0"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 120

  local result g7_pass
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  g7_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G7") | .pass' 2>/dev/null || echo "null")
  assert_equal "$g7_pass" "true"
}

# ── recovery/recover — primary pod-0 (Bitnami default primary scenario) ───────
#
# Bitnami MongoDB Helm chart gives pod-0 priority=2, making it the permanent
# primary.  When pod-0 itself is corrupted, the operator must:
#   1. Step it down so another pod wins the election.
#   2. Run recovery/recover on pod-0 while it is secondary (G7 passes).
#   3. Verify pod-0 restarts, re-syncs, and rejoins RS as a healthy member.
#
# After the wipe, pod-0 eventually re-elects as primary (priority=2) once its
# initial sync completes and the stepdown timer expires.

@test "recovery/recover wipes pod-0 (Bitnami primary) after stepdown and it rejoins RS" {
  local ctx="$CTX_A"

  # Wait for pod-0 to reclaim primary after the previous test's stepdown expires.
  # (priority=2 wins back once the stepdown lock expires.)
  _wait_for_pod0_primary "mongo-1" "$ctx" 150
  echo "pod-0 is primary — confirmed pre-condition for primary-recovery test" >&2

  # Run pre-check to confirm G7 currently BLOCKS on pod-0 (it is primary).
  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-0"}'
  local precheck_id
  precheck_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$precheck_id" 120 || true
  local g7_pre_result g7_pre
  g7_pre_result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  g7_pre=$(echo "$g7_pre_result" | jq -r '.gates[] | select(.gate=="G7") | .pass' 2>/dev/null || echo "?")
  echo "G7 before stepdown (pod-0 is primary): ${g7_pre}" >&2
  if [[ "$g7_pre" == "?" ]]; then
    echo "DEBUG task status: $(echo "$TASK_RESPONSE" | jq -r '.status // "?"')" >&2
    echo "DEBUG task data: $(echo "$_precheck_data" | jq -c . 2>/dev/null || echo "${_precheck_data:0:400}")" >&2
  fi
  assert_equal "$g7_pre" "false"

  # Capture pod-0 UID before wipe.
  local before_uid
  before_uid=$(kubectl --context "$ctx" -n mongo-1 \
    get pod mongodb-0 -o jsonpath='{.metadata.uid}')

  # Step down pod-0 so G7 passes, then immediately submit the recovery task.
  # The 120s stepdown window is long enough for G7 to run and the wipe to fire
  # before pod-0 can re-elect (it is down/restarting during the wipe).
  _stepdown_pod0 "mongo-1" "$ctx" 120

  http_post "${AQSH_URL}/tasks/recovery%2Frecover" \
    '{"namespace":"mongo-1","target_pod":"mongodb-0","wait_timeout":"300"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 600

  local result reached
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  reached=$(echo "$result" | jq -r '.reached_running // empty')
  assert_equal "$reached" "true"

  # Pod was genuinely recreated (UID changed — init container fired)
  local after_uid
  after_uid=$(kubectl --context "$ctx" -n mongo-1 \
    get pod mongodb-0 -o jsonpath='{.metadata.uid}')
  [ "$before_uid" != "$after_uid" ]

  # wipe-targets cleared by reset phase
  local wipe_targets
  wipe_targets=$(kubectl --context "$ctx" -n mongo-1 \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  assert_equal "$wipe_targets" ""

  # Wait for pod-0 to finish initial sync and appear healthy in RS.
  # After re-sync, pod-0 will eventually re-elect as primary (priority=2).
  kubectl --context "$ctx" -n mongo-1 \
    wait pod mongodb-0 --for=condition=Ready --timeout=300s >/dev/null 2>&1 || true
  _wait_for_rs_healthy "mongo-1" "mongodb-0" "$ctx" 300
}

# ── recovery/wipe vs recovery/recover: manual split flow ─────────────────────
#
# recovery/wipe only runs gate-mode checks + sets wipe-targets — it does NOT
# auto-reset like recovery/recover does. These tests prove that distinction:
# wipe alone leaves wipe-targets set until an explicit recovery/reset call.

@test "recovery/wipe leaves wipe-targets set until a manual recovery/reset" {
  local ctx="$CTX_A"

  # Pick a non-primary target dynamically — the previous test's stepdown/
  # re-election may not have fully settled back to pod-0 yet.
  local primary_pod target=""
  primary_pod=$(_find_primary_pod "mongo-1" "$ctx") || true
  for p in mongodb-2 mongodb-1 mongodb-0; do
    [[ "$p" != "$primary_pod" ]] && { target="$p"; break; }
  done
  echo "Primary: ${primary_pod}  wipe target: ${target}" >&2

  local before_uid
  before_uid=$(kubectl --context "$ctx" -n mongo-1 \
    get pod "$target" -o jsonpath='{.metadata.uid}')

  http_post "${AQSH_URL}/tasks/recovery%2Fwipe" \
    "{\"namespace\":\"mongo-1\",\"target_pod\":\"${target}\"}"
  assert_equal "$HTTP_CODE" "202"

  local wipe_task_id
  wipe_task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$wipe_task_id" 120

  # wipe.sh does not call reset — wipe-targets must still be set
  local wipe_targets
  wipe_targets=$(kubectl --context "$ctx" -n mongo-1 \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  echo "wipe-targets after wipe (no reset): '${wipe_targets}'" >&2
  assert_equal "$wipe_targets" "$target"

  # Wait for the pod to restart and come back Running
  local elapsed=0
  until [[ "$(kubectl --context "$ctx" -n mongo-1 \
      get pod "$target" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo '')" \
      != "$before_uid" ]]; do
    [[ $elapsed -ge 300 ]] && { echo "Pod did not restart within 300s" >&2; break; }
    sleep 5; elapsed=$((elapsed + 5))
  done
  elapsed=0
  until kubectl --context "$ctx" -n mongo-1 \
      get pod "$target" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; do
    [[ $elapsed -ge 300 ]] && { echo "Pod did not reach Running within 300s" >&2; break; }
    sleep 5; elapsed=$((elapsed + 5))
  done
  local after_uid
  after_uid=$(kubectl --context "$ctx" -n mongo-1 \
    get pod "$target" -o jsonpath='{.metadata.uid}')
  [ "$before_uid" != "$after_uid" ]

  # Explicit reset clears it
  http_post "${AQSH_URL}/tasks/recovery%2Freset" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"
  local reset_task_id
  reset_task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$reset_task_id"

  wipe_targets=$(kubectl --context "$ctx" -n mongo-1 \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  assert_equal "$wipe_targets" ""

  # Leave mongo-1 healthy for any test file that runs after this one
  kubectl --context "$ctx" -n mongo-1 \
    wait pod "$target" --for=condition=Ready --timeout=180s >/dev/null 2>&1 || true
  _wait_for_rs_healthy "mongo-1" "$target" "$ctx" 180
}
