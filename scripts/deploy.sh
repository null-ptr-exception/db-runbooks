#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

# Deploy shared infrastructure
"${SCRIPT_DIR}/deploy-infra.sh"

# shellcheck source=/dev/null
source "$ENV_FILE"

DB_MODE="${DB_MODE:-single}"
USE_MARIADB_OPERATOR="${USE_MARIADB_OPERATOR:-true}"
CLUSTER_DBS_CONTEXT="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"

# ---------------------------------------------------------------------------
# deploy_mariadb_to_cluster <context> <namespace_list...>
# ---------------------------------------------------------------------------
deploy_mariadb_to_cluster() {
  local ctx="$1"
  shift
  local namespaces=("$@")

  for ns in "${namespaces[@]}"; do
    kubectl --context "$ctx" create ns "$ns" --dry-run=client -o yaml \
      | kubectl --context "$ctx" apply -f -

    kubectl --context "$ctx" -n "$ns" apply -f - <<EOF
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

    if [[ "$USE_MARIADB_OPERATOR" == "true" ]]; then
      kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/${ns}.yaml"
    else
      # Native mode: extract only the Secret document (kind: Secret) from the operator
      # yaml so we reuse the same password, then deploy the native StatefulSet.
      python3 -c "
import sys, re
docs = open('${ROOT_DIR}/k8s/cluster-dbs/mariadb/${ns}.yaml').read().split('\n---\n')
for doc in docs:
    if re.search(r'^kind:\s*Secret', doc, re.MULTILINE):
        print(doc)
" | kubectl --context "$ctx" -n "$ns" apply -f -
      kubectl --context "$ctx" -n "$ns" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/statefulset.yaml"
    fi

    if [[ "$DB_MODE" == "dual" ]]; then
      kubectl --context "$ctx" -n "$ns" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/nodeport-service.yaml"
    fi
  done

  echo "Waiting for MariaDB instances in ${ctx}..."
  for ns in "${namespaces[@]}"; do
    if [[ "$USE_MARIADB_OPERATOR" == "true" ]]; then
      kubectl --context "$ctx" -n "$ns" wait --for=condition=Ready mariadb/mariadb --timeout=180s
    else
      kubectl --context "$ctx" -n "$ns" wait pod \
        -l app.kubernetes.io/name=mariadb --for=condition=Ready --timeout=180s
    fi
  done
}

# ---------------------------------------------------------------------------
# deploy_mongodb_to_cluster <context> <namespace_list...>
# ---------------------------------------------------------------------------
deploy_mongodb_to_cluster() {
  local ctx="$1"
  shift
  local namespaces=("$@")

  for ns in "${namespaces[@]}"; do
    kubectl --context "$ctx" create ns "$ns" --dry-run=client -o yaml \
      | kubectl --context "$ctx" apply -f -

    kubectl --context "$ctx" -n "$ns" apply -f - <<EOF
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

    if ! kubectl --context "$ctx" -n "$ns" get secret mongodb-credentials &>/dev/null; then
      kubectl --context "$ctx" -n "$ns" create secret generic mongodb-credentials \
        --from-literal="MONGO_ROOT_USER=${ns}-admin" \
        --from-literal="MONGO_ROOT_PASS=$(openssl rand -base64 16 | tr -d '=+/')"
    fi

    kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/${ns}.yaml"
    if [[ "$DB_MODE" == "dual" ]]; then
      kubectl --context "$ctx" -n "$ns" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/nodeport-service.yaml"
    fi
  done

  echo "Waiting for MongoDB instances in ${ctx}..."
  for ns in "${namespaces[@]}"; do
    kubectl --context "$ctx" -n "$ns" rollout status statefulset/mongodb --timeout=180s
  done
}

if [[ "$DB_MODE" == "dual" ]]; then
  echo "=== Deploy MariaDB instances (dual mode) ==="
  deploy_mariadb_to_cluster "kind-cluster-dbs-a" mariadb-1
  deploy_mariadb_to_cluster "kind-cluster-dbs-b" mariadb-1

  echo "=== Deploy MongoDB instances (dual mode) ==="
  deploy_mongodb_to_cluster "kind-cluster-dbs-a" mongo-1
  deploy_mongodb_to_cluster "kind-cluster-dbs-b" mongo-1
else
  echo "=== Deploy MariaDB instances ==="
  deploy_mariadb_to_cluster "$CLUSTER_DBS_CONTEXT" mariadb-1 mariadb-2 mariadb-3

  echo "=== Deploy MongoDB instances ==="
  deploy_mongodb_to_cluster "$CLUSTER_DBS_CONTEXT" mongo-1 mongo-2 mongo-3
fi

echo "=== Deployment complete ==="
