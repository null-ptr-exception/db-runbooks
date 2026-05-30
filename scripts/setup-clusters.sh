#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

DB_MODE="${DB_MODE:-single}"
ENABLE_MINIO="${ENABLE_MINIO:-false}"

if [[ "$DB_MODE" == "dual" ]]; then
  CLUSTERS=(cluster-auth cluster-dbs-a cluster-dbs-b cluster-apps)
else
  CLUSTERS=(cluster-auth cluster-dbs cluster-apps)
fi

if [[ "$ENABLE_MINIO" == "true" ]]; then
  CLUSTERS+=("cluster-minio")
fi

ECR_REGISTRY="${ECR_REGISTRY:-}"

configure_ecr_mirror() {
  local node="$1"
  local ecr_password
  ecr_password="$(aws ecr get-login-password --region "${AWS_REGION:-ap-southeast-1}")"
  local auth
  auth="$(echo -n "AWS:${ecr_password}" | base64 -w0)"

  docker exec "$node" mkdir -p /etc/containerd/certs.d/docker.io
  # docker-hub.vpc.internal is a VPC-internal proxy (available on aws-runner)
  # that rewrites paths for ECR pull-through cache (adds docker-hub/ prefix).
  docker exec -i "$node" tee /etc/containerd/certs.d/docker.io/hosts.toml > /dev/null <<EOF
server = "https://registry-1.docker.io"

[host."http://docker-hub.vpc.internal"]
  capabilities = ["pull", "resolve"]
  [host."http://docker-hub.vpc.internal".header]
    Authorization = ["Basic ${auth}"]
EOF
}

echo "=== Creating Kind clusters (DB_MODE=${DB_MODE}) ==="

for cluster in "${CLUSTERS[@]}"; do
  if kind get clusters 2>/dev/null | grep -qx "$cluster"; then
    echo "Cluster $cluster already exists, skipping"
  else
    echo "Creating $cluster..."
    kind create cluster --name "$cluster" --wait 60s
  fi
done

if [[ -n "$ECR_REGISTRY" ]]; then
  echo "=== Configuring ECR pull-through cache mirror ==="
  for cluster in "${CLUSTERS[@]}"; do
    configure_ecr_mirror "${cluster}-control-plane"
  done
fi

echo "=== Extracting Docker IPs ==="

get_node_ip() {
  docker inspect "${1}-control-plane" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
}

CLUSTER_AUTH_IP=$(get_node_ip cluster-auth)
CLUSTER_APPS_IP=$(get_node_ip cluster-apps)

echo "cluster-auth: $CLUSTER_AUTH_IP"
echo "cluster-apps: $CLUSTER_APPS_IP"

if [[ "$ENABLE_MINIO" == "true" ]]; then
  CLUSTER_MINIO_IP=$(get_node_ip cluster-minio)
  echo "cluster-minio: $CLUSTER_MINIO_IP"
fi

if [[ "$DB_MODE" == "dual" ]]; then
  CLUSTER_DBS_A_IP=$(get_node_ip cluster-dbs-a)
  CLUSTER_DBS_B_IP=$(get_node_ip cluster-dbs-b)
  echo "cluster-dbs-a: $CLUSTER_DBS_A_IP"
  echo "cluster-dbs-b: $CLUSTER_DBS_B_IP"

  cat > "$ENV_FILE" <<EOF
DB_MODE=${DB_MODE}
CLUSTER_AUTH_IP=${CLUSTER_AUTH_IP}
CLUSTER_DBS_A_IP=${CLUSTER_DBS_A_IP}
CLUSTER_DBS_B_IP=${CLUSTER_DBS_B_IP}
CLUSTER_DBS_IP=${CLUSTER_DBS_A_IP}
CLUSTER_DBS_CONTEXT=kind-cluster-dbs-a
CLUSTER_APPS_IP=${CLUSTER_APPS_IP}
ENABLE_MINIO=${ENABLE_MINIO}
$(if [[ "$ENABLE_MINIO" == "true" ]]; then echo "CLUSTER_MINIO_IP=${CLUSTER_MINIO_IP}"; fi)
$(if [[ "$ENABLE_MINIO" == "true" ]]; then echo "CLUSTER_MINIO_CONTEXT=kind-cluster-minio"; fi)
EOF
else
  CLUSTER_DBS_IP=$(get_node_ip cluster-dbs)
  echo "cluster-dbs:  $CLUSTER_DBS_IP"

  cat > "$ENV_FILE" <<EOF
DB_MODE=${DB_MODE}
CLUSTER_AUTH_IP=${CLUSTER_AUTH_IP}
CLUSTER_DBS_IP=${CLUSTER_DBS_IP}
CLUSTER_DBS_CONTEXT=kind-cluster-dbs
CLUSTER_APPS_IP=${CLUSTER_APPS_IP}
ENABLE_MINIO=${ENABLE_MINIO}
$(if [[ "$ENABLE_MINIO" == "true" ]]; then echo "CLUSTER_MINIO_IP=${CLUSTER_MINIO_IP}"; fi)
$(if [[ "$ENABLE_MINIO" == "true" ]]; then echo "CLUSTER_MINIO_CONTEXT=kind-cluster-minio"; fi)
EOF
fi

echo "=== Wrote $ENV_FILE ==="
