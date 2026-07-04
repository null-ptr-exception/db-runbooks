#!/usr/bin/env bats
# =============================================================================
# Integration tests for the MongoDB reconfig gateway task API
# (reconfig/plan, reconfig/apply, reconfig/force-dr, reconfig/freeze).
#
# Self-contained like recovery.bats: setup_file upgrades mongo-1 to a
# 3-replica RS (member 0 priority 2 → deterministic primary) and ensures the
# root user exists. No recovery init container is needed here.
#
# The force-dr test at the end simulates a site loss by scaling the STS to 1
# replica; it restores the set (replicas + votes) itself, and teardown_file
# double-checks.
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

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=2h)

  export CTX_A CTX_B NS AQSH_URL TEST_POD TOKEN

  local ctx="$CTX_A"

  # Upgrade to a 3-replica RS (same inline STS as recovery.bats).
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

  _init_mongodb_rs "mongo-1" "$ctx" 3
  _wait_for_mongodb_primary "mongo-1" "$ctx" 180

  # Ensure the root user from mongodb-credentials exists (see recovery.bats).
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
  if [[ "$user_ready" != true ]]; then
    echo "Failed to create/verify root user in mongo-1 after 60s" >&2
    return 1
  fi
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

teardown_file() {
  local ctx="kind-cluster-a"

  # Safety net: the force-dr test restores these itself; make sure anyway.
  kubectl --context "$ctx" -n mongo-1 patch statefulset mongodb --type=merge \
    -p '{"spec":{"replicas":3}}' 2>/dev/null || true
  kubectl --context "$ctx" -n mongo-1 patch statefulset mongodb --type=merge \
    -p '{"metadata":{"annotations":{"reconfig.db-runbooks/freeze":null,"reconfig.db-runbooks/freeze-reason":null,"reconfig.db-runbooks/dr-active":null,"reconfig.db-runbooks/dr-incident":null}}}' \
    2>/dev/null || true

  # Remove any zone labels the zone tests added.
  local node
  for node in $(kubectl --context "$ctx" get nodes -o jsonpath='{.items[*].metadata.name}'); do
    kubectl --context "$ctx" label node "$node" topology.kubernetes.io/zone- \
      2>/dev/null || true
  done

  kubectl --context "$ctx" -n mongo-1 delete configmap mongodb-reconfig-audit \
    --ignore-not-found 2>/dev/null || true

  kubectl --context "$ctx" -n mongo-1 \
    rollout status statefulset/mongodb --timeout=180s 2>/dev/null || true

  # Best-effort: restore full voting rights in case the DR test aborted midway.
  local user pass
  { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds "mongo-1" "$ctx")
  kubectl --context "$ctx" -n mongo-1 exec mongodb-0 -- mongosh --quiet --norc \
    "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin" --eval "
      try {
        var cfg = rs.conf(); var dirty = false;
        cfg.members.forEach(function(m){
          var prio = (m.host.indexOf('mongodb-0') !== -1) ? 2 : 1;
          if (m.votes !== 1 || m.priority !== prio) { m.votes = 1; m.priority = prio; dirty = true; }
        });
        if (dirty) { cfg.version++; rs.reconfig(cfg, {force: true}); print('votes restored'); }
      } catch(e) { print('restore skipped: ' + e.message); }
    " 2>/dev/null || true
  _wait_for_mongodb_primary "mongo-1" "$ctx" 120 || true
}

# ---------------------------------------------------------------------------
# Helpers (same pattern as recovery.bats)
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

