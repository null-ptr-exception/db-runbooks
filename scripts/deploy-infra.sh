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

deployment_rollout_complete() {
  local ctx="$1"
  local namespace="$2"
  local deployment="$3"
  local generation observed_generation desired_replicas updated_replicas available_replicas unavailable_replicas

  generation=$(kubectl --context "$ctx" -n "$namespace" get deployment "$deployment" -o jsonpath='{.metadata.generation}')
  observed_generation=$(kubectl --context "$ctx" -n "$namespace" get deployment "$deployment" -o jsonpath='{.status.observedGeneration}')
  desired_replicas=$(kubectl --context "$ctx" -n "$namespace" get deployment "$deployment" -o jsonpath='{.spec.replicas}')
  updated_replicas=$(kubectl --context "$ctx" -n "$namespace" get deployment "$deployment" -o jsonpath='{.status.updatedReplicas}')
  available_replicas=$(kubectl --context "$ctx" -n "$namespace" get deployment "$deployment" -o jsonpath='{.status.availableReplicas}')
  unavailable_replicas=$(kubectl --context "$ctx" -n "$namespace" get deployment "$deployment" -o jsonpath='{.status.unavailableReplicas}')

  generation="${generation:-0}"
  observed_generation="${observed_generation:-0}"
  desired_replicas="${desired_replicas:-1}"
  updated_replicas="${updated_replicas:-0}"
  available_replicas="${available_replicas:-0}"
  unavailable_replicas="${unavailable_replicas:-0}"

  [[ "$observed_generation" -ge "$generation" ]] \
    && [[ "$updated_replicas" -eq "$desired_replicas" ]] \
    && [[ "$available_replicas" -eq "$desired_replicas" ]] \
    && [[ "$unavailable_replicas" -eq 0 ]]
}

