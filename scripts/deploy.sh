#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

# shellcheck source=/dev/null
source "$ENV_FILE"
export REGION_A_IP APPS_MINIO_IP
REGION_B_IP="${REGION_B_IP:-}"
export REGION_B_IP
MODE="${MODE:-single}"
MONGO_FLAVOR="${MONGO_FLAVOR:-official}"

deploy_region() {
  local cluster="$1"           # e.g. cluster-region-a
  local context="kind-${cluster}"
  local dir="${ROOT_DIR}/k8s/${cluster}"
  local REMOTE_VAR="REGION_B_IP"
  [[ "$cluster" == "cluster-region-b" ]] && REMOTE_VAR="REGION_A_IP"
  export REMOTE_VAR

  echo ""
  echo "=== Deploying to ${cluster} ==="

  echo "--- Namespaces & RBAC ---"
  kubectl --context "$context" apply -f "${dir}/dbs/namespace.yaml"
  kubectl --context "$context" apply -f "${dir}/dbs/federated-auth-rbac.yaml"
  kubectl --context "$context" apply -f "${dir}/dbs/aqsh-rbac.yaml"
  kubectl --context "$context" apply -f "${dir}/dbs/mariadb/rbac.yaml"
  kubectl --context "$context" apply -f "${dir}/dbs/mongodb/rbac.yaml"
  kubectl --context "$context" apply -f "${dir}/auth/namespace.yaml"

  echo "--- kube-federated-auth ---"
  kubectl --context "$context" apply -f "${dir}/auth/rbac.yaml"
  envsubst < "${dir}/auth/configmap-${MODE}.yaml.tpl" | kubectl --context "$context" apply -f -
  kubectl --context "$context" apply -f "${dir}/auth/deployment.yaml"
  kubectl --context "$context" apply -f "${dir}/auth/service.yaml"
  kubectl --context "$context" -n db-ops rollout status deployment/kube-federated-auth --timeout=120s

  echo "--- mariadb-operator ---"
  helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator 2>/dev/null || true
  helm repo update mariadb-operator
  helm upgrade --install mariadb-operator-crds mariadb-operator/mariadb-operator-crds \
    --kube-context "$context" --wait
  helm upgrade --install mariadb-operator mariadb-operator/mariadb-operator \
    --kube-context "$context" --namespace db-ops --wait

  echo "--- MariaDB instances ---"
  kubectl --context "$context" apply -f "${dir}/dbs/mariadb/mariadb-1.yaml"
  kubectl --context "$context" apply -f "${dir}/dbs/mariadb/mariadb-2.yaml"
  kubectl --context "$context" apply -f "${dir}/dbs/mariadb/mariadb-3.yaml"
  kubectl --context "$context" -n mariadb-1 wait --for=condition=Ready mariadb/mariadb --timeout=180s
  kubectl --context "$context" -n mariadb-2 wait --for=condition=Ready mariadb/mariadb --timeout=180s
  kubectl --context "$context" -n mariadb-3 wait --for=condition=Ready mariadb/mariadb --timeout=180s

  echo "--- MongoDB instances (flavor: ${MONGO_FLAVOR}) ---"
  kubectl --context "$context" apply -f "${dir}/dbs/mongodb/mongo-1.yaml"
  kubectl --context "$context" apply -f "${dir}/dbs/mongodb/mongo-2.yaml"
  kubectl --context "$context" apply -f "${dir}/dbs/mongodb/mongo-3.yaml"
  kubectl --context "$context" -n mongo-1 wait --for=condition=Ready pod -l app=mongodb --timeout=180s
  kubectl --context "$context" -n mongo-2 wait --for=condition=Ready pod -l app=mongodb --timeout=180s
  kubectl --context "$context" -n mongo-3 wait --for=condition=Ready pod -l app=mongodb --timeout=180s

  echo "--- Deploy nginx (needed for MongoDB RS NodePort addresses) ---"
  kubectl --context "$context" apply -f "${dir}/nginx/configmap.yaml.tpl"
  kubectl --context "$context" apply -f "${dir}/nginx/deployment.yaml"
  kubectl --context "$context" apply -f "${dir}/nginx/service.yaml"

  echo "--- Initialise MongoDB replica sets ---"
  local CLUSTER_IP
  [[ "$cluster" == "cluster-region-a" ]] && CLUSTER_IP="$REGION_A_IP"
  [[ "$cluster" == "cluster-region-b" ]] && CLUSTER_IP="$REGION_B_IP"
  local -a MONGO_PORTS=(30092 30094 30096)
  local ns_idx=0
  for ns in mongo-1 mongo-2 mongo-3; do
    RS_NAME="rs-${ns}"
    local STREAM_PORT="${MONGO_PORTS[$ns_idx]}"
    local ROOT_USER ROOT_PASS
    ROOT_USER=$(kubectl --context "$context" -n "$ns" \
      get secret mongodb-credentials -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
    ROOT_PASS=$(kubectl --context "$context" -n "$ns" \
      get secret mongodb-credentials -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)
    kubectl --context "$context" -n "$ns" exec mongodb-0 -- \
      mongosh --quiet --norc -u "$ROOT_USER" -p "$ROOT_PASS" --authenticationDatabase admin \
      --eval \
      "try { rs.initiate({_id:'${RS_NAME}',members:[{_id:0,host:'${CLUSTER_IP}:${STREAM_PORT}'}]}) } catch(e) { if(e.codeName!='AlreadyInitialized') throw e }" \
      2>/dev/null || true
    ns_idx=$((ns_idx + 1))
  done

  echo "--- Build & load aqsh images ---"
  skaffold build --filename="${ROOT_DIR}/skaffold.yaml" --tag=latest --quiet
  kind load docker-image aqsh-mariadb:latest --name "$cluster"
  kind load docker-image aqsh-mongodb:latest --name "$cluster"

  echo "--- Deploy Redis + aqsh ---"
  kubectl --context "$context" apply -f "${dir}/dbs/redis.yaml"
  # Export defaults so envsubst fills plain ${VAR} tokens in secrets.yaml.tpl
  export MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://${APPS_MINIO_IP}:30090}"
  export MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}"
  export MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minioadmin}"
  export MINIO_BUCKET_MARIADB="${MINIO_BUCKET_MARIADB:-mariadb-backups}"
  export MINIO_BUCKET_MONGODB="${MINIO_BUCKET_MONGODB:-mongodb-backups}"
  export MARIADB_REPLICATION_USER="${MARIADB_REPLICATION_USER:-repl}"
  export MARIADB_REPLICATION_PASSWORD="${MARIADB_REPLICATION_PASSWORD:-replpass}"
  envsubst < "${dir}/dbs/secrets.yaml.tpl" | kubectl --context "$context" apply -f -
  envsubst < "${dir}/dbs/aqsh-mariadb-deployment.yaml.tpl" | kubectl --context "$context" apply -f -
  kubectl --context "$context" apply -f "${dir}/dbs/aqsh-mariadb-service.yaml"
  envsubst < "${dir}/dbs/aqsh-mongodb-deployment.yaml.tpl" | kubectl --context "$context" apply -f -
  kubectl --context "$context" apply -f "${dir}/dbs/aqsh-mongodb-service.yaml"
  kubectl --context "$context" -n db-ops rollout restart deployment/aqsh-mariadb
  kubectl --context "$context" -n db-ops rollout restart deployment/aqsh-mongodb

  echo "--- Wait for aqsh & nginx ---"
  kubectl --context "$context" -n db-ops rollout status deployment/redis --timeout=60s
  kubectl --context "$context" -n db-ops rollout status deployment/aqsh-mariadb --timeout=120s
  kubectl --context "$context" -n db-ops rollout status deployment/aqsh-mongodb --timeout=120s
  kubectl --context "$context" -n db-ops rollout status deployment/nginx --timeout=60s
}

