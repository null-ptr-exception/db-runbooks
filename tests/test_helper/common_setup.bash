#!/usr/bin/env bash

# Load bats helper libraries
HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
load "${HELPER_DIR}/bats-support/load.bash"
load "${HELPER_DIR}/bats-assert/load.bash"

# ---------------------------------------------------------------------------
# common_setup — call from setup_file in each .bats file
#
# Sources .env, resolves test-client pod, sets URL variables.
# Usage:
#   setup_file() { common_setup; }                   # no token
#   setup_file() { common_setup --create-token; }    # with token
# ---------------------------------------------------------------------------
common_setup() {
  ROOT_DIR="$(cd "${HELPER_DIR}/../.." && pwd)"
  export ROOT_DIR

  # shellcheck source=/dev/null
  source "${ROOT_DIR}/.env"

  export DB_MODE="${DB_MODE:-single}"
  export ENABLE_MINIO="${ENABLE_MINIO:-false}"
  export USE_MARIADB_OPERATOR="${USE_MARIADB_OPERATOR:-true}"
  export CLUSTER_DBS_CONTEXT="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"

  export CLUSTER_DBS_IP
  export MARIADB_AQSH_URL="http://${CLUSTER_DBS_IP}:30081"
  export MONGODB_AQSH_URL="http://${CLUSTER_DBS_IP}:30082"
  export FEDAUTH_URL="http://${CLUSTER_AUTH_IP}:30080"

  if [[ "$DB_MODE" == "dual" ]]; then
    export CLUSTER_DBS_A_IP CLUSTER_DBS_B_IP
    export CLUSTER_MINIO_IP="${CLUSTER_MINIO_IP:-}"
    export MARIADB_AQSH_A_URL="http://${CLUSTER_DBS_A_IP}:30081"
    export MARIADB_AQSH_B_URL="http://${CLUSTER_DBS_B_IP}:30081"
    export MONGODB_AQSH_A_URL="http://${CLUSTER_DBS_A_IP}:30082"
    export MONGODB_AQSH_B_URL="http://${CLUSTER_DBS_B_IP}:30082"
  fi

  # Wait for test-client pod to be ready, then resolve its name
  kubectl --context kind-cluster-apps -n app-a wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context kind-cluster-apps -n app-a \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  export TEST_POD

  if [[ "${1:-}" == "--create-token" ]]; then
    # Long-running suites (e.g. recovery.bats: rollouts + 2 full recovers +
    # initial-sync waits) can exceed 30m — override via TOKEN_DURATION.
    export TOKEN
    TOKEN=$(kubectl --context kind-cluster-apps -n app-a create token test-client \
      --duration="${TOKEN_DURATION:-30m}")
  fi
}

# ---------------------------------------------------------------------------
# kexec <cmd>
#
# Runs a command inside the test-client pod via kubectl exec.
# ---------------------------------------------------------------------------
kexec() {
  kubectl --context kind-cluster-apps -n app-a exec "$TEST_POD" -- sh -c "$1"
}

# ---------------------------------------------------------------------------
# http_post <url> <json_body>
#
# Runs curl inside the test-client pod.
# Sets HTTP_CODE and HTTP_BODY (exported so @test blocks can read them).
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# wait_for_task <base_url> <task_id> [max_wait_seconds]
#
# Polls GET <base_url>/executions/<task_id> until status is completed or failed.
# Sets TASK_RESPONSE to the final JSON body.
# Returns 0 on completed, 1 on failed/timeout.
# ---------------------------------------------------------------------------
wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-540}"
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE

    status=$(echo "$TASK_RESPONSE" | jq -r '.status' 2>/dev/null || true)

    # Heartbeat for long-running async tasks to avoid "stuck" perception.
    echo "Task ${task_id} polling: status=${status:-unknown} elapsed=${elapsed}s/${max_wait}s" >&2

    if [[ "$status" == "completed" ]]; then
      return 0
    elif [[ "$status" == "failed" ]]; then
      echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2
      return 1
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

