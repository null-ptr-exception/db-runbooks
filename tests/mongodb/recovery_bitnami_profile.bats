#!/usr/bin/env bats
# =============================================================================
# E2E proof that `setup-data-recovery.sh --profile bitnami` actually works:
# volume name "datadir", mount path "/bitnami/mongodb", wipe path
# "/bitnami/mongodb/data/db", and runAsUser 1001 all function through the
# real aqsh recovery/pre-check and recovery/recover tasks against a real
# StatefulSet.
#
# recovery.bats and recovery_custom_naming.bats only ever exercise
# `--profile standard` against mongo-1's /data/db layout — until now,
# --profile bitnami was unverified anywhere except mocked unit tests
# (tests/unit/mongodb/setup-data-recovery.bats and the path-mismatch cases
# in tests/unit/mongodb/recovery.bats).
#
# This deploys a SEPARATE 2-replica RS in its own "mongo-bitnami" namespace,
# using the mongo:7 image (not the real bitnami/mongodb image, which this
# repo does not otherwise pull) reshaped to match the Bitnami chart's layout:
# volumeClaimTemplate "datadir" mounted at /bitnami/mongodb, dbpath nested
# two levels under that mount, runAsUser/runAsGroup/fsGroup 1001. This proves
# the path/volume/uid mechanics --profile bitnami controls, independent of
# whichever container image a real deployment happens to use.
#
# It coexists with mongo-1 (profile=standard) to prove a second deployment
# can legitimately use a different profile with zero naming/path inputs —
# data_path/mount_path are not task inputs (see CLAUDE.md "Configuration
# Layers"); detection reads the real --dbpath this profile's mongod was
# started with directly, no per-call override needed.
#
# Reuses mongo-1's own object names (mongodb / mongodb-credentials /
# mongodb-recovery-config) but in namespace mongo-bitnami, so the existing
# aqsh-mongo-manager ClusterRole's resourceNames already match by name —
# only a new namespace-scoped RoleBinding is needed, no ClusterRole change.
#
# Fully self-contained: setup_file creates the mongo-bitnami namespace and
# all its resources; teardown_file deletes the namespace. No other test file
# reads or writes mongo-bitnami.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  BNS="mongo-bitnami"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=1h)

  export CTX_A CTX_B NS BNS AQSH_URL TEST_POD TOKEN

  local ctx="$CTX_A"

  kubectl --context "$ctx" create namespace "$BNS" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  # Same object name as mongo-1's root credentials secret — the existing
  # aqsh-mongo-manager ClusterRole's resourceNames already cover it.
  kubectl --context "$ctx" -n "$BNS" create secret generic mongodb-credentials \
    --from-literal=MONGO_ROOT_USER=mongoadmin --from-literal=MONGO_ROOT_PASS=testpass123 \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  # Grant aqsh's SA the same ClusterRole within mongo-bitnami. RoleBinding
  # only — no ClusterRole change, since resourceNames match "mongodb" /
  # "mongodb-credentials" / "mongodb-recovery-config" regardless of namespace.
  kubectl --context "$ctx" -n "$BNS" apply -f - <<'RB_EOF'
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

  # Bitnami-shaped layout: volumeClaimTemplate "datadir" mounted at
  # /bitnami/mongodb, dbpath nested two levels under that mount (matching
  # the real Bitnami chart), so --profile bitnami's WIPE_PATH/MOUNT_PATH are
  # exercised exactly as setup-data-recovery.sh expects. A small init
  # container creates the nested dbpath dir on first boot (the real Bitnami
  # entrypoint does this; mongod itself will not create missing parents).
  # mongod is started directly (bypassing docker-entrypoint.sh, same as
  # recovery.bats's RS), so the root user is created via createUser below.
  kubectl --context "$ctx" -n "$BNS" apply -f - <<STS_EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: ${BNS}
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
        runAsUser: 1001
        runAsGroup: 1001
        fsGroup: 1001
      initContainers:
        - name: init-bitnami-dir
          image: mongo:7
          command: ["/bin/bash", "-c", "mkdir -p /bitnami/mongodb/data/db"]
          volumeMounts:
            - name: datadir
              mountPath: /bitnami/mongodb
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
            readOnlyRootFilesystem: false
      containers:
        - name: mongodb
          image: mongo:7
          command: ["mongod"]
          args: ["--replSet", "rs0", "--bind_ip_all", "--dbpath", "/bitnami/mongodb/data/db"]
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
            - name: datadir
              mountPath: /bitnami/mongodb
  volumeClaimTemplates:
    - metadata:
        name: datadir
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
  namespace: ${BNS}
