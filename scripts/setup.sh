#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================="
echo " db-runbooks: Multi-Cluster Sandbox Setup"
echo "========================================="

echo ""
echo "--- Phase 0: Preflight checks ---"
"${SCRIPT_DIR}/preflight.sh"

echo ""
echo "--- Phase 1: Create Kind clusters ---"
"${SCRIPT_DIR}/setup-clusters.sh"

echo ""
echo "--- Phase 2: Deploy all components ---"
"${SCRIPT_DIR}/deploy.sh"

echo ""
echo "--- Phase 3: Run tests ---"
"${SCRIPT_DIR}/test.sh"

echo ""
echo "========================================="
echo " Setup complete!"
echo "========================================="
