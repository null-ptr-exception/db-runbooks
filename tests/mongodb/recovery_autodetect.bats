#!/usr/bin/env bats
# =============================================================================
# E2E proof that the auto-detect tier (CLAUDE.md "Configuration Layers") does
# real work, not just match the hardcoded literal by coincidence.
#
# recovery.bats's mongo-1 RS and recovery_custom_naming.bats both happen to
# use credential/path conventions that are IDENTICAL to the library's
# hardcoded-literal fallback (mongodb-credentials/MONGO_ROOT_USER/
# MONGO_ROOT_PASS, /bitnami/mongodb/data/db) or explicitly override it via
# internal config/task input — none of them can tell "detection resolved
# this correctly" apart from "the hardcoded fallback happened to match" or
# "an explicit override took precedence over whatever detection would say".
#
# This file is deliberately shaped so BOTH of those escape hatches are
# absent and BOTH would give the WRONG answer if used:
#   - credential username is a literal env value ("root"), password comes
#     from a secretKeyRef with a non-default key name ("rootPassword", not
#     "MONGO_ROOT_PASS")
#   - the real dbPath is the official-image default "/data/db", which does
#     not match the hardcoded-literal "/bitnami/mongodb/data/db"
# recovery/pre-check is called with ONLY namespace+target_pod — no naming
# inputs, no internal config changes. It can only succeed (and G5 can only
# measure real data, not warn-degrade to 0) if _recovery_detect_credentials
# and _recovery_detect_data_path actually read the live StatefulSet/mongod
# state correctly.
#
# Self-contained: setup_file creates the mongo-autodetect namespace and all
# its resources (reusing default object names "mongodb"/"mongodb-credentials"
# /"mongodb-recovery-config" so the existing aqsh-mongo-manager ClusterRole's
# resourceNames already cover it — only a namespace-scoped RoleBinding is
# needed, no ClusterRole change, same technique as recovery_bitnami_profile.
# bats). teardown_file deletes the namespace. No other test file reads or
# writes mongo-autodetect.
#
# mongod is started directly (bypassing docker-entrypoint.sh, same reason as
# recovery_bitnami_profile.bats: mixing --replSet with the entrypoint's own
# user-bootstrap timing is unreliable), so the root user is created via
# createUser below. The MONGO_INITDB_ROOT_* env block on the container is
# therefore not what actually bootstraps mongod — it stands in for what a
# real entrypoint-driven image (official or Bitnami) would already wire up,
# which is exactly the live signal _recovery_detect_credentials reads.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  ANS="mongo-autodetect"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=1h)

  export CTX_A CTX_B NS ANS AQSH_URL TEST_POD TOKEN

  local ctx="$CTX_A"

  kubectl --context "$ctx" create namespace "$ANS" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  # Non-default key name ("rootPassword", not "MONGO_ROOT_PASS") in a
  # default-named secret — no RBAC change needed (resourceNames pins the
  # secret NAME, never the keys inside it), but the hardcoded-literal
  # fallback's assumed key name is wrong here, so only detection (or an
  # explicit override, which this file never passes) can read it.
  kubectl --context "$ctx" -n "$ANS" create secret generic mongodb-credentials \
    --from-literal=rootPassword=testpass456 \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  # Default object names ("mongodb") — existing ClusterRole's resourceNames
  # already cover it; only a namespace-scoped RoleBinding is needed.
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

  # Official-image default layout: volume "data" at /data/db (NOT the
  # hardcoded-literal "/bitnami/mongodb/data/db") — mongod started directly
  # (see file header), 2 replicas so G3/G7 have another healthy member.
  kubectl --context "$ctx" -n "$ANS" apply -f - <<STS_EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: ${ANS}
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
            - name: MONGO_INITDB_ROOT_USERNAME
              value: "root"
            - name: MONGO_INITDB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mongodb-credentials
                  key: rootPassword
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

  echo "Waiting for 2-replica auto-detect RS rollout in ${ANS}..."
  kubectl --context "$ctx" -n "$ANS" rollout status statefulset/mongodb --timeout=300s

  _init_rs "$ANS" "$ctx" 2
  _wait_for_primary "$ANS" "$ctx" 180

  local mongo_pass
  mongo_pass=$(_mongo_pass "$ANS" "$ctx")
  local user_elapsed=0 user_ready=false
  while (( user_elapsed < 60 )); do
    if kubectl --context "$ctx" -n "$ANS" exec mongodb-0 -- mongosh --quiet --norc \
      "mongodb://localhost:27017/admin" --eval "
        try {
          db.getSiblingDB('admin').createUser({user:'root', pwd:'${mongo_pass}', roles:[{role:'root',db:'admin'}]});
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
    echo "Failed to create/verify root user in ${ANS} after 60s" >&2
    return 1
  fi

  # The script under test: applies the recovery ConfigMap + patches the STS
  # with the data-recovery init container shaped by --profile standard
  # (matches this fixture's /data/db layout).
  "${BATS_TEST_DIRNAME}/../../aqsh-tasks/scripts/mongodb/recovery/setup-data-recovery.sh" \
    --context "$ctx" --namespace "$ANS" --sts mongodb --profile standard

  echo "Waiting for MongoDB to stabilise after init-container patch..."
  kubectl --context "$ctx" -n "$ANS" rollout status statefulset/mongodb --timeout=300s || true
  _wait_for_primary "$ANS" "$ctx" 120
}

