#!/usr/bin/env bash

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local K8S_DIR="${ROOT_DIR}/k8s"
  local CTX_A="kind-cluster-a"

  # Reuse aqsh suite setup (Layers 1-3: clusters, platform, aqsh infra)
  source "${ROOT_DIR}/tests/aqsh/setup_suite.bash"
  setup_suite

  # Layer 3b: MongoDB-specific resources on cluster-a

  # RBAC (cluster-scoped)
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/mongodb/rbac.yaml"

  # Namespace
  kubectl --context "$CTX_A" create ns mongo-1 --dry-run=client -o yaml \
    | kubectl --context "$CTX_A" apply -f -

  # RoleBinding in mongo-1 namespace
  kubectl --context "$CTX_A" -n mongo-1 apply -f - <<'EOF'
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

  # Credentials (only create if missing to avoid breaking running MongoDB)
  if ! kubectl --context "$CTX_A" -n mongo-1 get secret mongodb-credentials &>/dev/null; then
    kubectl --context "$CTX_A" -n mongo-1 create secret generic mongodb-credentials \
      --from-literal="MONGO_ROOT_USER=mongo-admin" \
      --from-literal="MONGO_ROOT_PASS=$(openssl rand -base64 16 | tr -d '=+/')"
  fi

  # StatefulSet + headless Service
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/mongodb/mongo-1.yaml"

  echo "Waiting for MongoDB..."
  kubectl --context "$CTX_A" -n mongo-1 rollout status statefulset/mongodb --timeout=120s
}

teardown_suite() {
  if [[ "${TEARDOWN:-}" != "true" ]]; then
    return 0
  fi

  local CTX_A="kind-cluster-a"

  kubectl --context "$CTX_A" delete ns mongo-1 --ignore-not-found
  kubectl --context "$CTX_A" delete clusterrole aqsh-mongo-manager aqsh-mongo-node-reader --ignore-not-found
  kubectl --context "$CTX_A" delete clusterrolebinding aqsh-mongo-node-reader --ignore-not-found
}
