#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

CLUSTERS=(cluster-auth cluster-dbs cluster-apps)

echo "=== Creating Kind clusters ==="

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
CLUSTER_DBS_IP=$(get_node_ip cluster-dbs)
CLUSTER_APPS_IP=$(get_node_ip cluster-apps)

echo "cluster-auth: $CLUSTER_AUTH_IP"
echo "cluster-dbs:  $CLUSTER_DBS_IP"
echo "cluster-apps: $CLUSTER_APPS_IP"

cat > "$ENV_FILE" <<EOF
CLUSTER_AUTH_IP=${CLUSTER_AUTH_IP}
CLUSTER_DBS_IP=${CLUSTER_DBS_IP}
CLUSTER_APPS_IP=${CLUSTER_APPS_IP}
EOF

echo "=== Wrote $ENV_FILE ==="