# wait until the task reaches completed OR failed; exports TASK_STATUS.
# Use for tests that assert on a task's *failure* payload.
wait_for_task_any() {
  local base_url="$1" task_id="$2" max_wait="${3:-300}"
  local elapsed=0 status
  while (( elapsed < max_wait )); do
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

# submit a task body to a reconfig endpoint and wait; exports TASK_STATUS,
# TASK_RESPONSE and RESULT_DATA (the .result.data payload).
run_reconfig_task() {
  local endpoint="$1" body="$2" max_wait="${3:-300}"
  http_post "${AQSH_URL}/tasks/reconfig%2F${endpoint}" "$body"
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
  echo "RS initiated — allowing time for primary election..."
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
    sleep 3; elapsed=$((elapsed + 3))
  done
  echo "MongoDB primary not ready in namespace ${namespace} after ${max_wait}s" >&2
  return 1
}

_mongo_creds() {
  # user on line 1, pass on line 2 — read with two IFS= read -r calls.
  local namespace="$1" ctx="${2:-$CTX_A}"
  local user pass
  user=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  pass=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)
  printf '%s\n%s\n' "$user" "$pass"
}

# run a mongosh eval on mongodb-0 with root credentials; echoes last line.
_mongo0_eval() {
  local js="$1" ctx="${2:-$CTX_A}"
  local user pass
  { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds "mongo-1" "$ctx")
  kubectl --context "$ctx" -n mongo-1 exec mongodb-0 -- mongosh --quiet --norc \
    "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=5000" \
    --eval "$js" 2>/dev/null | tail -1 | tr -d '\r'
}

# ── reconfig/plan ────────────────────────────────────────────────────────────

@test "reconfig/plan returns a pass-level report with a plan_hash for a benign op" {
  run_reconfig_task "plan" \
    '{"namespace":"mongo-1","ops_json":"[{\"action\":\"set_priority\",\"member\":\"mongodb-1\",\"priority\":1}]"}'
  assert_equal "$TASK_STATUS" "completed"

  local risk hash resolution
  risk=$(echo "$RESULT_DATA" | jq -r '.risk_level')
  hash=$(echo "$RESULT_DATA" | jq -r '.plan_hash')
  resolution=$(echo "$RESULT_DATA" | jq -r '.checks[] | select(.id=="member_resolution") | .status')
  assert_equal "$risk" "pass"
  assert_equal "$resolution" "pass"
  [[ "$hash" =~ ^rcp[0-9a-f]{24}$ ]]
}

@test "reconfig/plan blocks when an op references a nonexistent member" {
  run_reconfig_task "plan" \
    '{"namespace":"mongo-1","ops_json":"[{\"action\":\"set_votes\",\"member\":\"mongodb-9\",\"votes\":0}]"}'
  assert_equal "$TASK_STATUS" "completed"

  local risk resolution
  risk=$(echo "$RESULT_DATA" | jq -r '.risk_level')
  resolution=$(echo "$RESULT_DATA" | jq -r '.checks[] | select(.id=="member_resolution") | .status')
  assert_equal "$risk" "block"
  assert_equal "$resolution" "block"
}

@test "reconfig/plan warns on even voting-member count" {
  run_reconfig_task "plan" \
    '{"namespace":"mongo-1","ops_json":"[{\"action\":\"set_votes\",\"member\":\"mongodb-2\",\"votes\":0}]"}'
  assert_equal "$TASK_STATUS" "completed"

  local risk parity
  risk=$(echo "$RESULT_DATA" | jq -r '.risk_level')
  parity=$(echo "$RESULT_DATA" | jq -r '.checks[] | select(.id=="vote_parity") | .status')
  assert_equal "$risk" "warn"
  assert_equal "$parity" "warn"
  # projection must also have zeroed the priority (votes:0 forces priority:0)
  local projected_prio
  projected_prio=$(echo "$RESULT_DATA" | jq -r '.projected_members[] | select(.host | startswith("mongodb-2.")) | .priority')
  assert_equal "$projected_prio" "0"
}

@test "reconfig/plan rejects malformed ops_json" {
  run_reconfig_task "plan" \
    '{"namespace":"mongo-1","ops_json":"[{\"action\":\"drop_all\"}]"}'
  assert_equal "$TASK_STATUS" "failed"
  local err
  err=$(echo "$RESULT_DATA" | jq -r '.error // empty')
  [[ -n "$err" ]]
}

