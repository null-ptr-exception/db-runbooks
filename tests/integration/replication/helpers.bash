#!/usr/bin/env bash

setup_env() {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  ENV_FILE="${ROOT_DIR}/.env"
  [ -f "$ENV_FILE" ] || fail "Missing ${ENV_FILE}. Run setup first."

  # shellcheck source=/dev/null
  source "$ENV_FILE"

  export MODE REGION_A_IP APPS_MINIO_IP
  export REGION_B_IP="${REGION_B_IP:-}"
  export MONGO_REPLICATION_MODE="${MONGO_REPLICATION_MODE:-3+3}"
}

require_multi_mode() {
  [ "${MODE:-single}" = "multi" ] || skip "Requires MODE=multi"
  [ -n "${REGION_A_IP:-}" ] || skip "Missing REGION_A_IP"
  [ -n "${REGION_B_IP:-}" ] || skip "Missing REGION_B_IP"
}

retry_curl() {
  local url="$1"
  local expected_code="$2"
  local token="${3:-}"
  local auth_scheme="Bearer"

  local code
  for _ in $(seq 1 30); do
    if [ -n "$token" ]; then
      code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: ${auth_scheme} ${token}" "$url" || true)
    else
      code=$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)
    fi
    [ "$code" = "$expected_code" ] && return 0
    sleep 2
  done
  return 1
}

wait_for_replication() {
  local command="$1"
  local attempts="${2:-30}"
  local sleep_seconds="${3:-2}"

  for _ in $(seq 1 "$attempts"); do
    if bash -ceu "$command" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_seconds"
  done
  return 1
}

assert_success() {
  # shellcheck disable=SC2154
  [ "$status" -eq 0 ]
}

assert_output() {
  # shellcheck disable=SC2154
  if [ "${1:-}" = "--partial" ]; then
    shift
    [[ "$output" == *"$1"* ]]
  else
    [ "$output" = "$1" ]
  fi
}
