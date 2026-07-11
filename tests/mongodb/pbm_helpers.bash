#!/usr/bin/env bash
# =============================================================================
# Shared helpers for the pbm_* bats files (pbm.bats, pbm_pitr.bats,
# pbm_bitnami.bats). Test-local fixture/HTTP plumbing — NOT a task lib.
#
# Fixture model (fcv_bitnami.bats precedent): each pbm suite creates its own
# namespace with an inline 2-member replica-set StatefulSet named "mongodb"
# (the aqsh-mongo-manager ClusterRole pins that name, so only a namespace-
# scoped RoleBinding is needed) plus a pbm-agent sidecar per pod and the
# `minio` S3-credentials secret the pbm/* tasks read. mongo-1 stays untouched
# — it is used only as the agent-less negative fixture.
#
# The pbm-agent container runs under a retry wrapper instead of letting the
# process crashloop: before rs.initiate the agent exits ("node is not in
# replica set"), and CrashLoopBackOff on pod-0 + OrderedReady would deadlock
# the rollout. podManagementPolicy: Parallel for the same reason.
# =============================================================================

PBM_IMAGE="percona/percona-backup-mongodb:2.15.0"

# ---------------------------------------------------------------------------
# _pbm_common_env — contexts, aqsh URL, test-client pod + bearer token.
# ---------------------------------------------------------------------------
_pbm_common_env() {
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

  export CTX_A CTX_B NS AQSH_URL TEST_POD TOKEN PBM_IMAGE
}

# ---------------------------------------------------------------------------
# HTTP plumbing — trimmed copies of fcv.bats's patterns.
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

# run_pbm_task <endpoint> <json_body> [max_wait]
# Submits /tasks/pbm%2F<endpoint>, waits for a terminal state (completed OR
# failed — failure-path tests assert on TASK_STATUS/RESULT_DATA themselves),
# exports TASK_STATUS + RESULT_DATA.
run_pbm_task() {
  local endpoint="$1" body="$2" max_wait="${3:-300}"
  http_post "${AQSH_URL}/tasks/pbm%2F${endpoint}" "$body"
  [[ "$HTTP_CODE" == "202" ]] || { echo "submit pbm/${endpoint} got HTTP ${HTTP_CODE}: ${HTTP_BODY}" >&2; return 1; }
  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task_any "$AQSH_URL" "$task_id" "$max_wait" || return 1
  RESULT_DATA=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  export RESULT_DATA
}