echo "=== Step 1: Deploy namespaces + bootstrap credentials ==="
kubectl --context kind-cluster-region-a apply -f "${ROOT_DIR}/k8s/cluster-region-a/dbs/namespace.yaml"
kubectl --context kind-cluster-region-a apply -f "${ROOT_DIR}/k8s/cluster-region-a/dbs/federated-auth-rbac.yaml"
kubectl --context kind-cluster-region-a apply -f "${ROOT_DIR}/k8s/cluster-region-a/auth/namespace.yaml"

if [[ "$MODE" == "multi" ]]; then
  kubectl --context kind-cluster-region-b apply -f "${ROOT_DIR}/k8s/cluster-region-b/dbs/namespace.yaml"
  kubectl --context kind-cluster-region-b apply -f "${ROOT_DIR}/k8s/cluster-region-b/dbs/federated-auth-rbac.yaml"
  kubectl --context kind-cluster-region-b apply -f "${ROOT_DIR}/k8s/cluster-region-b/auth/namespace.yaml"
fi

kubectl --context kind-cluster-apps-minio apply -f "${ROOT_DIR}/k8s/cluster-apps-minio/namespace.yaml"
kubectl --context kind-cluster-apps-minio apply -f "${ROOT_DIR}/k8s/cluster-apps-minio/apps/rbac.yaml"
# Wait for the SA to be created so setup-credentials.sh can generate a token
kubectl --context kind-cluster-apps-minio -n db-ops wait --for=jsonpath='{.metadata.name}'=kube-federated-auth-reader \
  serviceaccount/kube-federated-auth-reader --timeout=30s

echo "=== Step 2: Bootstrap cross-cluster credentials ==="
"${SCRIPT_DIR}/setup-credentials.sh"
source "$ENV_FILE"
export ISSUER_REGION_A ISSUER_APPS_MINIO
ISSUER_REGION_B="${ISSUER_REGION_B:-}"
export ISSUER_REGION_B

echo "=== Step 3: Deploy region-a ==="
deploy_region cluster-region-a

if [[ "$MODE" == "multi" ]]; then
  echo "=== Step 4: Deploy region-b ==="
  deploy_region cluster-region-b

  echo "=== Step 5: Set up cross-region replication ==="
  "${SCRIPT_DIR}/setup-replication.sh"
fi

echo "=== Step 6: Deploy cluster-apps-minio ==="
kubectl --context kind-cluster-apps-minio apply -f "${ROOT_DIR}/k8s/cluster-apps-minio/minio/minio.yaml"
kubectl --context kind-cluster-apps-minio apply -f "${ROOT_DIR}/k8s/cluster-apps-minio/apps/test-client.yaml"
kubectl --context kind-cluster-apps-minio -n minio rollout status deployment/minio --timeout=120s
kubectl --context kind-cluster-apps-minio -n app-a rollout status deployment/test-client --timeout=60s
kubectl --context kind-cluster-apps-minio -n app-b rollout status deployment/test-client --timeout=60s

echo ""
echo "=== Deployment complete ==="
echo "  Region-A nginx:  http://${REGION_A_IP}:30080"
echo "  MinIO API:       http://${APPS_MINIO_IP}:30090"
echo "  MinIO Console:   http://${APPS_MINIO_IP}:30091"
[[ "$MODE" == "multi" ]] && echo "  Region-B nginx:  http://${REGION_B_IP}:30080"
