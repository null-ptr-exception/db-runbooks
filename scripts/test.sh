#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Install helper libs if not present
"${SCRIPT_DIR}/install-bats-libs.sh"

# Global setup: create clusters and deploy shared infrastructure
"${SCRIPT_DIR}/setup-clusters.sh"
"${SCRIPT_DIR}/deploy-infra.sh"

# Teardown clusters on exit (success or failure)
trap '"${SCRIPT_DIR}/teardown.sh"' EXIT

bats --recursive \
  "${ROOT_DIR}/tests/common" \
  "${ROOT_DIR}/tests/mariadb" \
  "${ROOT_DIR}/tests/mongodb"