# ---------------------------------------------------------------------------
# Fixture: namespace + secrets + RoleBinding + RS StatefulSet with pbm-agent.
# _pbm_apply_fixture <namespace> <official|bitnami>
# ---------------------------------------------------------------------------
_pbm_apply_fixture() {
  local sns="${1:?namespace required}" variant="${2:-official}"
  local ctx="$CTX_A"

  kubectl --context "$ctx" create namespace "$sns" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  # S3 credentials the pbm/* tasks read (must match the chart's MinIO root
  # credentials — see tests/chart/values.yaml minio.* and mongodb.backupSecret).
  kubectl --context "$ctx" -n "$sns" create secret generic minio \
    --from-literal=access-key-id=minioadmin \
    --from-literal=secret-access-key=minioadmin-changeme-prod \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  # MongoDB credentials + variant-specific wiring.
  local user_key pass_key mongo_env datadir_yaml run_as init_yaml mongod_args
  if [[ "$variant" == "bitnami" ]]; then
    user_key="root-user"; pass_key="root-password"; run_as=1001
    kubectl --context "$ctx" -n "$sns" create secret generic mongodb-credentials \
      --from-literal="${user_key}=bitnamiadmin" --from-literal="${pass_key}=testpass321" \
      --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -
    mongo_env="
            - name: MONGODB_ROOT_USER
              valueFrom:
                secretKeyRef: {name: mongodb-credentials, key: ${user_key}}
            - name: MONGODB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef: {name: mongodb-credentials, key: ${pass_key}}"
    mongod_args='["--replSet", "rs0", "--bind_ip_all", "--dbpath", "/bitnami/mongodb/data/db"]'
    datadir_yaml="
            - name: datadir
              mountPath: /bitnami/mongodb"
    init_yaml="
      initContainers:
        - name: prepare-dbpath
          image: mongo:7
          command: [\"sh\", \"-c\", \"mkdir -p /bitnami/mongodb/data/db\"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: [\"ALL\"]}
          volumeMounts:
            - name: datadir
              mountPath: /bitnami/mongodb"
  else
    user_key="MONGO_ROOT_USER"; pass_key="MONGO_ROOT_PASS"; run_as=999
    kubectl --context "$ctx" -n "$sns" create secret generic mongodb-credentials \
      --from-literal="${user_key}=mongoadmin" --from-literal="${pass_key}=testpass123" \
      --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -
    mongo_env="
            - name: MONGO_INITDB_ROOT_USERNAME
              valueFrom:
                secretKeyRef: {name: mongodb-credentials, key: ${user_key}}
            - name: MONGO_INITDB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef: {name: mongodb-credentials, key: ${pass_key}}"
    mongod_args='["--replSet", "rs0", "--bind_ip_all"]'
    datadir_yaml="
            - name: datadir
              mountPath: /data/db"
    init_yaml=""
  fi

  # Namespace-scoped RoleBinding to the existing ClusterRole (default object
  # names, so the pinned resourceNames already cover this fixture).
  kubectl --context "$ctx" -n "$sns" apply -f - <<'RB_EOF'
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

  kubectl --context "$ctx" -n "$sns" apply -f - <<STS_EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: ${sns}
spec:
  replicas: 2
  podManagementPolicy: Parallel
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
        runAsUser: ${run_as}
        runAsGroup: ${run_as}
        fsGroup: ${run_as}${init_yaml}
      containers:
        - name: mongodb
          image: mongo:7
          command: ["mongod"]
          args: ${mongod_args}
          env:${mongo_env}
          ports:
            - containerPort: 27017
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: ["ALL"]}
            seccompProfile: {type: RuntimeDefault}
          readinessProbe:
            exec:
              command: ["mongosh", "--quiet", "--norc", "--eval", "db.adminCommand('ping').ok"]
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          volumeMounts:${datadir_yaml}
        - name: pbm-agent
          image: ${PBM_IMAGE}
          # Retry wrapper: pbm-agent exits until the RS is initiated; a plain
          # crashloop on pod-0 would deadlock an OrderedReady rollout and
          # back off for minutes. The wrapper keeps the container Running.
          command: ["sh", "-c", "until pbm-agent; do echo 'pbm-agent exited, retrying in 5s...'; sleep 5; done"]
          env:
            - name: PBM_AGENT_MONGO_USER
              valueFrom:
                secretKeyRef: {name: mongodb-credentials, key: ${user_key}}
            - name: PBM_AGENT_MONGO_PASS
              valueFrom:
                secretKeyRef: {name: mongodb-credentials, key: ${pass_key}}
            - name: PBM_MONGODB_URI
              value: "mongodb://\$(PBM_AGENT_MONGO_USER):\$(PBM_AGENT_MONGO_PASS)@localhost:27017"
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: ["ALL"]}
            seccompProfile: {type: RuntimeDefault}
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
  namespace: ${sns}
spec:
  clusterIP: None
  selector:
    app: mongodb
  ports:
    - port: 27017
      targetPort: 27017
STS_EOF

  echo "Waiting for 2-replica PBM fixture rollout in ${sns} (${variant})..."
  kubectl --context "$ctx" -n "$sns" rollout status statefulset/mongodb --timeout=300s

  _pbm_init_rs "$sns" 2
  _pbm_wait_for_primary "$sns" 180
  _pbm_create_root_user "$sns" "$variant"
  _pbm_wait_agents "$sns" 2 180
}

# ---------------------------------------------------------------------------
# _pbm_init_rs <namespace> [replicas] — equal-priority rs.initiate.
# ---------------------------------------------------------------------------
_pbm_init_rs() {
  local namespace="$1" replicas="${2:-2}"
  echo "Initializing MongoDB replica set rs0 in ${namespace} (${replicas} members)..."
  kubectl --context "$CTX_A" -n "$namespace" wait pod mongodb-0 \
    --for=condition=Ready --timeout=180s || {
    echo "mongodb-0 not ready after 180s" >&2; return 1
  }
  local members="" i
  for i in $(seq 0 $((replicas - 1))); do
    members+="{_id:${i},host:'mongodb-${i}.mongodb.${namespace}.svc.cluster.local:27017'},"
  done
  members="${members%,}"
  kubectl --context "$CTX_A" -n "$namespace" exec mongodb-0 -c mongodb -- mongosh --quiet --norc \
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

_pbm_wait_for_primary() {
  local namespace="$1" max_wait="${2:-120}"
  local elapsed=0
  while (( elapsed < max_wait )); do
    local rs_check='try {
      var s = rs.status();
      var p = s.members && s.members.find(function(m){ return m.state===1 && m.health===1; });
      if (p) { quit(0); }
    } catch(e) {}
    quit(1);'
    if kubectl --context "$CTX_A" -n "$namespace" exec mongodb-0 -c mongodb -- mongosh --quiet --norc \
      "mongodb://localhost:27017/admin?serverSelectionTimeoutMS=2000" \
      --eval "$rs_check" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  echo "MongoDB primary not ready in namespace ${namespace} after ${max_wait}s" >&2
  return 1
}

