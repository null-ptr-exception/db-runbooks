#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

# shellcheck source=/dev/null
source "$ENV_FILE"
export CLUSTER_AUTH_IP CLUSTER_DBS_IP CLUSTER_APPS_IP

echo "=== Step 1: Deploy namespaces and RBAC ==="

kubectl --context kind-cluster-auth apply -f "${ROOT_DIR}/k8s/cluster-auth/namespace.yaml"

kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/namespace.yaml"
kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/federated-auth-rbac.yaml"
kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/aqsh-rbac.yaml"
kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/rbac.yaml"
kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/rbac.yaml"

kubectl --context kind-cluster-apps apply -f "${ROOT_DIR}/k8s/cluster-apps/namespace.yaml"
kubectl --context kind-cluster-apps apply -f "${ROOT_DIR}/k8s/cluster-apps/federated-auth-rbac.yaml"

echo "=== Step 2: Bootstrap credentials ==="

"${SCRIPT_DIR}/setup-credentials.sh"

# Re-source to pick up ISSUER_DBS and ISSUER_APPS added by setup-credentials.sh
# shellcheck source=/dev/null
source "$ENV_FILE"
export ISSUER_DBS ISSUER_APPS

echo "=== Step 3: Deploy cluster-auth (kube-federated-auth) ==="

kubectl --context kind-cluster-auth apply -f "${ROOT_DIR}/k8s/cluster-auth/rbac.yaml"

envsubst < "${ROOT_DIR}/k8s/cluster-auth/configmap.yaml.tpl" | kubectl --context kind-cluster-auth apply -f -

kubectl --context kind-cluster-auth apply -f "${ROOT_DIR}/k8s/cluster-auth/deployment.yaml"
kubectl --context kind-cluster-auth apply -f "${ROOT_DIR}/k8s/cluster-auth/service.yaml"

echo "Waiting for kube-federated-auth to be ready..."
kubectl --context kind-cluster-auth -n db-ops rollout status deployment/kube-federated-auth --timeout=120s

echo "=== Step 4: Deploy mariadb-operator ==="

helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator 2>/dev/null || true
helm repo update mariadb-operator

helm upgrade --install mariadb-operator-crds mariadb-operator/mariadb-operator-crds \
  --kube-context kind-cluster-dbs \
  --wait

helm upgrade --install mariadb-operator mariadb-operator/mariadb-operator \
  --kube-context kind-cluster-dbs \
  --namespace db-ops \
  --wait

echo "=== Step 5: Build and load aqsh images ==="

skaffold build --filename="${ROOT_DIR}/skaffold.yaml" --tag=latest --quiet
kind load docker-image aqsh-mariadb:latest --name cluster-dbs
kind load docker-image aqsh-mongodb:latest --name cluster-dbs

echo "=== Step 6: Deploy aqsh + Redis ==="

kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/redis.yaml"

envsubst < "${ROOT_DIR}/k8s/cluster-dbs/aqsh-mariadb-deployment.yaml.tpl" | kubectl --context kind-cluster-dbs apply -f -
kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/aqsh-mariadb-service.yaml"

envsubst < "${ROOT_DIR}/k8s/cluster-dbs/aqsh-mongodb-deployment.yaml.tpl" | kubectl --context kind-cluster-dbs apply -f -
kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/aqsh-mongodb-service.yaml"

kubectl --context kind-cluster-dbs -n db-ops rollout restart deployment/aqsh-mariadb
kubectl --context kind-cluster-dbs -n db-ops rollout restart deployment/aqsh-mongodb

echo "Waiting for Redis to be ready..."
kubectl --context kind-cluster-dbs -n db-ops rollout status deployment/redis --timeout=60s

echo "Waiting for aqsh-mariadb to be ready..."
kubectl --context kind-cluster-dbs -n db-ops rollout status deployment/aqsh-mariadb --timeout=120s

echo "Waiting for aqsh-mongodb to be ready..."
kubectl --context kind-cluster-dbs -n db-ops rollout status deployment/aqsh-mongodb --timeout=120s

echo "=== Step 7: Deploy test-client ==="

kubectl --context kind-cluster-apps apply -f "${ROOT_DIR}/k8s/cluster-apps/test-client.yaml"

echo "Waiting for test-client to be ready..."
kubectl --context kind-cluster-apps -n app-a rollout status deployment/test-client --timeout=60s
kubectl --context kind-cluster-apps -n app-b rollout status deployment/test-client --timeout=60s

echo "=== Infrastructure deployment complete ==="
