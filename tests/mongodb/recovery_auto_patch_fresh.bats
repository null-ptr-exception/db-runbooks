#!/usr/bin/env bats
# =============================================================================
# E2E proof that G1 self-heal also creates the recovery ConfigMap itself
# when that's missing too — not just the init container (see
# recovery_auto_patch.bats, which deliberately pre-creates the ConfigMap so
# G2 passes and only G1 self-heals; this file is the "completely untouched"
# counterpart: setup_file never creates the ConfigMap, never calls
# setup-data-recovery.sh, and never even creates the ConfigMap by hand).
#
# A single recovery/recover call against a StatefulSet that has NEITHER the
# data-recovery init container NOR the mongodb-recovery-config ConfigMap
# must self-heal both and complete the wipe+resync — proving an operator
# never needs the One-Time Setup script as a precondition. See CLAUDE.md
# "Gate G1 self-heal" and _recovery_auto_patch_init_container in
# aqsh-tasks/lib/mongodb-recovery.sh.
#
# Self-contained: setup_file creates the mongo-autopatch-fresh namespace and
# all its resources. Reuses default object names ("mongodb"/
# "mongodb-credentials"/"mongodb-recovery-config") so the existing
# aqsh-mongo-manager ClusterRole's resourceNames already cover the
# StatefulSet/secret; the ConfigMap is created by self-heal itself, not by
# this file, exercising the namespace-wide `configmaps` `create` RBAC rule
# (see tests/chart/templates/mongodb-rbac.yaml). teardown_file deletes the
# namespace. No other test file reads or writes mongo-autopatch-fresh.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  FNS="mongo-autopatch-fresh"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=1h)

  export CTX_A CTX_B NS FNS AQSH_URL TEST_POD TOKEN

  local ctx="$CTX_A"

  kubectl --context "$ctx" create namespace "$FNS" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  kubectl --context "$ctx" -n "$FNS" create secret generic mongodb-credentials \
    --from-literal=MONGO_ROOT_USER=mongoadmin --from-literal=MONGO_ROOT_PASS=testpass123 \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  kubectl --context "$ctx" -n "$FNS" apply -f - <<'RB_EOF'
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

  # Standard mongo:N layout (volume "data" at /data/db) — deliberately NO
  # initContainers, and setup_file never creates the recovery ConfigMap
  # either: both halves of the One-Time Setup are missing.
  kubectl --context "$ctx" -n "$FNS" apply -f - <<STS_EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: ${FNS}
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
  namespace: ${FNS}
spec:
  clusterIP: None
  selector:
    app: mongodb
  ports:
    - port: 27017
      targetPort: 27017
STS_EOF

  echo "Waiting for 2-replica fresh-autopatch RS rollout in ${FNS}..."
  kubectl --context "$ctx" -n "$FNS" rollout status statefulset/mongodb --timeout=300s

  _init_rs "$FNS" "$ctx" 2
  _wait_for_primary "$FNS" "$ctx" 180

  local mongo_user mongo_pass
  mongo_user=$(kubectl --context "$ctx" -n "$FNS" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  mongo_pass=$(kubectl --context "$ctx" -n "$FNS" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)
  local user_elapsed=0 user_ready=false
  while (( user_elapsed < 60 )); do
    if kubectl --context "$ctx" -n "$FNS" exec mongodb-0 -- mongosh --quiet --norc \
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
    echo "Failed to create/verify root user in ${FNS} after 60s" >&2
    return 1
  fi

  # Deliberately NOT creating the recovery ConfigMap here — that's the
  # whole point of this file.
}