# mongod bypasses docker-entrypoint.sh (command: mongod), so the root user is
# created explicitly; equal-priority RS -> try every pod, primary accepts it.
_pbm_create_root_user() {
  local namespace="$1" variant="${2:-official}"
  local user pass
  if [[ "$variant" == "bitnami" ]]; then
    user="bitnamiadmin"; pass="testpass321"
  else
    user="mongoadmin"; pass="testpass123"
  fi
  local elapsed=0 ready=false pod
  while (( elapsed < 60 )); do
    for pod in mongodb-0 mongodb-1; do
      if kubectl --context "$CTX_A" -n "$namespace" exec "$pod" -c mongodb -- mongosh --quiet --norc \
        "mongodb://localhost:27017/admin" --eval "
          try {
            db.getSiblingDB('admin').createUser({user:'${user}', pwd:'${pass}', roles:[{role:'root',db:'admin'}]});
            print('root user created');
          } catch(e) {
            if (/already exists/.test(e.message)) { print('root user exists'); }
            else { throw e; }
          }" >/dev/null 2>&1; then
        ready=true
        break
      fi
    done
    [[ "$ready" == true ]] && break
    sleep 5; elapsed=$((elapsed + 5))
  done
  if [[ "$ready" != true ]]; then
    echo "Failed to create/verify root user in ${namespace} after 60s" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# _pbm_agent_exec <namespace> <pbm args...> — run the pbm CLI directly in the
# sidecar (test-side verification only; the tasks under test do their own
# exec through aqsh).
# ---------------------------------------------------------------------------
_pbm_agent_exec() {
  local namespace="$1"; shift
  kubectl --context "$CTX_A" -n "$namespace" exec mongodb-0 -c pbm-agent -- pbm "$@"
}

# _pbm_wait_agents <namespace> <expected_nodes> <timeout> — poll pbm status
# until the expected number of agents have registered heartbeats.
_pbm_wait_agents() {
  local namespace="$1" expected="${2:-2}" max_wait="${3:-180}"
  local elapsed=0
  echo "Waiting for ${expected} pbm agent(s) to register in ${namespace}..."
  while (( elapsed < max_wait )); do
    if _pbm_agent_exec "$namespace" status -o json 2>/dev/null \
        | jq -e --argjson n "$expected" '[.cluster[]?.nodes[]?] | length >= $n' >/dev/null 2>&1; then
      return 0
    fi
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "pbm agents not registered in ${namespace} after ${max_wait}s" >&2
  return 1
}

# ---------------------------------------------------------------------------
# _pbm_mongo_eval <namespace> <js> — run mongosh against the RS (routes to
# the primary) from inside mongodb-0.
# ---------------------------------------------------------------------------
_pbm_mongo_eval() {
  local namespace="$1" js="$2"
  local uri="mongodb://mongodb-0.mongodb.${namespace}.svc.cluster.local:27017,mongodb-1.mongodb.${namespace}.svc.cluster.local:27017/admin?replicaSet=rs0"
  kubectl --context "$CTX_A" -n "$namespace" exec mongodb-0 -c mongodb -- \
    mongosh --quiet --norc "$uri" --eval "$js"
}

# ---------------------------------------------------------------------------
# _pbm_minio_ls <prefix> — list what actually landed in MinIO under
# db-backups/<prefix> (single-node MinIO keeps objects as directories under
# /data/<bucket>/). Prints the entries; rc 1 when the prefix is empty/absent.
# ---------------------------------------------------------------------------
_pbm_minio_ls() {
  local prefix="$1"
  local out
  out=$(kubectl --context "$CTX_B" -n minio exec deploy/minio -- \
    sh -c "ls -A /data/db-backups/${prefix} 2>/dev/null") || return 1
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}
