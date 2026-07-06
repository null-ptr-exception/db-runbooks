#!/usr/bin/env bats
# =============================================================================
# Integration tests for the MongoDB FCV gateway task API
# (fcv/status, fcv/set) — see docs/mongodb/fcv.md.
#
# Self-contained like reconfig.bats: setup_file upgrades mongo-1 to a
# 3-replica RS (member 0 priority 2 → deterministic primary) and ensures the
# root user exists. The test image is mongo:7, so the suite starts at
# FCV "7.0" and the allowed target set is {"6.0","7.0"}.
#
# Test order matters: the confirmed downgrade to 6.0 is later upgraded back
# to 7.0, so the suite is a round trip; teardown_file re-asserts FCV "7.0"
# as a safety net so other suites are unaffected.
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

  # Upgrade to a 3-replica RS (same inline STS as reconfig.bats).
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

  # Ensure the root user from mongodb-credentials exists (see reconfig.bats).
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

  # Start from a known FCV so the suite is deterministic even after an
  # aborted earlier run left the set downgraded.
  _mongo0_eval "db.adminCommand({setFeatureCompatibilityVersion:'7.0', confirm:true}).ok" >/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

teardown_file() {
  local ctx="kind-cluster-a"
  # Safety net: the upgrade-back test restores 7.0 itself; make sure anyway
  # so later suites see the FCV the mongo:7 image started with.
  _mongo0_eval "db.adminCommand({setFeatureCompatibilityVersion:'7.0', confirm:true}).ok" "$ctx" >/dev/null 2>&1 || true
  local fcv
  fcv=$(_current_fcv "$ctx")
  [[ "$fcv" == "7.0" ]] || echo "WARNING: mongo-1 FCV is '${fcv}', expected 7.0" >&2
}

# ---------------------------------------------------------------------------
# Helpers (same pattern as reconfig.bats)
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

# wait until the task reaches completed OR failed; exports TASK_STATUS.
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

# submit a task body to an fcv endpoint and wait; exports TASK_STATUS,
# TASK_RESPONSE and RESULT_DATA (the .result.data payload).
run_fcv_task() {
  local endpoint="$1" body="$2" max_wait="${3:-300}"
  http_post "${AQSH_URL}/tasks/fcv%2F${endpoint}" "$body"
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

# current FCV as observed directly on mongodb-0 (ground truth for asserts).
_current_fcv() {
  local ctx="${1:-$CTX_A}"
  _mongo0_eval "print(db.adminCommand({getParameter:1,featureCompatibilityVersion:1}).featureCompatibilityVersion.version)" "$ctx"
}

# ── fcv/status ───────────────────────────────────────────────────────────────

@test "fcv/status reports version, FCV and allowed targets with only a namespace" {
  run_fcv_task "status" '{"namespace":"mongo-1"}'
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.server_series')" "7.0"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.fcv')" "7.0"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.transitional')" "false"
  assert_equal "$(echo "$RESULT_DATA" | jq -cr '.allowed_targets')" '["6.0","7.0"]'
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.sts')" "mongodb"
  [[ "$(echo "$RESULT_DATA" | jq -r '.primary')" == mongodb-0.* ]]
  # No warning key on a supported version.
  assert_equal "$(echo "$RESULT_DATA" | jq -r 'has("warning")')" "false"
}

# ── fcv/set gating ───────────────────────────────────────────────────────────

@test "fcv/set default dry_run previews a downgrade without changing anything" {
  run_fcv_task "set" '{"namespace":"mongo-1","target_version":"6.0"}'
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "DRY_RUN_READY"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.direction')" "downgrade"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.changed')" "false"
  assert_equal "$(_current_fcv)" "7.0"
}

@test "fcv/set rejects dry_run=true with confirm=true" {
  run_fcv_task "set" '{"namespace":"mongo-1","target_version":"6.0","dry_run":"true","confirm":"true"}'
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"
}

@test "fcv/set rejects dry_run=false without confirm" {
  run_fcv_task "set" '{"namespace":"mongo-1","target_version":"6.0","dry_run":"false"}'
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"
}

# ── fcv/set validation ───────────────────────────────────────────────────────

@test "fcv/set fails INVALID_TARGET for an FCV outside the binary's allowed set" {
  run_fcv_task "set" '{"namespace":"mongo-1","target_version":"5.0","dry_run":"false","confirm":"true"}'
  assert_equal "$TASK_STATUS" "failed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_TARGET"
  # The error must state what IS allowed.
  local summary
  summary=$(echo "$RESULT_DATA" | jq -r '.summary')
  [[ "$summary" == *"6.0 7.0"* ]]
  assert_equal "$(echo "$RESULT_DATA" | jq -cr '.details.allowed_targets')" '["6.0","7.0"]'
  assert_equal "$(_current_fcv)" "7.0"
}

# ── fcv/set execution (downgrade → upgrade round trip) ───────────────────────

@test "fcv/set confirmed downgrade 7.0 -> 6.0 changes the live FCV" {
  run_fcv_task "set" '{"namespace":"mongo-1","target_version":"6.0","dry_run":"false","confirm":"true"}'
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "FCV_SET"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.previous_fcv')" "7.0"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.current_fcv')" "6.0"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.direction')" "downgrade"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.changed')" "true"
  assert_equal "$(_current_fcv)" "6.0"
}

@test "fcv/status reflects the downgraded FCV" {
  run_fcv_task "status" '{"namespace":"mongo-1"}'
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.fcv')" "6.0"
  assert_equal "$(echo "$RESULT_DATA" | jq -cr '.allowed_targets')" '["6.0","7.0"]'
}

@test "fcv/set confirmed upgrade 6.0 -> 7.0 restores the FCV" {
  run_fcv_task "set" '{"namespace":"mongo-1","target_version":"7.0","dry_run":"false","confirm":"true"}'
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.previous_fcv')" "6.0"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.current_fcv')" "7.0"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.direction')" "upgrade"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.changed')" "true"
  assert_equal "$(_current_fcv)" "7.0"
}

@test "fcv/set at the current FCV completes as ALREADY_AT_TARGET without changing anything" {
  run_fcv_task "set" '{"namespace":"mongo-1","target_version":"7.0","dry_run":"false","confirm":"true"}'
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "ALREADY_AT_TARGET"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.changed')" "false"
  assert_equal "$(_current_fcv)" "7.0"
}
