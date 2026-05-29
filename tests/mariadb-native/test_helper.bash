#!/usr/bin/env bash

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${HELPER_DIR}/../.." && pwd)"

load "${ROOT_DIR}/tests/test_helper/bats-support/load.bash"
load "${ROOT_DIR}/tests/test_helper/bats-assert/load.bash"

export ROOT_DIR
export CTX_A="kind-cluster-a"
export CTX_B="kind-cluster-b"

export MARIADB_AQSH_URL="http://aqsh-mariadb.kind-a.test:30080"
export FEDAUTH_URL="http://fedauth.kind-a.test:30080"

mariadb_suite_setup() {
  kubectl --context "$CTX_B" -n app-a wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n app-a \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  export TEST_POD

  if [[ "${1:-}" == "--create-token" ]]; then
    TOKEN=$(kubectl --context "$CTX_B" -n app-a create token test-client --duration=30m)
    export TOKEN
  fi
}

kexec() {
  kubectl --context "$CTX_B" -n app-a exec "$TEST_POD" -- sh -c "$1"
}

http_post() {
  local url="$1" body="$2"
  local response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\\n%{http_code}' \
    -X POST '${url}' \
    -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Content-Type: application/json' \
    -d '${body}'")

  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-540}"
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/tasks/${task_id}'")
    export TASK_RESPONSE

    status=$(echo "$TASK_RESPONSE" | jq -r '.status' 2>/dev/null || true)

    if [[ "$status" == "completed" ]]; then
      return 0
    elif [[ "$status" == "failed" ]]; then
      echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2
      return 1
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}