teardown_file() {
  local ctx="kind-cluster-a"
  kubectl --context "$ctx" delete namespace "mongo-autodetect" --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

# ---------------------------------------------------------------------------
# Helpers — trimmed copies of recovery_bitnami_profile.bats's patterns,
# adjusted for this fixture's literal-username/non-default-key convention.
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
  local base_url="$1" task_id="$2" max_wait="${3:-120}"
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

_init_rs() {
  local namespace="$1" ctx="${2:-$CTX_A}" replicas="${3:-2}"
  echo "Initializing MongoDB replica set rs0 in ${namespace} (${replicas} members)..."
  kubectl --context "$ctx" -n "$namespace" wait pod mongodb-0 \
    --for=condition=Ready --timeout=120s || {
    echo "mongodb-0 not ready after 120s" >&2; return 1
  }
  local members="" i
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

# ---------------------------------------------------------------------------
# _mongo_pass <namespace> [context]
# Echo the rootPassword key from the mongodb-credentials secret. Username
# is the literal "root" (see file header) — never stored in a secret here.
# ---------------------------------------------------------------------------
_mongo_pass() {
  local namespace="$1" ctx="${2:-$CTX_A}"
  kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
    -o jsonpath='{.data.rootPassword}' | base64 -d
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
      var h = db.hello();
      if (h && (h.isWritablePrimary || h.ismaster)) { quit(0); }
      quit(1);'
      if kubectl --context "$ctx" -n "$namespace" exec "$pod" -- mongosh --quiet --norc \
        "mongodb://localhost:27017/admin?serverSelectionTimeoutMS=2000" \
        --eval "$rs_check" >/dev/null 2>&1; then
        return 0
      fi
      local pass
      pass=$(_mongo_pass "$namespace" "$ctx")
      if [[ -n "$pass" ]]; then
        if kubectl --context "$ctx" -n "$namespace" exec "$pod" -- mongosh --quiet --norc \
          "mongodb://root:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=2000" \
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
# _find_primary_pod <namespace> [context]
# ---------------------------------------------------------------------------
_find_primary_pod() {
  local namespace="$1" ctx="${2:-$CTX_A}"
  local pass
  pass=$(_mongo_pass "$namespace" "$ctx")
  local pod
  for pod in mongodb-0 mongodb-1; do
    local is_primary
    is_primary=$(kubectl --context "$ctx" -n "$namespace" exec "$pod" -- mongosh --quiet --norc \
      "mongodb://root:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=3000" \
      --eval "try{var h=db.hello();print((h.isWritablePrimary||h.ismaster)?'1':'0');}catch(e){print('0');}" \
      2>/dev/null | tail -1 | tr -d '\r') || is_primary="0"
    [[ "$is_primary" == "1" ]] && { echo "$pod"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# _wipe_target <namespace> [context]
# Echo a non-primary pod name, suitable as a safe recovery/pre-check target.
# ---------------------------------------------------------------------------
_wipe_target() {
  local namespace="$1" ctx="${2:-$CTX_A}"
  local primary_pod
  primary_pod=$(_find_primary_pod "$namespace" "$ctx") || true
  for p in mongodb-1 mongodb-0; do
    [[ "$p" != "$primary_pod" ]] && { echo "$p"; return 0; }
  done
  return 1
}

# ── the real proof ───────────────────────────────────────────────────────

@test "recovery/pre-check resolves credentials and data_path purely via live detection (zero naming inputs, no internal config)" {
  local target
  target=$(_wipe_target "$ANS" "$CTX_A")

  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    "{\"namespace\":\"${ANS}\",\"target_pod\":\"${target}\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 120

  local result fail_count gate_count
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  fail_count=$(echo "$result" | jq -r '.fail // "missing"')
  gate_count=$(echo "$result" | jq '[.gates[] | select(.gate)] | length' 2>/dev/null || echo "0")
  [ "$gate_count" -ge 8 ] || { echo "gates: $result" >&2; false; }
  # If credential detection failed (wrong secret/keys), gates would never
  # get this far — G3 requires an authenticated rs.status() call.
  [ "$fail_count" = "0" ] || { echo "gates: $result" >&2; false; }

  # If data_path detection fell back to the hardcoded-literal
  # "/bitnami/mongodb/data/db" (wrong for this fixture's real /data/db),
  # G5 would silently warn-degrade to data_mb=0 instead of measuring real
  # data — see recovery.bats's "wrong data_path" tests for that failure mode.
  local g5_data_mb
  g5_data_mb=$(echo "$result" | jq -r '.gates[] | select(.gate=="G5") | .data_mb')
  [ "${g5_data_mb:-0}" -gt 0 ]
}
