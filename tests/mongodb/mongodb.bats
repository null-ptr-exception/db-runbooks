#!/usr/bin/env bats

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"

  # Resolve test-client pod on cluster-b
  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  # Create a token from cluster-b SA
  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  export CTX_A CTX_B NS AQSH_URL TEST_POD TOKEN
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

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
  local base_url="$1" task_id="$2" max_wait="${3:-300}"
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE

    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && { echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2; return 1; }
    [[ -z "$status" && -n "$TASK_RESPONSE" ]] && { echo "Task ${task_id} invalid response: ${TASK_RESPONSE}" >&2; return 1; }

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

# --- Tests ---

@test "sanity-check completes without critical issues" {
  http_post "${AQSH_URL}/tasks/sanity-check" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result_status
  result_status=$(echo "$TASK_RESPONSE" | jq -r '.result.data.status // .result.status // "unknown"')
  echo "sanity result: status=${result_status}"
  assert [ "$result_status" != "critical" ]
}

@test "restart completes and all pods ready" {
  local before_generation
  before_generation=$(kubectl --context "$CTX_A" -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.status.observedGeneration}')

  http_post "${AQSH_URL}/tasks/restart" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  kubectl --context "$CTX_A" -n mongo-1 wait pod \
    -l app=mongodb --for=condition=Ready --timeout=120s

  local after_generation ready replicas
  after_generation=$(kubectl --context "$CTX_A" -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.status.observedGeneration}')
  ready=$(kubectl --context "$CTX_A" -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.status.readyReplicas}')
  replicas=$(kubectl --context "$CTX_A" -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.status.replicas}')

  echo "generation: ${before_generation} → ${after_generation}, ready: ${ready}/${replicas}"
  [[ "$before_generation" =~ ^[0-9]+$ ]] || { echo "before_generation is not numeric: '${before_generation}'" >&2; return 1; }
  [[ "$after_generation" =~ ^[0-9]+$ ]] || { echo "after_generation is not numeric: '${after_generation}'" >&2; return 1; }
  assert [ "$after_generation" -gt "$before_generation" ]
  assert_equal "$ready" "$replicas"
}