@test "reconfig/plan zone simulation: warns on single zone, skips without labels" {
  local ctx="$CTX_A" node
  # label every node in cluster-a with the same zone
  for node in $(kubectl --context "$ctx" get nodes -o jsonpath='{.items[*].metadata.name}'); do
    kubectl --context "$ctx" label node "$node" \
      topology.kubernetes.io/zone=zone-a --overwrite >/dev/null
  done

  run_reconfig_task "plan" \
    '{"namespace":"mongo-1","ops_json":"[{\"action\":\"set_priority\",\"member\":\"mongodb-1\",\"priority\":1}]"}'
  assert_equal "$TASK_STATUS" "completed"
  local zone_status
  zone_status=$(echo "$RESULT_DATA" | jq -r '.checks[] | select(.id=="zone_quorum") | .status')
  assert_equal "$zone_status" "warn"   # all voters in one zone → SPOF warning

  # remove the labels → simulation must fail soft (skip), never guess
  for node in $(kubectl --context "$ctx" get nodes -o jsonpath='{.items[*].metadata.name}'); do
    kubectl --context "$ctx" label node "$node" topology.kubernetes.io/zone- >/dev/null
  done

  run_reconfig_task "plan" \
    '{"namespace":"mongo-1","ops_json":"[{\"action\":\"set_priority\",\"member\":\"mongodb-1\",\"priority\":1}]"}'
  assert_equal "$TASK_STATUS" "completed"
  zone_status=$(echo "$RESULT_DATA" | jq -r '.checks[] | select(.id=="zone_quorum") | .status')
  assert_equal "$zone_status" "skip"
}

# ── reconfig/apply ───────────────────────────────────────────────────────────

@test "reconfig/apply rejects request with missing plan_hash at submission" {
  http_post "${AQSH_URL}/tasks/reconfig%2Fapply" \
    '{"namespace":"mongo-1","ops_json":"[{\"action\":\"set_priority\",\"member\":\"mongodb-1\",\"priority\":1}]"}'
  [ "$HTTP_CODE" != "202" ]
}

