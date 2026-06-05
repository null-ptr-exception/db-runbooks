#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DB_MODE="${DB_MODE:-single}"
BATS_BIN="bats"

resolve_bats() {
  if ! command -v mise >/dev/null 2>&1; then
    return
  fi

  local mise_bats_bin bats_bin bats_core_dir
  mise_bats_bin="$(mise which bats 2>/dev/null || true)"
  if [[ -z "$mise_bats_bin" || ! -x "$mise_bats_bin" ]]; then
    return
  fi

  # mise can expose bats through a symlink; resolve it before deriving helpers.
  bats_bin="$(readlink -f "$mise_bats_bin" 2>/dev/null || printf '%s\n' "$mise_bats_bin")"
  BATS_BIN="$bats_bin"

  bats_core_dir="${bats_bin%/bin/bats}/libexec/bats-core"
  if [[ -d "$bats_core_dir" ]]; then
    export PATH="$bats_core_dir:$PATH"
  fi
}

# Ensure all prerequisites are installed
"${SCRIPT_DIR}/preflight.sh"

resolve_bats

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
    "${ROOT_DIR}/tests/mariadb/create_account.bats" \
    "${ROOT_DIR}/tests/mongodb"
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
