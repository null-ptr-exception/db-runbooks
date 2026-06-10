#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DB_MODE="${DB_MODE:-single}"
BATS_BIN="bats"

# Ensure all prerequisites are installed
"${SCRIPT_DIR}/preflight.sh"

# Ensure mise-managed tool shims are available in this shell when scripts are
# run directly (for example in CI without `mise exec --`).
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi

# Teardown clusters on exit (success or failure) — registered early so
# clusters are cleaned up even if setup or deploy fails.
trap '"${SCRIPT_DIR}/teardown.sh"' EXIT

# Global setup: create clusters and deploy shared infrastructure
"${SCRIPT_DIR}/setup-clusters.sh"
"${SCRIPT_DIR}/deploy-infra.sh"

if [[ "$DB_MODE" == "dual" ]]; then
  "$BATS_BIN" --recursive \
    "${ROOT_DIR}/tests/common" \
    "${ROOT_DIR}/tests/mariadb/replication.bats" \
    "${ROOT_DIR}/tests/mariadb/status.bats" \
    "${ROOT_DIR}/tests/mariadb/sanity_check.bats" \
    "${ROOT_DIR}/tests/mariadb/create_account.bats"

  # Run MongoDB tests file-by-file to avoid occasional hangs seen when
  # invoking the whole directory in a single bats process.
  "$BATS_BIN" "${ROOT_DIR}/tests/mongodb/account_lifecycle.bats"
  "$BATS_BIN" "${ROOT_DIR}/tests/mongodb/replication.bats"
  "$BATS_BIN" "${ROOT_DIR}/tests/mongodb/restart.bats"
  "$BATS_BIN" "${ROOT_DIR}/tests/mongodb/sanity_check.bats"
else
  "$BATS_BIN" --recursive \
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
  "$BATS_BIN" --recursive "${ROOT_DIR}/tests/minio"
fi