# ---------------------------------------------------------------------------
# _wait_for_ns_deleted <namespace>
#
# If the namespace exists and is Terminating, wait up to 180s for it to be
# fully removed before proceeding (deleting a namespace with several PVCs
# routinely takes more than 60s).
# ---------------------------------------------------------------------------
_wait_for_ns_deleted() {
  local namespace="$1" ctx="${2:-${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}}" elapsed=0
  while (( elapsed < 180 )); do
    local phase
    phase=$(kubectl --context "$ctx" get ns "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ -z "$phase" ]]; then
      return 0
    fi
    if [[ "$phase" != "Terminating" ]]; then
      return 0
    fi
    echo "Namespace ${namespace} is Terminating, waiting..."
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo "Namespace ${namespace} still Terminating after 180s" >&2
  return 1
}

# ---------------------------------------------------------------------------
# _wait_for_mongodb_primary <namespace> [context] [max_wait_seconds]
#
# Waits until MongoDB responds as writable primary from inside the pod.
# Tries without credentials first (RS test clusters with no auth), then
# with credentials (auth-enabled deployments).
# ---------------------------------------------------------------------------
_wait_for_mongodb_primary() {
  local namespace="$1"
  local ctx="${2:-${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}}"
  local max_wait="${3:-120}"
  local elapsed=0

  while (( elapsed < max_wait )); do
    local pod
    pod=$(kubectl --context "$ctx" -n "$namespace" get pod -l app=mongodb \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [[ -n "$pod" ]]; then
      # Check via rs.status() first — works even when connected to a secondary.
      # Falls back to db.hello() for standalone (no RS).
      local rs_check='try {
        var s = rs.status();
        var p = s.members && s.members.find(function(m){ return m.state===1 && m.health===1; });
        if (p) { quit(0); }
      } catch(e) {}
      var h = db.hello();
      if (h && (h.isWritablePrimary || h.ismaster)) { quit(0); }
      quit(1);'

      # Try without auth first (RS test clusters with --bind_ip_all, no --auth)
      if kubectl --context "$ctx" -n "$namespace" exec "$pod" -- mongosh --quiet --norc \
        "mongodb://localhost:27017/admin?serverSelectionTimeoutMS=2000" \
        --eval "$rs_check" \
        >/dev/null 2>&1; then
        return 0
      fi
      # Fallback: try with credentials (auth-enabled deployments)
      local user pass
      user=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
        -o jsonpath='{.data.MONGO_ROOT_USER}' 2>/dev/null | base64 -d || true)
      pass=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
        -o jsonpath='{.data.MONGO_ROOT_PASS}' 2>/dev/null | base64 -d || true)
      if [[ -n "$user" && -n "$pass" ]]; then
        if kubectl --context "$ctx" -n "$namespace" exec "$pod" -- mongosh --quiet --norc \
          "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=2000" \
          --eval "$rs_check" \
          >/dev/null 2>&1; then
          return 0
        fi
      fi
    fi

    sleep 3
    elapsed=$((elapsed + 3))
  done

  echo "MongoDB primary not ready in namespace ${namespace} after ${max_wait}s" >&2
  return 1
}

# ---------------------------------------------------------------------------
# _init_mongodb_rs <namespace> [context] [replicas]
#
# Initializes a MongoDB replica set named rs0 using rs.initiate().
# Idempotent: AlreadyInitialized is treated as success.
# ---------------------------------------------------------------------------
_init_mongodb_rs() {
  local namespace="$1"
  local ctx="${2:-${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}}"
  local replicas="${3:-3}"

  echo "Initializing MongoDB replica set rs0 in ${namespace} (${replicas} members)..."

  # Wait for mongodb-0 to be reachable before initiating
  kubectl --context "$ctx" -n "$namespace" wait pod mongodb-0 \
    --for=condition=Ready --timeout=120s || {
    echo "mongodb-0 not ready after 120s" >&2
    return 1
  }

  # Member 0 gets priority 2 so the primary lands deterministically on
  # mongodb-0 — tests (e.g. recovery G7) depend on knowing who is primary.
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
        if (e.codeName === 'AlreadyInitialized') {
          print('RS already initialized');
        } else {
          print('RS init error: ' + e.message);
          quit(1);
        }
      }
    " || {
    echo "RS initiate failed" >&2
    return 1
  }
  echo "RS initiated — allowing time for primary election..."
  sleep 8
}

