#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

# Deploy shared infrastructure
"${SCRIPT_DIR}/deploy-infra.sh"

# shellcheck source=/dev/null
source "$ENV_FILE"

echo "=== Deploy MariaDB instances ==="

for ns in mariadb-1 mariadb-2 mariadb-3; do
  kubectl --context kind-cluster-dbs create ns "$ns" --dry-run=client -o yaml \
    | kubectl --context kind-cluster-dbs apply -f -

  kubectl --context kind-cluster-dbs -n "$ns" apply -f - <<EOF
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

  kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/${ns}.yaml"
done

echo "Waiting for MariaDB instances to be ready..."
kubectl --context kind-cluster-dbs -n mariadb-1 wait --for=condition=Ready mariadb/mariadb --timeout=180s
kubectl --context kind-cluster-dbs -n mariadb-2 wait --for=condition=Ready mariadb/mariadb --timeout=180s
kubectl --context kind-cluster-dbs -n mariadb-3 wait --for=condition=Ready mariadb/mariadb --timeout=180s

echo "=== Deploy MongoDB instances ==="

for ns in mongo-1 mongo-2 mongo-3; do
  kubectl --context kind-cluster-dbs create ns "$ns" --dry-run=client -o yaml \
    | kubectl --context kind-cluster-dbs apply -f -

  kubectl --context kind-cluster-dbs -n "$ns" apply -f - <<EOF
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

  if ! kubectl --context kind-cluster-dbs -n "$ns" get secret mongodb-credentials &>/dev/null; then
    kubectl --context kind-cluster-dbs -n "$ns" create secret generic mongodb-credentials \
      --from-literal="MONGO_ROOT_USER=${ns}-admin" \
      --from-literal="MONGO_ROOT_PASS=$(openssl rand -base64 16 | tr -d '=+/')"
  fi

  kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/${ns}.yaml"
done

echo "Waiting for MongoDB instances to be ready..."
kubectl --context kind-cluster-dbs -n mongo-1 wait --for=condition=Ready pod -l app=mongodb --timeout=180s
kubectl --context kind-cluster-dbs -n mongo-2 wait --for=condition=Ready pod -l app=mongodb --timeout=180s
kubectl --context kind-cluster-dbs -n mongo-3 wait --for=condition=Ready pod -l app=mongodb --timeout=180s

echo "=== Deployment complete ==="
