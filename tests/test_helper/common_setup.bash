#!/usr/bin/env bash

# Load bats helper libraries
HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
load "${HELPER_DIR}/bats-support/load.bash"
load "${HELPER_DIR}/bats-assert/load.bash"

# ---------------------------------------------------------------------------
# common_setup — call from setup_file in each .bats file
#
# Sources .env, sets URL variables, optionally creates a TOKEN.
# Usage:
#   setup_file() { common_setup; }                   # no token
#   setup_file() { common_setup --create-token; }    # with token
# ---------------------------------------------------------------------------
common_setup() {
  ROOT_DIR="$(cd "${HELPER_DIR}/../.." && pwd)"
  export ROOT_DIR

  # shellcheck source=/dev/null
  source "${ROOT_DIR}/.env"

  export MARIADB_AQSH_URL="http://127.0.0.1:30081"
  export MONGODB_AQSH_URL="http://127.0.0.1:30082"
  export FEDAUTH_URL="http://127.0.0.1:30080"
  export CLUSTER_DBS_IP

  if [[ "${1:-}" == "--create-token" ]]; then
    export TOKEN
    TOKEN=$(kubectl --context kind-cluster-apps -n app-a create token test-client --duration=10m)
  fi
}

# ---------------------------------------------------------------------------
# http_post <url> <json_body>
#
# Sets HTTP_CODE and HTTP_BODY (exported so @test blocks can read them).
# ---------------------------------------------------------------------------
http_post() {
  local url="$1" body="$2"
  local response
  response=$(curl -s -w '\n%{http_code}' \
    -X POST "$url" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body")

  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

# ---------------------------------------------------------------------------
# wait_for_task <base_url> <task_id> [max_wait_seconds]
#
# Polls GET <base_url>/tasks/<task_id> until status is completed or failed.
# Sets TASK_RESPONSE to the final JSON body.
# Returns 0 on completed, 1 on failed/timeout.
# ---------------------------------------------------------------------------
wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-300}"
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(curl -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${base_url}/tasks/${task_id}")
    export TASK_RESPONSE

    status=$(echo "$TASK_RESPONSE" | jq -r '.status' 2>/dev/null || true)

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
# If the namespace exists and is Terminating, wait up to 60s for it to be
# fully removed before proceeding.
# ---------------------------------------------------------------------------
_wait_for_ns_deleted() {
  local namespace="$1" elapsed=0
  while (( elapsed < 60 )); do
    local phase
    phase=$(kubectl --context kind-cluster-dbs get ns "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || true)
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
  echo "Namespace ${namespace} still Terminating after 60s" >&2
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

  _wait_for_ns_deleted "$namespace"
  kubectl --context kind-cluster-dbs create ns "$namespace" --dry-run=client -o yaml \
    | kubectl --context kind-cluster-dbs apply -f -

  kubectl --context kind-cluster-dbs -n "$namespace" apply -f - <<EOF
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

  kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/${namespace}.yaml"

  echo "Waiting for MariaDB in ${namespace} to be ready..."
  kubectl --context kind-cluster-dbs -n "$namespace" wait \
    --for=condition=Ready mariadb/mariadb --timeout=180s
}

# ---------------------------------------------------------------------------
# deploy_mongodb <namespace>
#
# Creates namespace, RBAC RoleBinding, credentials secret, and MongoDB StatefulSet.
# Waits for the MongoDB pod to be ready.
# ---------------------------------------------------------------------------
deploy_mongodb() {
  local namespace="$1"

  _wait_for_ns_deleted "$namespace"
  kubectl --context kind-cluster-dbs create ns "$namespace" --dry-run=client -o yaml \
    | kubectl --context kind-cluster-dbs apply -f -

  kubectl --context kind-cluster-dbs -n "$namespace" apply -f - <<EOF
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

  if ! kubectl --context kind-cluster-dbs -n "$namespace" get secret mongodb-credentials &>/dev/null; then
    kubectl --context kind-cluster-dbs -n "$namespace" create secret generic mongodb-credentials \
      --from-literal="MONGO_ROOT_USER=${namespace}-admin" \
      --from-literal="MONGO_ROOT_PASS=$(openssl rand -base64 16 | tr -d '=+/')"
  fi

  kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/${namespace}.yaml"

  echo "Waiting for MongoDB in ${namespace} to be ready..."
  kubectl --context kind-cluster-dbs -n "$namespace" wait pod \
    -l app=mongodb --for=condition=Ready --timeout=180s
}