# ---------------------------------------------------------------------------
# _find_primary_pod <namespace> [context]
#
# Returns the name of the pod that is currently the RS writable primary.
# Tries each pod (mongodb-0 first) using db.hello().isWritablePrimary.
# Prints to stdout; returns 0 on success, 1 if no primary found within 60s.
# ---------------------------------------------------------------------------
_find_primary_pod() {
  local namespace="$1"
  local ctx="${2:-${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}}"
  local elapsed=0 result

  while (( elapsed < 60 )); do
    result=$(kubectl --context "$ctx" -n "$namespace" exec mongodb-0 -- \
      mongosh --quiet --norc "mongodb://localhost:27017/admin" \
      --eval "
        try {
          var s = rs.status();
          var p = s.members && s.members.find(function(m){ return m.state===1; });
          if (p) { print(p.name.split('.')[0]); quit(0); }
        } catch(e) {}
        quit(1);" 2>/dev/null | grep -E '^mongodb-[0-9]+$' | tail -1 || true)
    if [[ -n "$result" ]]; then
      echo "$result"
      return 0
    fi
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "Could not find primary pod in ${namespace}" >&2
  return 1
}

# ---------------------------------------------------------------------------
# _wait_for_rs_healthy <namespace> <pod_name> [context] [max_wait_seconds]
#
# Waits until <pod_name> appears as a healthy (health=1) member in rs.status()
# as observed from mongodb-0.
# ---------------------------------------------------------------------------
_wait_for_rs_healthy() {
  local namespace="$1"
  local pod_name="$2"
  local ctx="${3:-${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}}"
  local max_wait="${4:-120}"
  local elapsed=0

  while (( elapsed < max_wait )); do
    local healthy
    healthy=$(kubectl --context "$ctx" -n "$namespace" exec mongodb-0 -- \
      mongosh --quiet --norc "mongodb://localhost:27017/admin" \
      --eval "
        try {
          var s = rs.status();
          var m = s.members && s.members.find(function(m){
            return m.name.indexOf('${pod_name}.') === 0 && m.health === 1;
          });
          print(m ? '1' : '0');
        } catch(e) { print('0'); }" 2>/dev/null | tail -1 | tr -d '\r' || echo "0")
    [[ "$healthy" == "1" ]] && return 0
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "Pod ${pod_name} not healthy in RS for ${namespace} after ${max_wait}s" >&2
  return 1
}

# ---------------------------------------------------------------------------
# deploy_mariadb <namespace>
#
# Creates namespace, RBAC RoleBinding, and MariaDB CR.
# Waits for the MariaDB instance to be ready.
# ---------------------------------------------------------------------------
deploy_mariadb() {
  local namespace="$1"
  local ctx="${2:-${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}}"

  _wait_for_ns_deleted "$namespace" "$ctx"
  kubectl --context "$ctx" create ns "$namespace" --dry-run=client -o yaml \
    | kubectl --context "$ctx" apply -f -

  kubectl --context "$ctx" -n "$namespace" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: aqsh-mariadb-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aqsh-mariadb-manager
subjects:
  - kind: ServiceAccount
    name: kube-auth-proxy
    namespace: db-ops
EOF

  if [[ "${USE_MARIADB_OPERATOR:-true}" == "true" ]]; then
    kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/${namespace}.yaml"
    echo "Waiting for MariaDB in ${namespace} to be ready..."
    if ! kubectl --context "$ctx" -n "$namespace" wait \
      --for=condition=Ready mariadb/mariadb --timeout=300s 2>/dev/null; then
      echo "MariaDB CR not ready after 300s. Checking status..."
      kubectl --context "$ctx" -n "$namespace" get mariadb mariadb -o yaml | tail -50
      kubectl --context "$ctx" -n "$namespace" get pods -l app.kubernetes.io/instance=mariadb
      kubectl --context "$ctx" -n "$namespace" describe pod -l app.kubernetes.io/instance=mariadb | tail -30
      return 1
    fi
  else
    # Extract only the Secret document from the operator yaml, then apply native StatefulSet
    python3 -c "
import sys, re
docs = open('${ROOT_DIR}/k8s/cluster-dbs/mariadb/${namespace}.yaml').read().split('\n---\n')
for doc in docs:
    if re.search(r'^kind:\s*Secret', doc, re.MULTILINE):
        print(doc)
" | kubectl --context "$ctx" -n "$namespace" apply -f -
    kubectl --context "$ctx" -n "$namespace" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/statefulset.yaml"
    kubectl --context "$ctx" -n "$namespace" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/nodeport-service.yaml"
    echo "Waiting for MariaDB in ${namespace} to be ready..."
    if ! kubectl --context "$ctx" -n "$namespace" rollout status statefulset/mariadb --timeout=240s 2>/dev/null; then
      echo "Rollout status timed out, falling back to wait pod..."
      kubectl --context "$ctx" -n "$namespace" wait pod \
        -l app.kubernetes.io/name=mariadb --for=condition=Ready --timeout=60s || {
        echo "MariaDB pod still not ready. Checking pod status..."
        kubectl --context "$ctx" -n "$namespace" get pods -l app.kubernetes.io/name=mariadb
        kubectl --context "$ctx" -n "$namespace" describe pod -l app.kubernetes.io/name=mariadb | tail -30
        return 1
      }
    fi
  fi
}

# ---------------------------------------------------------------------------
# deploy_mongodb <namespace>
#
# Creates namespace, RBAC RoleBinding, credentials secret, and MongoDB StatefulSet.
# Waits for the MongoDB pod to be ready.
# ---------------------------------------------------------------------------
deploy_mongodb() {
  local namespace="$1"
  local ctx="${2:-${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}}"

  _wait_for_ns_deleted "$namespace" "$ctx"
  kubectl --context "$ctx" create ns "$namespace" --dry-run=client -o yaml \
    | kubectl --context "$ctx" apply -f -

  kubectl --context "$ctx" -n "$namespace" apply -f - <<EOF
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
    namespace: db-ops
EOF

  if ! kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials &>/dev/null; then
    kubectl --context "$ctx" -n "$namespace" create secret generic mongodb-credentials \
      --from-literal="MONGO_ROOT_USER=${namespace}-admin" \
      --from-literal="MONGO_ROOT_PASS=$(openssl rand -base64 16 | tr -d '=+/')"
  fi

  kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/${namespace}.yaml"
  kubectl --context "$ctx" -n "$namespace" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/nodeport-service.yaml"

  echo "Waiting for MongoDB in ${namespace} to be ready..."
  if ! kubectl --context "$ctx" -n "$namespace" rollout status statefulset/mongodb --timeout=300s 2>/dev/null; then
    echo "Rollout status timed out, falling back to wait pod..."
    kubectl --context "$ctx" -n "$namespace" wait pod \
      -l app=mongodb --for=condition=Ready --timeout=60s || {
      echo "MongoDB pod still not ready. Checking pod status..."
      kubectl --context "$ctx" -n "$namespace" get pods -l app=mongodb
      kubectl --context "$ctx" -n "$namespace" describe pod -l app=mongodb | tail -30
      return 1
    }
  fi

  # Initialize replica set if this is a multi-member deployment
  local replicas
  replicas=$(kubectl --context "$ctx" -n "$namespace" \
    get statefulset mongodb -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
  if [[ "${replicas:-1}" -gt 1 ]]; then
    _init_mongodb_rs "$namespace" "$ctx" "$replicas"
  fi

  echo "Waiting for MongoDB primary election in ${namespace}..."
  _wait_for_mongodb_primary "$namespace" "$ctx" 180
}

# ---------------------------------------------------------------------------
# deploy_mongodb_dual <namespace>
#
# Deploys MongoDB into <namespace> on both cluster-dbs-a and cluster-dbs-b.
# ---------------------------------------------------------------------------
deploy_mongodb_dual() {
  local namespace="$1"
  local ctx_a="kind-cluster-dbs-a"
  local ctx_b="kind-cluster-dbs-b"

  deploy_mongodb "$namespace" "$ctx_a"
  deploy_mongodb "$namespace" "$ctx_b"

  echo "Deploying nginx-proxy for cross-cluster connectivity..."

  PEER_DBS_IP="$CLUSTER_DBS_B_IP" envsubst < "${ROOT_DIR}/k8s/nginx-proxy/configmap.yaml.tpl" \
    | kubectl --context "$ctx_a" apply -f -
  kubectl --context "$ctx_a" apply -f "${ROOT_DIR}/k8s/nginx-proxy/deployment.yaml"

  PEER_DBS_IP="$CLUSTER_DBS_A_IP" envsubst < "${ROOT_DIR}/k8s/nginx-proxy/configmap.yaml.tpl" \
    | kubectl --context "$ctx_b" apply -f -
  kubectl --context "$ctx_b" apply -f "${ROOT_DIR}/k8s/nginx-proxy/deployment.yaml"

  echo "Waiting for nginx-proxy on both clusters..."
  kubectl --context "$ctx_a" -n db-ops wait pod \
    -l app=nginx-proxy --for=condition=Ready --timeout=60s || true
  kubectl --context "$ctx_b" -n db-ops wait pod \
    -l app=nginx-proxy --for=condition=Ready --timeout=60s || true
}

# ---------------------------------------------------------------------------
# deploy_mariadb_dual <namespace>
#
# Deploys MariaDB into <namespace> on both cluster-dbs-a and cluster-dbs-b.
# ---------------------------------------------------------------------------
deploy_mariadb_dual() {
  local namespace="$1"
  local ctx_a="kind-cluster-dbs-a"
  local ctx_b="kind-cluster-dbs-b"

  for ctx in "$ctx_a" "$ctx_b"; do
    _wait_for_ns_deleted "$namespace" "$ctx"
    kubectl --context "$ctx" create ns "$namespace" --dry-run=client -o yaml \
      | kubectl --context "$ctx" apply -f -

    kubectl --context "$ctx" -n "$namespace" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: aqsh-mariadb-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aqsh-mariadb-manager
subjects:
  - kind: ServiceAccount
    name: kube-auth-proxy
    namespace: db-ops
EOF

    if [[ "${USE_MARIADB_OPERATOR:-true}" == "true" ]]; then
      kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/${namespace}.yaml"
      kubectl --context "$ctx" -n "$namespace" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/nodeport-service.yaml"
    else
      python3 -c "
import sys, re
docs = open('${ROOT_DIR}/k8s/cluster-dbs/mariadb/${namespace}.yaml').read().split('\n---\n')
for doc in docs:
    if re.search(r'^kind:\s*Secret', doc, re.MULTILINE):
        print(doc)
" | kubectl --context "$ctx" -n "$namespace" apply -f -
      kubectl --context "$ctx" -n "$namespace" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/statefulset.yaml"
      kubectl --context "$ctx" -n "$namespace" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/nodeport-service.yaml"
    fi
  done

  echo "Waiting for MariaDB in ${namespace} on both clusters..."
  for ctx in "$ctx_a" "$ctx_b"; do
    if [[ "${USE_MARIADB_OPERATOR:-true}" == "true" ]]; then
      if ! kubectl --context "$ctx" -n "$namespace" wait \
        --for=condition=Ready mariadb/mariadb --timeout=300s 2>/dev/null; then
        echo "MariaDB CR not ready on $ctx after 300s. Checking status..."
        kubectl --context "$ctx" -n "$namespace" get mariadb mariadb -o yaml | tail -50
        kubectl --context "$ctx" -n "$namespace" get pods -l app.kubernetes.io/instance=mariadb
        kubectl --context "$ctx" -n "$namespace" describe pod -l app.kubernetes.io/instance=mariadb | tail -30
        return 1
      fi
    else
      if ! kubectl --context "$ctx" -n "$namespace" rollout status statefulset/mariadb --timeout=240s 2>/dev/null; then
        echo "Rollout status timed out on $ctx, falling back to wait pod..."
        kubectl --context "$ctx" -n "$namespace" wait pod \
          -l app.kubernetes.io/name=mariadb --for=condition=Ready --timeout=60s || {
          echo "MariaDB pod still not ready on $ctx. Checking pod status..."
          kubectl --context "$ctx" -n "$namespace" get pods -l app.kubernetes.io/name=mariadb
          kubectl --context "$ctx" -n "$namespace" describe pod -l app.kubernetes.io/name=mariadb | tail -30
          return 1
        }
      fi
    fi
  done

  echo "Deploying nginx-proxy for cross-cluster connectivity..."

  PEER_DBS_IP="$CLUSTER_DBS_B_IP" envsubst < "${ROOT_DIR}/k8s/nginx-proxy/configmap.yaml.tpl" \
    | kubectl --context "$ctx_a" apply -f -
  kubectl --context "$ctx_a" apply -f "${ROOT_DIR}/k8s/nginx-proxy/deployment.yaml"

  PEER_DBS_IP="$CLUSTER_DBS_A_IP" envsubst < "${ROOT_DIR}/k8s/nginx-proxy/configmap.yaml.tpl" \
    | kubectl --context "$ctx_b" apply -f -
  kubectl --context "$ctx_b" apply -f "${ROOT_DIR}/k8s/nginx-proxy/deployment.yaml"

  echo "Waiting for nginx-proxy on both clusters..."
  kubectl --context "$ctx_a" -n db-ops wait pod \
    -l app=nginx-proxy --for=condition=Ready --timeout=60s || true
  kubectl --context "$ctx_b" -n db-ops wait pod \
    -l app=nginx-proxy --for=condition=Ready --timeout=60s || true
}
