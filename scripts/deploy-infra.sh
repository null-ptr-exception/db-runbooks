#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

# shellcheck source=/dev/null
source "$ENV_FILE"
export CLUSTER_AUTH_IP CLUSTER_DBS_IP CLUSTER_APPS_IP
export DB_MODE="${DB_MODE:-single}"
export USE_MARIADB_OPERATOR="${USE_MARIADB_OPERATOR:-true}"
export CLUSTER_DBS_CONTEXT="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"

kubectl_apply_with_retry() {
  local ctx="$1"
  local manifest="$2"
  local attempt

  for attempt in 1 2 3 4 5; do
    if kubectl --context "$ctx" apply -f "$manifest"; then
      return 0
    fi

    if [[ "$attempt" -eq 5 ]]; then
      return 1
    fi

    echo "kubectl apply failed for ${manifest} on ${ctx} (attempt ${attempt}/5); retrying in 5s..."
    sleep 5
  done
}

wait_for_log_message() {
  local ctx="$1"
  local namespace="$2"
  local selector="$3"
  local message="$4"
  local timeout="${5:-240}"
  local elapsed=0

  while (( elapsed < timeout )); do
    if kubectl --context "$ctx" -n "$namespace" logs -l "$selector" --tail=50 2>/dev/null | grep -Fq "$message"; then
      return 0
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  return 1
}

wait_for_deployment_ready() {
  local ctx="$1"
  local namespace="$2"
  local deployment="$3"
  local selector="$4"
  local rollout_timeout="${5:-120s}"
  local pod_timeout="${6:-120s}"

  if kubectl --context "$ctx" -n "$namespace" rollout status "deployment/${deployment}" --timeout="$rollout_timeout"; then
    return 0
  fi

  echo "rollout status timed out for deployment/${deployment}; checking pod readiness..."
  kubectl --context "$ctx" -n "$namespace" get deployment "$deployment" -o wide || true
  kubectl --context "$ctx" -n "$namespace" get pods -l "$selector" -o wide || true
  kubectl --context "$ctx" -n "$namespace" wait pod -l "$selector" --for=condition=Ready --timeout="$pod_timeout"
}

# ---------------------------------------------------------------------------
# deploy_dbs_cluster <context> <cluster_name> <peer_dbs_ip_or_empty>
#
# Deploys namespaces, RBAC, mariadb-operator (if enabled), aqsh images,
# Redis, aqsh deployments, and (in dual mode) nginx proxy into one db cluster.
# ---------------------------------------------------------------------------
deploy_dbs_cluster() {
  local ctx="$1"
  local cluster_name="$2"
  local peer_ip="${3:-}"

  echo "--- Deploying to ${cluster_name} (context: ${ctx}) ---"

  echo "  Step 1: Remaining RBAC (aqsh, mariadb, mongodb)"
  kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/aqsh-rbac.yaml"
  kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/rbac.yaml"
  kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/rbac.yaml"

  if [[ "$USE_MARIADB_OPERATOR" == "true" ]]; then
    echo "  Step 2: mariadb-operator (Helm)"
    helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator 2>/dev/null || true
    helm repo update mariadb-operator

    helm upgrade --install mariadb-operator-crds mariadb-operator/mariadb-operator-crds \
      --kube-context "$ctx" \
      --wait

    helm upgrade --install mariadb-operator mariadb-operator/mariadb-operator \
      --kube-context "$ctx" \
      --namespace db-ops \
      --wait
  fi

  echo "  Step 3: Load aqsh images"
  kind load docker-image aqsh-mariadb:latest --name "$cluster_name"
  kind load docker-image aqsh-mongodb:latest --name "$cluster_name"

  echo "  Step 4: Deploy Redis + aqsh"
  kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/redis.yaml"

  # aqsh deployments use CLUSTER_AUTH_IP — same for all db clusters
  envsubst < "${ROOT_DIR}/k8s/cluster-dbs/aqsh-mariadb-deployment.yaml.tpl" | kubectl --context "$ctx" apply -f -
  kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/aqsh-mariadb-service.yaml"

  envsubst < "${ROOT_DIR}/k8s/cluster-dbs/aqsh-mongodb-deployment.yaml.tpl" | kubectl --context "$ctx" apply -f -
  kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/aqsh-mongodb-service.yaml"

  kubectl --context "$ctx" -n db-ops rollout restart deployment/aqsh-mariadb
  kubectl --context "$ctx" -n db-ops rollout restart deployment/aqsh-mongodb

  echo "  Waiting for Redis..."
  wait_for_deployment_ready "$ctx" "db-ops" "redis" "app=redis" "120s" "120s"
  echo "  Waiting for aqsh-mariadb..."
  wait_for_deployment_ready "$ctx" "db-ops" "aqsh-mariadb" "app=aqsh-mariadb" "120s" "120s"
  echo "  Waiting for aqsh-mongodb..."
  wait_for_deployment_ready "$ctx" "db-ops" "aqsh-mongodb" "app=aqsh-mongodb" "120s" "120s"

  if [[ -n "$peer_ip" ]]; then
    echo "  Step 5: nginx TCP proxy (peer: ${peer_ip})"
    PEER_DBS_IP="$peer_ip" envsubst < "${ROOT_DIR}/k8s/nginx-proxy/configmap.yaml.tpl" \
      | kubectl --context "$ctx" apply -f -
    kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/nginx-proxy/deployment.yaml"
    kubectl --context "$ctx" -n db-ops rollout restart deployment/nginx-proxy
    echo "  Waiting for nginx-proxy..."
    wait_for_deployment_ready "$ctx" "db-ops" "nginx-proxy" "app=nginx-proxy" "60s" "60s"
  fi
}

