#!/usr/bin/env bats

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="aqsh-test"
  AQSH_URL="http://aqsh.kind-a.test:30080"
  FEDAUTH_URL="http://fedauth.kind-a.test:30080"

  # Resolve test-client pod on cluster-b
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')

  # Create a token from cluster-b SA for authenticated requests
  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  export CTX_A CTX_B NS AQSH_URL FEDAUTH_URL TEST_POD TOKEN
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

# Run a command inside the test-client pod on cluster-b
kexec() {
  kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"
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
  local base_url="$1" task_id="$2" max_wait="${3:-120}"
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/tasks/${task_id}'")
    export TASK_RESPONSE

    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && { echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2; return 1; }
    [[ -z "$status" && -n "$TASK_RESPONSE" ]] && { echo "Task ${task_id} returned invalid response: ${TASK_RESPONSE}" >&2; return 1; }

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

# --- Auth tests ---

@test "fedauth health check returns 200 via Istio Gateway" {
  run kexec "curl -sf -o /dev/null -w '%{http_code}' '${FEDAUTH_URL}/health'"
  assert_success
  assert_output "200"
}

@test "unauthenticated request to aqsh returns 401" {
  run kexec "curl -s -o /dev/null -w '%{http_code}' '${AQSH_URL}/health'"
  assert_success
  assert_output "401"
}

@test "authenticated request from cluster-b is accepted" {
  run kexec "curl -s -o /dev/null -w '%{http_code}' \
    -H 'Authorization: Bearer ${TOKEN}' \
    '${AQSH_URL}/health'"
  assert_success
  assert_output "200"
}

# --- Task tests ---

@test "hello task completes with expected output" {
  http_post "${AQSH_URL}/tasks/common%2Fhello" '{"name": "World"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local logs
  logs=$(kexec "curl -s -m 5 \
    -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Accept: text/event-stream' \
    '${AQSH_URL}/tasks/${task_id}/logs?follow=false'" 2>/dev/null || true)

  echo "$logs"
  [[ "$logs" == *"Hello, World!"* ]]
}

# --- In-pod cross-cluster request ---

@test "in-pod request from cluster-b reaches aqsh on cluster-a via gateway" {
  run kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- \
    sh -c 'curl -s -o /dev/null -w "%{http_code}" \
      -X POST "http://aqsh.kind-a.test:30080/tasks/common%2Fhello" \
      -H "Authorization: Bearer $(cat /var/run/secrets/tokens/token)" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"from-cluster-b\"}"'
  assert_success
  assert_output "202"
}