spec:
  clusterIP: None
  selector:
    app: mongodb
  ports:
    - port: 27017
      targetPort: 27017
STS_EOF

  echo "Waiting for 2-replica Bitnami-profile RS rollout in ${BNS}..."
  kubectl --context "$ctx" -n "$BNS" rollout status statefulset/mongodb --timeout=300s

  _init_rs "$BNS" "$ctx" 2
  _wait_for_primary "$BNS" "$ctx" 180

  local mongo_user mongo_pass
  { IFS= read -r mongo_user; IFS= read -r mongo_pass; } < <(_mongo_creds "$BNS" "$ctx")
  # _init_rs gives all members equal priority (no deterministic primary —
  # see its header comment), so createUser must be tried against every pod
  # each round: whichever one is actually primary accepts it, the other
  # fails fast with "not primary" rather than blocking the round.
  local user_elapsed=0 user_ready=false pod
  while (( user_elapsed < 60 )); do
    for pod in mongodb-0 mongodb-1; do
      if kubectl --context "$ctx" -n "$BNS" exec "$pod" -- mongosh --quiet --norc \
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
    done
    [[ "$user_ready" == true ]] && break
    sleep 5; user_elapsed=$((user_elapsed + 5))
  done
  if [[ "$user_ready" != true ]]; then
    echo "Failed to create/verify root user in ${BNS} after 60s" >&2
    return 1
  fi

  # The script under test: applies the recovery ConfigMap + patches the STS
  # with the data-recovery init container shaped by --profile bitnami.
  "${BATS_TEST_DIRNAME}/../../aqsh-tasks/scripts/mongodb/recovery/setup-data-recovery.sh" \
    --context "$ctx" --namespace "$BNS" --sts mongodb --profile bitnami

  echo "Waiting for MongoDB to stabilise after init-container patch..."
  kubectl --context "$ctx" -n "$BNS" rollout status statefulset/mongodb --timeout=300s || true
  _wait_for_primary "$BNS" "$ctx" 120
}

teardown_file() {
  local ctx="kind-cluster-a"
  kubectl --context "$ctx" delete namespace "mongo-bitnami" --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

# ---------------------------------------------------------------------------
# Helpers — trimmed copies of recovery.bats's patterns (no need here for
# deterministic primary placement, since tests below discover the primary
# dynamically before picking a wipe target).
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
# _init_rs <namespace> [context] [replicas]
# Initializes a MongoDB replica set named rs0 with equal-priority members —
# unlike recovery.bats's _init_mongodb_rs, no deterministic primary is
# needed here since tests pick the wipe target dynamically.
# ---------------------------------------------------------------------------
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
# _mongo_creds <namespace> [context]
# Echo "user pass" for the mongodb-credentials secret.
# ---------------------------------------------------------------------------
_mongo_creds() {
  local namespace="$1" ctx="${2:-$CTX_A}"
  local user pass
  user=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  pass=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)
  printf '%s\n%s\n' "$user" "$pass"
}

