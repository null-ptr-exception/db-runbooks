#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

MODE="${MODE:-single}"
MONGO_REPLICATION_MODE="${MONGO_REPLICATION_MODE:-3+3}"
export MONGO_REPLICATION_MODE

echo "=== Creating Kind clusters (MODE=${MODE}) ==="

CLUSTERS=(cluster-region-a cluster-apps-minio)
[[ "$MODE" == "multi" ]] && CLUSTERS+=(cluster-region-b)

for cluster in "${CLUSTERS[@]}"; do
  if kind get clusters 2>/dev/null | grep -qx "$cluster"; then
    echo "Cluster $cluster already exists, skipping"
  else
    echo "Creating $cluster..."
    kind create cluster --name "$cluster" --wait 60s
  fi
done

echo "=== Extracting Docker node IPs ==="

get_node_ip() {
  docker inspect "${1}-control-plane" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
}

REGION_A_IP=$(get_node_ip cluster-region-a)
APPS_MINIO_IP=$(get_node_ip cluster-apps-minio)

echo "cluster-region-a:   $REGION_A_IP"
echo "cluster-apps-minio: $APPS_MINIO_IP"

cat > "$ENV_FILE" <<EOF
MODE=${MODE}
MONGO_REPLICATION_MODE=${MONGO_REPLICATION_MODE}
REGION_A_IP=${REGION_A_IP}
APPS_MINIO_IP=${APPS_MINIO_IP}
EOF

if [[ "$MODE" == "multi" ]]; then
  REGION_B_IP=$(get_node_ip cluster-region-b)
  echo "cluster-region-b:   $REGION_B_IP"
  echo "REGION_B_IP=${REGION_B_IP}" >> "$ENV_FILE"
fi

echo "=== Wrote $ENV_FILE ==="
