#!/usr/bin/env bats
# =============================================================================
# E2E proof that the FCV tasks work against a Bitnami-convention deployment
# with zero task inputs beyond the namespace: credentials wired as
# MONGODB_ROOT_USER/MONGODB_ROOT_PASSWORD secretKeyRefs with non-default key
# names ("root-user"/"root-password"), so neither the hardcoded-literal
# fallback nor any internal config can resolve them — only
# _recovery_detect_credentials reading the live StatefulSet spec can.
# Fixture mirrors recovery_autodetect_bitnami_secret.bats (which proves the
# same detection chain for recovery/*).
#
# Self-contained: setup_file creates the mongo-fcv-bitnami namespace and all
# its resources (default object names "mongodb"/"mongodb-credentials" so the
# existing aqsh-mongo-manager ClusterRole's resourceNames already cover it —
# only a namespace-scoped RoleBinding is needed). teardown_file deletes the
# namespace. No other test file reads or writes mongo-fcv-bitnami.
#
# mongod is started directly (bypassing docker-entrypoint.sh, same reason as
# the recovery autodetect fixtures), so the root user is created via
# createUser below; the secretKeyRefs stand in for what a real Bitnami chart
# deployment would wire up — exactly the live signal detection reads.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  SNS="mongo-fcv-bitnami"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=1h)

  export CTX_A CTX_B NS SNS AQSH_URL TEST_POD TOKEN

  local ctx="$CTX_A"

  kubectl --context "$ctx" create namespace "$SNS" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  # Non-default key names — the hardcoded-literal fallback's assumed keys
  # are wrong here, so only detection can read them.
  kubectl --context "$ctx" -n "$SNS" create secret generic mongodb-credentials \
    --from-literal=root-user=bitnamiadmin --from-literal=root-password=testpass321 \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  # Default object names ("mongodb") — existing ClusterRole's resourceNames
  # already cover it; only a namespace-scoped RoleBinding is needed.
  kubectl --context "$ctx" -n "$SNS" apply -f - <<'RB_EOF'
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

  kubectl --context "$ctx" -n "$SNS" apply -f - <<STS_EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: ${SNS}
spec:
  replicas: 2
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
            - name: MONGODB_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: mongodb-credentials
                  key: root-user
            - name: MONGODB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mongodb-credentials
                  key: root-password
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
  namespace: ${SNS}
spec:
  clusterIP: None
  selector:
    app: mongodb
  ports:
    - port: 27017
      targetPort: 27017
STS_EOF

  echo "Waiting for 2-replica Bitnami-convention RS rollout in ${SNS}..."
  kubectl --context "$ctx" -n "$SNS" rollout status statefulset/mongodb --timeout=300s

  _init_rs "$SNS" "$ctx" 2
  _wait_for_primary "$SNS" "$ctx" 180

  # _init_rs gives all members equal priority (no deterministic primary),
  # so createUser must be tried against every pod each round: whichever one
  # is actually primary accepts it.
  local user_elapsed=0 user_ready=false pod
  while (( user_elapsed < 60 )); do
    for pod in mongodb-0 mongodb-1; do
      if kubectl --context "$ctx" -n "$SNS" exec "$pod" -- mongosh --quiet --norc \
        "mongodb://localhost:27017/admin" --eval "
          try {
            db.getSiblingDB('admin').createUser({user:'bitnamiadmin', pwd:'testpass321', roles:[{role:'root',db:'admin'}]});
            print('root user created');
          } catch(e) {
            if (/already exists/.test(e.message)) { print('root user exists'); }
            else { throw e; }
          }" >/dev/null 2>&1; then
        user_ready=true
        break
      fi
    done
    [[ "$user_ready" == true ]] && break
    sleep 5; user_elapsed=$((user_elapsed + 5))
  done
  if [[ "$user_ready" != true ]]; then
    echo "Failed to create/verify root user in ${SNS} after 60s" >&2
    return 1
  fi
}

teardown_file() {
  local ctx="kind-cluster-a"
  kubectl --context "$ctx" delete namespace "mongo-fcv-bitnami" --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

# ---------------------------------------------------------------------------
# Helpers — trimmed copies of fcv.bats's patterns.
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

# Equal-priority RS init (2 members) — no deterministic primary needed here.
_init_rs() {
  local namespace="$1" ctx="${2:-$CTX_A}" replicas="${3:-2}"
  echo "Initializing MongoDB replica set rs0 in ${namespace} (${replicas} members)..."
  kubectl --context "$ctx" -n "$namespace" wait pod mongodb-0 \
    --for=condition=Ready --timeout=120s || {
    echo "mongodb-0 not ready after 120s" >&2; return 1
  }
  local members=""
  for i in $(seq 0 $((replicas - 1))); do
    members+="{_id:${i},host:'mongodb-${i}.mongodb.${namespace}.svc.cluster.local:27017'},"
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

_wait_for_primary() {
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

# ── The tests: namespace is the ONLY input ever sent ────────────────────────

@test "fcv/status auto-detects Bitnami-convention credentials from the live STS" {
  run_fcv_task "status" "{\"namespace\":\"${SNS}\"}"
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.server_series')" "7.0"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.fcv')" "7.0"
  assert_equal "$(echo "$RESULT_DATA" | jq -cr '.allowed_targets')" '["6.0","7.0"]'
}

@test "fcv/set dry-run works against the Bitnami-convention deployment" {
  run_fcv_task "set" "{\"namespace\":\"${SNS}\",\"target_version\":\"6.0\"}"
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "DRY_RUN_READY"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.direction')" "downgrade"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.changed')" "false"
}
