#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

echo "=== Creating Kind clusters ==="

create_cluster() {
  local name="$1" config="${2:-}"
  if kind get clusters 2>/dev/null | grep -qx "$name"; then
    echo "Cluster $name already exists, skipping"
  else
    echo "Creating $name..."
    if [[ -n "$config" ]]; then
      kind create cluster --name "$name" --config "$config" --wait 60s
    else
      kind create cluster --name "$name" --wait 60s
    fi
  fi
}

create_cluster cluster-auth "${ROOT_DIR}/k8s/kind/cluster-auth.yaml"
create_cluster cluster-dbs  "${ROOT_DIR}/k8s/kind/cluster-dbs.yaml"
create_cluster cluster-apps

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
