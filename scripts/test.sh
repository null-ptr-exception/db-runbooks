#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

# shellcheck source=/dev/null
source "$ENV_FILE"

MARIADB_AQSH_URL="http://${CLUSTER_DBS_IP}:30081"
MONGODB_AQSH_URL="http://${CLUSTER_DBS_IP}:30082"
FEDAUTH_URL="http://${CLUSTER_AUTH_IP}:30080"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

run_cmd() {
  local varname="$1"; shift
  echo "  \$ $*"
  local output
  output=$("$@" 2>&1) || true
  if [ -n "$output" ]; then
    echo "$output" | sed 's/^/  > /'
  fi
  eval "$varname=\$output"
}

# Run all test suites (TOKEN is set by tests/common/test.sh and reused below)
TOKEN=""

source "${ROOT_DIR}/tests/common/test.sh"
source "${ROOT_DIR}/tests/mariadb/test.sh"
source "${ROOT_DIR}/tests/mongodb/test.sh"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