@test "reconfig/apply refuses a stale plan_hash (PLAN_STALE)" {
  # plan first — then move the config underneath it, so the hash no longer matches
  run_reconfig_task "plan" \
    '{"namespace":"mongo-1","ops_json":"[{\"action\":\"set_priority\",\"member\":\"mongodb-1\",\"priority\":1}]"}'
  assert_equal "$TASK_STATUS" "completed"
  local hash
  hash=$(echo "$RESULT_DATA" | jq -r '.plan_hash')

  # out-of-band reconfig bumps the version (a no-op priority write is enough)
  local bump
  bump=$(_mongo0_eval "
    try {
      var cfg = rs.conf(); cfg.version = cfg.version + 1;
      var r = rs.reconfig(cfg); print(JSON.stringify({ok: r.ok}));
    } catch(e) { print(JSON.stringify({ok:0, errmsg:e.message})); }")
  echo "out-of-band version bump: ${bump}" >&2
  [[ "$bump" == *'"ok":1'* ]]

  run_reconfig_task "apply" \
    "{\"namespace\":\"mongo-1\",\"ops_json\":\"[{\\\"action\\\":\\\"set_priority\\\",\\\"member\\\":\\\"mongodb-1\\\",\\\"priority\\\":1}]\",\"plan_hash\":\"${hash}\"}"
  assert_equal "$TASK_STATUS" "failed"
  local code
  code=$(echo "$RESULT_DATA" | jq -r '.code // empty')
  assert_equal "$code" "PLAN_STALE"
}

@test "reconfig/apply happy path: plan then apply, config actually changes, audit written" {
  # priority 0.5 keeps mongodb-1 BELOW every other member — the change is
  # observable in rs.conf() without triggering a priority-takeover election
  run_reconfig_task "plan" \
    '{"namespace":"mongo-1","ops_json":"[{\"action\":\"set_priority\",\"member\":\"mongodb-1\",\"priority\":0.5}]"}'
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.risk_level')" "pass"
  local hash
  hash=$(echo "$RESULT_DATA" | jq -r '.plan_hash')

  run_reconfig_task "apply" \
    "{\"namespace\":\"mongo-1\",\"ops_json\":\"[{\\\"action\\\":\\\"set_priority\\\",\\\"member\\\":\\\"mongodb-1\\\",\\\"priority\\\":0.5}]\",\"plan_hash\":\"${hash}\",\"requested_by\":\"bats\",\"request_id\":\"reconfig-e2e-1\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.primary_ok_after_apply')" "true"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.audited')" "true"

  # the live config really changed
  local live_prio
  live_prio=$(_mongo0_eval "
    var m = rs.conf().members.filter(function(x){ return x.host.indexOf('mongodb-1') !== -1; })[0];
    print(m.priority);")
  assert_equal "$live_prio" "0.5"

  # audit ConfigMap holds the entry with pre/post snapshots
  local audit_action audit_outcome
  audit_action=$(kubectl --context "$CTX_A" -n mongo-1 get configmap mongodb-reconfig-audit \
    -o jsonpath='{.data.entries}' | jq -r '.[-1].action')
  audit_outcome=$(kubectl --context "$CTX_A" -n mongo-1 get configmap mongodb-reconfig-audit \
    -o jsonpath='{.data.entries}' | jq -r '.[-1].outcome')
  assert_equal "$audit_action" "apply"
  assert_equal "$audit_outcome" "success"

  # revert (also exercises a second full plan → apply cycle)
  run_reconfig_task "plan" \
    '{"namespace":"mongo-1","ops_json":"[{\"action\":\"set_priority\",\"member\":\"mongodb-1\",\"priority\":1}]"}'
  assert_equal "$TASK_STATUS" "completed"
  hash=$(echo "$RESULT_DATA" | jq -r '.plan_hash')
  run_reconfig_task "apply" \
    "{\"namespace\":\"mongo-1\",\"ops_json\":\"[{\\\"action\\\":\\\"set_priority\\\",\\\"member\\\":\\\"mongodb-1\\\",\\\"priority\\\":1}]\",\"plan_hash\":\"${hash}\"}"
  assert_equal "$TASK_STATUS" "completed"
}

# ── reconfig/freeze ──────────────────────────────────────────────────────────

@test "reconfig/freeze blocks plan and apply until lifted; force of freeze needs reason" {
  # enabling without a reason is refused
  run_reconfig_task "freeze" '{"namespace":"mongo-1","enabled":"true"}'
  assert_equal "$TASK_STATUS" "failed"

  run_reconfig_task "freeze" \
    '{"namespace":"mongo-1","enabled":"true","reason":"bats change freeze"}'
  assert_equal "$TASK_STATUS" "completed"

  # plan now reports change_window block
  run_reconfig_task "plan" \
    '{"namespace":"mongo-1","ops_json":"[{\"action\":\"set_priority\",\"member\":\"mongodb-1\",\"priority\":1}]"}'
  assert_equal "$TASK_STATUS" "completed"
  local risk window hash
  risk=$(echo "$RESULT_DATA" | jq -r '.risk_level')
  window=$(echo "$RESULT_DATA" | jq -r '.checks[] | select(.id=="change_window") | .status')
  hash=$(echo "$RESULT_DATA" | jq -r '.plan_hash')
  assert_equal "$risk" "block"
  assert_equal "$window" "block"

  # apply is refused outright — block is never overridable
  run_reconfig_task "apply" \
    "{\"namespace\":\"mongo-1\",\"ops_json\":\"[{\\\"action\\\":\\\"set_priority\\\",\\\"member\\\":\\\"mongodb-1\\\",\\\"priority\\\":1}]\",\"plan_hash\":\"${hash}\",\"override_reason\":\"trying to sneak past the freeze\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.code // empty')" "BLOCKED"

  # lift the freeze — plan goes back to pass
  run_reconfig_task "freeze" '{"namespace":"mongo-1","enabled":"false"}'
  assert_equal "$TASK_STATUS" "completed"
  run_reconfig_task "plan" \
    '{"namespace":"mongo-1","ops_json":"[{\"action\":\"set_priority\",\"member\":\"mongodb-1\",\"priority\":1}]"}'
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.risk_level')" "pass"
}

# ── reconfig/force-dr ────────────────────────────────────────────────────────

@test "reconfig/force-dr rejects request with missing incident_id" {
  http_post "${AQSH_URL}/tasks/reconfig%2Fforce-dr" '{"namespace":"mongo-1"}'
  [ "$HTTP_CODE" != "202" ]
}

@test "reconfig/force-dr dry_run on a healthy cluster reports not ready (quorum intact)" {
  run_reconfig_task "force-dr" \
    '{"namespace":"mongo-1","incident_id":"INC-e2e-healthy"}'
  assert_equal "$TASK_STATUS" "completed"

  local ready no_primary
  ready=$(echo "$RESULT_DATA" | jq -r '.ready')
  no_primary=$(echo "$RESULT_DATA" | jq -r '.preconditions[] | select(.id=="no_primary") | .pass')
  assert_equal "$ready" "false"
  assert_equal "$no_primary" "false"   # a primary exists → precondition fails
}

@test "reconfig/force-dr full site-loss drill: threshold, confirm, election, post-DR vote restore" {
  local ctx="$CTX_A"

  # ── simulate losing 2 of 3 members (a "site") ──────────────────────────────
  kubectl --context "$ctx" -n mongo-1 patch statefulset mongodb --type=merge \
    -p '{"spec":{"replicas":1}}'
  kubectl --context "$ctx" -n mongo-1 wait pod mongodb-1 mongodb-2 --for=delete \
    --timeout=120s || true

  # survivor loses quorum → steps down; wait until it reports no primary
  local elapsed=0 has_primary="true"
  while (( elapsed < 90 )); do
    has_primary=$(_mongo0_eval "
      try { print(rs.status().members.some(function(m){ return m.state===1 && m.health===1; })); }
      catch(e) { print('true'); }")
    [[ "$has_primary" == "false" ]] && break
    sleep 5; elapsed=$((elapsed + 5))
  done
  assert_equal "$has_primary" "false"

  # ── dry_run immediately: heartbeat threshold (45s in this deployment) may
  #    still be running — if so, unreachable_age must be the failing gate ────
  run_reconfig_task "force-dr" \
    '{"namespace":"mongo-1","incident_id":"INC-e2e-drill"}'
  assert_equal "$TASK_STATUS" "completed"
  local ready age_pass
  ready=$(echo "$RESULT_DATA" | jq -r '.ready')
  if [[ "$ready" == "false" ]]; then
    age_pass=$(echo "$RESULT_DATA" | jq -r '.preconditions[] | select(.id=="unreachable_age") | .pass')
    assert_equal "$age_pass" "false"
    echo "threshold gate held as expected — waiting it out" >&2
    sleep 50
    run_reconfig_task "force-dr" \
      '{"namespace":"mongo-1","incident_id":"INC-e2e-drill"}'
    assert_equal "$TASK_STATUS" "completed"
    ready=$(echo "$RESULT_DATA" | jq -r '.ready')
  fi
  assert_equal "$ready" "true"

  local hash suggested_zero_votes
  hash=$(echo "$RESULT_DATA" | jq -r '.plan_hash')
  [[ "$hash" =~ ^rcp[0-9a-f]{24}$ ]]
  # suggested config strips votes/priority from BOTH lost members, deletes none
  suggested_zero_votes=$(echo "$RESULT_DATA" | jq -r \
    '[.suggested_members[] | select(.votes == 0 and .priority == 0)] | length')
  assert_equal "$suggested_zero_votes" "2"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.suggested_members | length')" "3"

  # confirm without plan_hash is refused
  run_reconfig_task "force-dr" \
    '{"namespace":"mongo-1","incident_id":"INC-e2e-drill","dry_run":"false","confirm":"true"}'
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.code // empty')" "PLAN_HASH_REQUIRED"

  # ── confirm: break the glass ───────────────────────────────────────────────
  run_reconfig_task "force-dr" \
    "{\"namespace\":\"mongo-1\",\"incident_id\":\"INC-e2e-drill\",\"dry_run\":\"false\",\"confirm\":\"true\",\"plan_hash\":\"${hash}\",\"requested_by\":\"bats\"}"
  assert_equal "$TASK_STATUS" "completed"
  local elected
  elected=$(echo "$RESULT_DATA" | jq -r '.elected_primary // empty')
  [[ "$elected" == *"mongodb-0"* ]]

  # dr-active annotation is set, audit entry recorded
  local dr_ann
  dr_ann=$(kubectl --context "$ctx" -n mongo-1 get statefulset mongodb \
    -o json | jq -r '.metadata.annotations["reconfig.db-runbooks/dr-active"] // ""')
  assert_equal "$dr_ann" "true"
  local audit_action
  audit_action=$(kubectl --context "$ctx" -n mongo-1 get configmap mongodb-reconfig-audit \
    -o jsonpath='{.data.entries}' | jq -r '.[-1].action')
  assert_equal "$audit_action" "force-dr"

  # survivor is writable primary with 1/1 votes
  local live_votes
  live_votes=$(_mongo0_eval "print(rs.conf().members.map(function(m){return m.votes;}).join(','));")
  assert_equal "$live_votes" "1,0,0"

  # ── site returns: scale back, members rejoin as non-voting ────────────────
  kubectl --context "$ctx" -n mongo-1 patch statefulset mongodb --type=merge \
    -p '{"spec":{"replicas":3}}'
  kubectl --context "$ctx" -n mongo-1 rollout status statefulset/mongodb --timeout=300s
  # give the rejoined members a moment to reach SECONDARY
  elapsed=0
  while (( elapsed < 180 )); do
    local sec_count
    sec_count=$(_mongo0_eval "
      try { print(rs.status().members.filter(function(m){ return m.stateStr==='SECONDARY' && m.health===1; }).length); }
      catch(e) { print('0'); }")
    [[ "$sec_count" == "2" ]] && break
    sleep 5; elapsed=$((elapsed + 5))
  done

  # ── post-DR recovery through the NORMAL gated path (multi-step apply) ─────
  local restore_ops='[{\"action\":\"set_votes\",\"member\":\"mongodb-1\",\"votes\":1},{\"action\":\"set_priority\",\"member\":\"mongodb-1\",\"priority\":1},{\"action\":\"set_votes\",\"member\":\"mongodb-2\",\"votes\":1},{\"action\":\"set_priority\",\"member\":\"mongodb-2\",\"priority\":1}]'
  run_reconfig_task "plan" \
    "{\"namespace\":\"mongo-1\",\"ops_json\":\"${restore_ops}\"}"
  assert_equal "$TASK_STATUS" "completed"
  local risk dr_state
  risk=$(echo "$RESULT_DATA" | jq -r '.risk_level')
  dr_state=$(echo "$RESULT_DATA" | jq -r '.checks[] | select(.id=="dr_state") | .status')
  assert_equal "$dr_state" "warn"      # dr-active steers the caller to the recovery flow
  assert_equal "$risk" "warn"
  hash=$(echo "$RESULT_DATA" | jq -r '.plan_hash')

  # warn-level needs override_reason — without it, refused
  run_reconfig_task "apply" \
    "{\"namespace\":\"mongo-1\",\"ops_json\":\"${restore_ops}\",\"plan_hash\":\"${hash}\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.code // empty')" "OVERRIDE_REQUIRED"

  run_reconfig_task "apply" \
    "{\"namespace\":\"mongo-1\",\"ops_json\":\"${restore_ops}\",\"plan_hash\":\"${hash}\",\"override_reason\":\"post-DR vote restore after site recovery\",\"requested_by\":\"bats\"}" 600
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.steps | length')" "4"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.dr_cleared')" "true"

  # dr-active annotation cleared; all members voting again
  dr_ann=$(kubectl --context "$ctx" -n mongo-1 get statefulset mongodb \
    -o json | jq -r '.metadata.annotations["reconfig.db-runbooks/dr-active"] // ""')
  assert_equal "$dr_ann" ""
  live_votes=$(_mongo0_eval "print(rs.conf().members.map(function(m){return m.votes;}).join(','));")
  assert_equal "$live_votes" "1,1,1"
}