wait_for_deployment_rollout_state() {
  local ctx="$1"
  local namespace="$2"
  local deployment="$3"
  local timeout="${4:-120s}"
  local timeout_seconds="${timeout%s}"
  local elapsed=0

  while (( elapsed < timeout_seconds )); do
    if deployment_rollout_complete "$ctx" "$namespace" "$deployment"; then
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
  local state_timeout="${6:-120s}"

  if kubectl --context "$ctx" -n "$namespace" rollout status "deployment/${deployment}" --timeout="$rollout_timeout"; then
    return 0
  fi

  echo "rollout status timed out for deployment/${deployment}; checking deployment status..."
  kubectl --context "$ctx" -n "$namespace" get deployment "$deployment" -o wide || true
  kubectl --context "$ctx" -n "$namespace" get pods -l "$selector" -o wide || true

  if wait_for_deployment_rollout_state "$ctx" "$namespace" "$deployment" "$state_timeout"; then
    return 0
  fi

  kubectl --context "$ctx" -n "$namespace" get deployment "$deployment" -o yaml || true
  return 1
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

  if [[ -n "$peer_ip" ]] || [[ "${ENABLE_MINIO:-false}" == "true" ]]; then
    echo "  Step 5: nginx proxy (peer: ${peer_ip}, minio: ${ENABLE_MINIO:-false})"
    local nginx_deployment_exists="false"

    if kubectl --context "$ctx" -n db-ops get deployment nginx-proxy >/dev/null 2>&1; then
      nginx_deployment_exists="true"
    fi

    if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then
      # Use HTTP+stream config
      export PEER_DBS_IP="${peer_ip}" CLUSTER_MINIO_IP
      envsubst '${PEER_DBS_IP} ${CLUSTER_MINIO_IP}' < "${ROOT_DIR}/k8s/nginx-proxy/configmap-http.yaml.tpl" \
        | kubectl --context "$ctx" apply -f -
    else
      # Use stream-only config (existing)
      PEER_DBS_IP="$peer_ip" envsubst '${PEER_DBS_IP}' < "${ROOT_DIR}/k8s/nginx-proxy/configmap.yaml.tpl" \
        | kubectl --context "$ctx" apply -f -
    fi

    kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/nginx-proxy/deployment.yaml"

    # Restart only when deployment already exists so reruns pick new ConfigMap
    # without introducing an extra rollout during first-time bootstrap.
    if [[ "$nginx_deployment_exists" == "true" ]]; then
      kubectl --context "$ctx" -n db-ops rollout restart deployment/nginx-proxy
    fi

    echo "  Waiting for nginx-proxy..."
    wait_for_deployment_ready "$ctx" "db-ops" "nginx-proxy" "app=nginx-proxy" "120s" "120s"
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

# Bootstrap cluster-minio namespace + federated-auth SA if enabled
if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then
  kubectl --context kind-cluster-minio apply -f "${ROOT_DIR}/k8s/cluster-minio/namespace.yaml"
  kubectl --context kind-cluster-minio apply -f "${ROOT_DIR}/k8s/cluster-minio/federated-auth-rbac.yaml"
fi

echo "=== Step 3: Bootstrap credentials ==="

"${SCRIPT_DIR}/setup-credentials.sh"

# Re-source to pick up ISSUER_* vars added by setup-credentials.sh
# shellcheck source=/dev/null
source "$ENV_FILE"

echo "=== Step 4: Deploy kube-federated-auth ==="

kubectl --context kind-cluster-auth apply -f "${ROOT_DIR}/k8s/cluster-auth/rbac.yaml"

if [[ "$DB_MODE" == "dual" ]]; then
  if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then
    export ISSUER_DBS_A ISSUER_DBS_B ISSUER_APPS ISSUER_MINIO
    export CLUSTER_DBS_A_IP CLUSTER_DBS_B_IP CLUSTER_APPS_IP CLUSTER_MINIO_IP
    envsubst < "${ROOT_DIR}/k8s/cluster-auth/configmap-dual-minio.yaml.tpl" \
      | kubectl --context kind-cluster-auth apply -f -
  else
    export ISSUER_DBS_A ISSUER_DBS_B ISSUER_APPS CLUSTER_DBS_A_IP CLUSTER_DBS_B_IP CLUSTER_APPS_IP
    envsubst < "${ROOT_DIR}/k8s/cluster-auth/configmap-dual.yaml.tpl" \
      | kubectl --context kind-cluster-auth apply -f -
  fi
else
  if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then
    export ISSUER_DBS ISSUER_APPS ISSUER_MINIO
    export CLUSTER_DBS_IP CLUSTER_APPS_IP CLUSTER_MINIO_IP
    envsubst < "${ROOT_DIR}/k8s/cluster-auth/configmap-minio.yaml.tpl" \
      | kubectl --context kind-cluster-auth apply -f -
  else
    export ISSUER_DBS CLUSTER_DBS_IP ISSUER_APPS CLUSTER_APPS_IP
    envsubst < "${ROOT_DIR}/k8s/cluster-auth/configmap.yaml.tpl" \
      | kubectl --context kind-cluster-auth apply -f -
  fi
fi

kubectl --context kind-cluster-auth apply -f "${ROOT_DIR}/k8s/cluster-auth/deployment.yaml"
kubectl_apply_with_retry "kind-cluster-auth" "${ROOT_DIR}/k8s/cluster-auth/service.yaml"

echo "Waiting for kube-federated-auth to be ready..."
kubectl --context kind-cluster-auth -n db-ops rollout status deployment/kube-federated-auth --timeout=240s
wait_for_log_message "kind-cluster-auth" "db-ops" "app=kube-federated-auth" "starting server" 240

echo "=== Step 5: Build aqsh images ==="

skaffold build --filename="${ROOT_DIR}/skaffold.yaml" --tag=latest --quiet

echo "=== Step 5.5: Preload DB images into Kind cluster(s) ==="
# Pre-loading avoids image pull latency competing for CPU during pod startup.

_kind_load_image() {
  local image="$1" cluster="$2"
  echo "  Loading ${image} into ${cluster}..."
  docker pull --quiet "$image" || true
  kind load docker-image "$image" --name "$cluster"
}

if [[ "$DB_MODE" == "dual" ]]; then
  for img in mongo:7 mariadb:10.6; do
    _kind_load_image "$img" "cluster-dbs-a"
    _kind_load_image "$img" "cluster-dbs-b"
  done
else
  for img in mongo:7 mariadb:10.6; do
    _kind_load_image "$img" "cluster-dbs"
  done
fi

echo "=== Step 6: Deploy DB cluster(s) ==="

if [[ "$DB_MODE" == "dual" ]]; then
  deploy_dbs_cluster "kind-cluster-dbs-a" "cluster-dbs-a" "${CLUSTER_DBS_B_IP}"
  deploy_dbs_cluster "kind-cluster-dbs-b" "cluster-dbs-b" "${CLUSTER_DBS_A_IP}"
else
  deploy_dbs_cluster "${CLUSTER_DBS_CONTEXT}" "cluster-dbs" ""
fi

if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then
  echo "=== Step 6.5: Deploy MinIO cluster ==="
  kubectl --context kind-cluster-minio apply -f "${ROOT_DIR}/k8s/cluster-minio/minio-secret.yaml"
  kubectl --context kind-cluster-minio apply -f "${ROOT_DIR}/k8s/cluster-minio/minio-deployment.yaml"

  echo "Waiting for MinIO to be ready..."
  wait_for_deployment_ready "kind-cluster-minio" "minio" "minio" "app=minio" "120s" "120s"
fi

echo "=== Step 7: Deploy test-client ==="

kubectl --context kind-cluster-apps apply -f "${ROOT_DIR}/k8s/cluster-apps/test-client.yaml"

echo "Waiting for test-client to be ready..."
kubectl --context kind-cluster-apps -n app-a rollout status deployment/test-client --timeout=60s
kubectl --context kind-cluster-apps -n app-b rollout status deployment/test-client --timeout=60s

echo "=== Infrastructure deployment complete ==="
