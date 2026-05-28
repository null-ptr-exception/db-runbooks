#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

DB_MODE="${DB_MODE:-single}"

# Teardown clusters on exit (success or failure) — registered early so
# clusters are cleaned up even if setup or deploy fails.
trap '"${SCRIPT_DIR}/teardown.sh"' EXIT

# Install helper libs if not present
"${SCRIPT_DIR}/install-bats-libs.sh"

# Global setup: create clusters and deploy shared infrastructure
"${SCRIPT_DIR}/setup-clusters.sh"
"${SCRIPT_DIR}/deploy-infra.sh"
"${SCRIPT_DIR}/deploy.sh"

# Run all tests — topology guards (skip_unless_mongo_topology /
# skip_unless_mariadb_topology) handle skipping tests that require a topology
# not currently deployed (e.g., replication tests skip in standalone mode).
bats --recursive \
  "${ROOT_DIR}/tests/common" \
  "${ROOT_DIR}/tests/mariadb" \
  "${ROOT_DIR}/tests/mongodb"

if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then
  echo "=== Running MinIO tests ==="
  bats --recursive "${ROOT_DIR}/tests/minio"
fi
