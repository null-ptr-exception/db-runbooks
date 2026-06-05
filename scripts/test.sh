#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DB_MODE="${DB_MODE:-single}"
RUN_BATS="${SCRIPT_DIR}/run-bats.sh"

# Ensure all prerequisites are installed
"${SCRIPT_DIR}/preflight.sh"

# Teardown clusters on exit (success or failure) — registered early so
# clusters are cleaned up even if setup or deploy fails.
trap '"${SCRIPT_DIR}/teardown.sh"' EXIT

# Global setup: create clusters and deploy shared infrastructure
"${SCRIPT_DIR}/setup-clusters.sh"
"${SCRIPT_DIR}/deploy-infra.sh"

if [[ "$DB_MODE" == "dual" ]]; then
  "$RUN_BATS" --recursive \
    "${ROOT_DIR}/tests/common" \
    "${ROOT_DIR}/tests/mariadb/replication.bats" \
    "${ROOT_DIR}/tests/mariadb/status.bats" \
    "${ROOT_DIR}/tests/mariadb/sanity_check.bats" \
    "${ROOT_DIR}/tests/mariadb/create_account.bats" \
    "${ROOT_DIR}/tests/mongodb"
else
  "$RUN_BATS" --recursive \
    "${ROOT_DIR}/tests/common" \
    "${ROOT_DIR}/tests/mariadb/restart.bats" \
    "${ROOT_DIR}/tests/mariadb/status.bats" \
    "${ROOT_DIR}/tests/mariadb/sanity_check.bats" \
    "${ROOT_DIR}/tests/mariadb/create_account.bats" \
    "${ROOT_DIR}/tests/mongodb/restart.bats" \
    "${ROOT_DIR}/tests/mongodb/sanity_check.bats"
fi

if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then
  echo "=== Running MinIO tests ==="
  "$RUN_BATS" --recursive "${ROOT_DIR}/tests/minio"
fi