teardown_file() {
  local ctx="kind-cluster-a"
  kubectl --context "$ctx" delete namespace "mongo-autopatch-fresh" --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

# ---------------------------------------------------------------------------
# Helpers — same pattern as recovery_auto_patch.bats, trimmed to 2 replicas.
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

# mongodb-0 gets priority=2 so it deterministically wins primary, leaving
# mongodb-1 as the safe, deterministic wipe target (same technique as
# recovery_auto_patch.bats's _init_rs).
_init_rs() {
  local namespace="$1" ctx="${2:-$CTX_A}" replicas="${3:-2}"
  echo "Initializing MongoDB replica set rs0 in ${namespace} (${replicas} members)..."
  kubectl --context "$ctx" -n "$namespace" wait pod mongodb-0 \
    --for=condition=Ready --timeout=120s || {
    echo "mongodb-0 not ready after 120s" >&2; return 1
  }
  local members="" i prio
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

_wait_for_rs_healthy() {
  local namespace="$1" target_pod="$2" ctx="${3:-$CTX_A}" max_wait="${4:-180}"
  local user pass
  user=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  pass=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)
  local probe_pod p
  for p in mongodb-0 mongodb-1; do
    [[ "$p" != "$target_pod" ]] && { probe_pod="$p"; break; }
  done
  local elapsed=0 state=""
  while (( elapsed < max_wait )); do
    state=$(kubectl --context "$ctx" -n "$namespace" exec "$probe_pod" -- mongosh --quiet --norc \
      "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=5000" \
      --eval "try{var m=rs.status().members.filter(function(x){return x.name.indexOf('${target_pod}')!==-1;})[0];print(m?m.stateStr+','+m.health:'NONE,0');}catch(e){print('ERR,0');}" \
      2>/dev/null | tail -1 | tr -d '\r') || state="ERR,0"
    [[ "$state" == "SECONDARY,1" || "$state" == "PRIMARY,1" ]] && return 0
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "${target_pod} did not become healthy within ${max_wait}s (last: ${state})" >&2
  return 1
}

# ── the real proof ───────────────────────────────────────────────────────

@test "STS starts with neither the data-recovery init container nor the recovery ConfigMap" {
  run kubectl --context "$CTX_A" -n "$FNS" get statefulset mongodb \
    -o jsonpath='{.spec.template.spec.initContainers[*].name}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run kubectl --context "$CTX_A" -n "$FNS" get configmap mongodb-recovery-config
  [ "$status" -ne 0 ]
}

@test "recovery/recover self-heals both the ConfigMap and the init container from a completely untouched StatefulSet in one call" {
  local target="mongodb-1"
  local before_uid
  before_uid=$(kubectl --context "$CTX_A" -n "$FNS" \
    get pod "$target" -o jsonpath='{.metadata.uid}')

  http_post "${AQSH_URL}/tasks/recovery%2Frecover" \
    "{\"namespace\":\"${FNS}\",\"target_pod\":\"${target}\",\"wait_timeout\":\"300\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 540

  local result reached auto_patched
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  reached=$(echo "$result" | jq -r '.reached_running // empty')
  assert_equal "$reached" "true"
  auto_patched=$(echo "$result" | jq -r '.auto_patched // empty')
  assert_equal "$auto_patched" "true"

  # The ConfigMap self-heal created is permanent, reusable state — it's
  # never reverted.
  run kubectl --context "$CTX_A" -n "$FNS" get configmap mongodb-recovery-config
  [ "$status" -eq 0 ]

  # The init container patch IS temporary — recover's own internal reset
  # step (run automatically at the end of its cycle) already reverted it,
  # same as recovery_auto_patch.bats's equivalent assertion. Self-heal fully
  # bootstrapped this StatefulSet from nothing, but doesn't leave the
  # init-container patch installed permanently — only the One-Time Setup
  # script does that.
  run bash -c "kubectl --context '$CTX_A' -n '$FNS' get statefulset mongodb -o jsonpath='{.spec.template.spec.initContainers[*].name}' | tr ' ' '\n' | grep -qx data-recovery"
  [ "$status" -ne 0 ]
  local annotation
  annotation=$(kubectl --context "$CTX_A" -n "$FNS" get statefulset mongodb \
    -o jsonpath='{.metadata.annotations.recovery/auto-patched}' 2>/dev/null || true)
  [ -z "$annotation" ]

  # Pod was genuinely recreated and wiped.
  local after_uid
  after_uid=$(kubectl --context "$CTX_A" -n "$FNS" \
    get pod "$target" -o jsonpath='{.metadata.uid}')
  [ "$before_uid" != "$after_uid" ]

  # wipe-targets cleared by reset phase (recovery/recover's own internal
  # reset at the end of its cycle).
  local wipe_targets
  wipe_targets=$(kubectl --context "$CTX_A" -n "$FNS" \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  assert_equal "$wipe_targets" ""

  kubectl --context "$CTX_A" -n "$FNS" wait pod "$target" \
    --for=condition=Ready --timeout=180s >/dev/null 2>&1 || true
  _wait_for_rs_healthy "$FNS" "$target" "$CTX_A" 180
}