# ---------------------------------------------------------------------------
# _wait_for_primary <namespace> [context] [max_wait]
# Waits until a MongoDB primary is available (tries without auth, then with).
# ---------------------------------------------------------------------------
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
      { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds "$namespace" "$ctx")
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
# _find_primary_pod <namespace> [context]
# Return the name of the pod that is currently the RS primary, among
# mongodb-0/mongodb-1 (this file's 2-replica RS).
# ---------------------------------------------------------------------------
_find_primary_pod() {
  local namespace="$1" ctx="${2:-$CTX_A}"
  local user pass
  { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds "$namespace" "$ctx")
  local pod
  for pod in mongodb-0 mongodb-1; do
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
# ---------------------------------------------------------------------------
_wait_for_rs_healthy() {
  local namespace="$1" target_pod="$2"
  local ctx="${3:-$CTX_A}" max_wait="${4:-180}"
  local user pass
  { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds "$namespace" "$ctx")
  local probe_pod
  for p in mongodb-0 mongodb-1; do
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

# ---------------------------------------------------------------------------
# _wipe_target <namespace> [context]
# Echo a non-primary pod name, suitable as a safe recovery/wipe target.
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

# ── G1: profile selection actually wired up the bitnami init container ──────

@test "G1 reports the data-recovery init container present after --profile bitnami" {
  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    "{\"namespace\":\"${BNS}\",\"target_pod\":\"mongodb-1\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 120

  local result g1_pass
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  g1_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G1") | .pass' 2>/dev/null || echo "null")
  assert_equal "$g1_pass" "true"
}

# ── recovery/pre-check: full gate pipeline against the real Bitnami layout ──

@test "recovery/pre-check passes all 8 gates against the Bitnami-profile layout via live detection" {
  local target
  target=$(_wipe_target "$BNS" "$CTX_A")

  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    "{\"namespace\":\"${BNS}\",\"target_pod\":\"${target}\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 120

  local result fail_count gate_count
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  fail_count=$(echo "$result" | jq -r '.fail // "missing"')
  gate_count=$(echo "$result" | jq '[.gates[] | select(.gate)] | length' 2>/dev/null || echo "0")
  [ "$gate_count" -ge 8 ] || { echo "gates: $result" >&2; false; }
  [ "$fail_count" = "0" ] || { echo "gates: $result" >&2; false; }

  # G5 must have measured real data against the bitnami dbpath (not the
  # skipped-warn data_mb=0 path from recovery.bats's wrong-profile tests).
  local g5_data_mb
  g5_data_mb=$(echo "$result" | jq -r '.gates[] | select(.gate=="G5") | .data_mb')
  [ "${g5_data_mb:-0}" -gt 0 ]
}

# ── recovery/recover: the real proof — wipe + restart under runAsUser 1001 ──

@test "recovery/recover wipes a Bitnami-profile secondary and it rejoins as healthy SECONDARY" {
  local target
  target=$(_wipe_target "$BNS" "$CTX_A")
  echo "Wipe target: ${target}" >&2

  local before_uid
  before_uid=$(kubectl --context "$CTX_A" -n "$BNS" \
    get pod "$target" -o jsonpath='{.metadata.uid}')

  http_post "${AQSH_URL}/tasks/recovery%2Frecover" \
    "{\"namespace\":\"${BNS}\",\"target_pod\":\"${target}\",\"wait_timeout\":\"300\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 540

  local result reached
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  reached=$(echo "$result" | jq -r '.reached_running // empty')
  assert_equal "$reached" "true"

  # Pod was genuinely recreated (init container ran under runAsUser 1001 and
  # actually deleted files at /bitnami/mongodb/data/db before mongod restarted)
  local after_uid
  after_uid=$(kubectl --context "$CTX_A" -n "$BNS" \
    get pod "$target" -o jsonpath='{.metadata.uid}')
  [ "$before_uid" != "$after_uid" ]

  # wipe-targets cleared by reset phase
  local wipe_targets
  wipe_targets=$(kubectl --context "$CTX_A" -n "$BNS" \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  assert_equal "$wipe_targets" ""

  # Wait for the wiped pod to finish initial sync and rejoin RS healthy —
  # this only succeeds if mongod could actually start and write to
  # /bitnami/mongodb/data/db as uid 1001 after the wipe.
  kubectl --context "$CTX_A" -n "$BNS" wait pod "$target" \
    --for=condition=Ready --timeout=180s >/dev/null 2>&1 || true
  _wait_for_rs_healthy "$BNS" "$target" "$CTX_A" 180
}
