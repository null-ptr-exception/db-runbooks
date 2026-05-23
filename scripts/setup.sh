#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

echo "========================================="
echo " db-runbooks: Multi-Cluster Sandbox Setup"
echo "========================================="

echo ""
echo "--- Phase 0: Preflight checks ---"
"${SCRIPT_DIR}/preflight.sh"

echo ""
echo "--- Phase 1: Create Kind clusters ---"
"${SCRIPT_DIR}/setup-clusters.sh"

# shellcheck source=/dev/null
source "$ENV_FILE"
export MONGO_REPLICATION_MODE

echo ""
echo "--- Phase 2: Deploy all components ---"
"${SCRIPT_DIR}/deploy.sh"

echo ""
echo "--- Phase 3: Run tests ---"
echo "Waiting for region-a nginx health endpoint to be ready..."
for i in $(seq 1 30); do
  if curl -fsS "http://${REGION_A_IP}:30080/healthz" >/dev/null 2>&1; then
    echo "region-a nginx is healthy"
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    echo "ERROR: region-a nginx health endpoint did not become ready in time" >&2
    exit 1
  fi
  sleep 2
done

"${SCRIPT_DIR}/test.sh"

echo ""
echo "========================================="
echo " Setup complete!"
echo "========================================="
