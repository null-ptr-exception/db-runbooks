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

echo "=== Creating Kind clusters (DB_MODE=${DB_MODE}) ==="

for cluster in "${CLUSTERS[@]}"; do
  if kind get clusters 2>/dev/null | grep -qx "$cluster"; then
    echo "Cluster $cluster already exists, skipping"
  else
    echo "Creating $cluster..."
    kind create cluster --name "$cluster" --wait 60s
  fi
done

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

  _MONGO_TOPOLOGY="${MONGO_TOPOLOGY:-2+1}"
  _MARIADB_TOPOLOGY="${MARIADB_TOPOLOGY:-2+1}"

  cat > "$ENV_FILE" <<EOF
DB_MODE=${DB_MODE}
CLUSTER_AUTH_IP=${CLUSTER_AUTH_IP}
CLUSTER_DBS_A_IP=${CLUSTER_DBS_A_IP}
CLUSTER_DBS_B_IP=${CLUSTER_DBS_B_IP}
CLUSTER_DBS_IP=${CLUSTER_DBS_A_IP}
CLUSTER_DBS_CONTEXT=kind-cluster-dbs-a
CLUSTER_APPS_IP=${CLUSTER_APPS_IP}
ENABLE_MINIO=${ENABLE_MINIO}
MONGO_TOPOLOGY=${_MONGO_TOPOLOGY}
MARIADB_TOPOLOGY=${_MARIADB_TOPOLOGY}
$(if [[ "$ENABLE_MINIO" == "true" ]]; then echo "CLUSTER_MINIO_IP=${CLUSTER_MINIO_IP}"; fi)
$(if [[ "$ENABLE_MINIO" == "true" ]]; then echo "CLUSTER_MINIO_CONTEXT=kind-cluster-minio"; fi)
EOF
else
  CLUSTER_DBS_IP=$(get_node_ip cluster-dbs)
  echo "cluster-dbs:  $CLUSTER_DBS_IP"

  _MONGO_TOPOLOGY="${MONGO_TOPOLOGY:-standalone}"
  _MARIADB_TOPOLOGY="${MARIADB_TOPOLOGY:-standalone}"

  cat > "$ENV_FILE" <<EOF
DB_MODE=${DB_MODE}
CLUSTER_AUTH_IP=${CLUSTER_AUTH_IP}
CLUSTER_DBS_IP=${CLUSTER_DBS_IP}
CLUSTER_DBS_CONTEXT=kind-cluster-dbs
CLUSTER_APPS_IP=${CLUSTER_APPS_IP}
ENABLE_MINIO=${ENABLE_MINIO}
MONGO_TOPOLOGY=${_MONGO_TOPOLOGY}
MARIADB_TOPOLOGY=${_MARIADB_TOPOLOGY}
$(if [[ "$ENABLE_MINIO" == "true" ]]; then echo "CLUSTER_MINIO_IP=${CLUSTER_MINIO_IP}"; fi)
$(if [[ "$ENABLE_MINIO" == "true" ]]; then echo "CLUSTER_MINIO_CONTEXT=kind-cluster-minio"; fi)
EOF
fi

echo "=== Wrote $ENV_FILE ==="