echo "=== Step 1: cluster-auth namespaces and RBAC ==="

kubectl --context kind-cluster-auth apply -f "${ROOT_DIR}/k8s/cluster-auth/namespace.yaml"

echo "=== Step 2: cluster-apps and cluster-dbs namespaces / RBAC ==="

kubectl --context kind-cluster-apps apply -f "${ROOT_DIR}/k8s/cluster-apps/namespace.yaml"
kubectl --context kind-cluster-apps apply -f "${ROOT_DIR}/k8s/cluster-apps/federated-auth-rbac.yaml"

# Bootstrap db cluster namespace + federated-auth SA now so setup-credentials.sh
# can create tokens. deploy_dbs_cluster will apply the rest of the RBAC later.
if [[ "$DB_MODE" == "dual" ]]; then
  for ctx in kind-cluster-dbs-a kind-cluster-dbs-b; do
    kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/namespace.yaml"
    kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/federated-auth-rbac.yaml"
  done
else
  kubectl --context "${CLUSTER_DBS_CONTEXT}" apply -f "${ROOT_DIR}/k8s/cluster-dbs/namespace.yaml"
  kubectl --context "${CLUSTER_DBS_CONTEXT}" apply -f "${ROOT_DIR}/k8s/cluster-dbs/federated-auth-rbac.yaml"
fi

echo "=== Step 3: Bootstrap credentials ==="

"${SCRIPT_DIR}/setup-credentials.sh"

# Re-source to pick up ISSUER_* vars added by setup-credentials.sh
# shellcheck source=/dev/null
source "$ENV_FILE"

echo "=== Step 4: Deploy kube-federated-auth ==="

kubectl --context kind-cluster-auth apply -f "${ROOT_DIR}/k8s/cluster-auth/rbac.yaml"

if [[ "$DB_MODE" == "dual" ]]; then
  export ISSUER_DBS_A ISSUER_DBS_B ISSUER_APPS CLUSTER_DBS_A_IP CLUSTER_DBS_B_IP CLUSTER_APPS_IP
  envsubst < "${ROOT_DIR}/k8s/cluster-auth/configmap-dual.yaml.tpl" \
    | kubectl --context kind-cluster-auth apply -f -
else
  export ISSUER_DBS CLUSTER_DBS_IP ISSUER_APPS CLUSTER_APPS_IP
  envsubst < "${ROOT_DIR}/k8s/cluster-auth/configmap.yaml.tpl" \
    | kubectl --context kind-cluster-auth apply -f -
fi

kubectl --context kind-cluster-auth apply -f "${ROOT_DIR}/k8s/cluster-auth/deployment.yaml"
kubectl_apply_with_retry "kind-cluster-auth" "${ROOT_DIR}/k8s/cluster-auth/service.yaml"

echo "Waiting for kube-federated-auth to be ready..."
kubectl --context kind-cluster-auth -n db-ops rollout status deployment/kube-federated-auth --timeout=240s
wait_for_log_message "kind-cluster-auth" "db-ops" "app=kube-federated-auth" "starting server" 240

echo "=== Step 5: Build aqsh images ==="

skaffold build --filename="${ROOT_DIR}/skaffold.yaml" --tag=latest --quiet

echo "=== Step 6: Deploy DB cluster(s) ==="

if [[ "$DB_MODE" == "dual" ]]; then
  deploy_dbs_cluster "kind-cluster-dbs-a" "cluster-dbs-a" "${CLUSTER_DBS_B_IP}"
  deploy_dbs_cluster "kind-cluster-dbs-b" "cluster-dbs-b" "${CLUSTER_DBS_A_IP}"
else
  deploy_dbs_cluster "${CLUSTER_DBS_CONTEXT}" "cluster-dbs" ""
fi

echo "=== Step 7: Deploy test-client ==="

kubectl --context kind-cluster-apps apply -f "${ROOT_DIR}/k8s/cluster-apps/test-client.yaml"

echo "Waiting for test-client to be ready..."
kubectl --context kind-cluster-apps -n app-a rollout status deployment/test-client --timeout=60s
kubectl --context kind-cluster-apps -n app-b rollout status deployment/test-client --timeout=60s

echo "=== Infrastructure deployment complete ==="
