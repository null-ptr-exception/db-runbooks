#!/usr/bin/env bats
#
# Replication tests: verify aqsh + MariaDB on both clusters and
# cross-cluster connectivity via Istio gateway.

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="db-ops"
  AQSH_A_URL="http://aqsh-mariadb.kind-a.test:30080"
  AQSH_B_URL="http://aqsh-mariadb.kind-b.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  export CTX_A CTX_B NS AQSH_A_URL AQSH_B_URL TEST_POD TOKEN
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
  local base_url="$1" task_id="$2" max_wait="${3:-540}"
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE

    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && { echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2; return 1; }

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

_task_result_data() {
  echo "$TASK_RESPONSE" | jq -c '
    .result.data as $data |
    (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))
  '
}

# --- Tests ---

@test "mariadb aqsh on cluster-a is reachable" {
  http_post "${AQSH_A_URL}/tasks/status" '{"namespace": "mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$AQSH_A_URL" "$task_id"
}

@test "mariadb aqsh on cluster-b is reachable" {
  http_post "${AQSH_B_URL}/tasks/status" '{"namespace": "mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$AQSH_B_URL" "$task_id"
}

@test "sanity-check passes on cluster-a mariadb" {
  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-1",
    resource: "mariadb",
    mdb: "mariadb"
  }')

  http_post "${AQSH_A_URL}/tasks/sanity-check" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$AQSH_A_URL" "$task_id"

  local result result_status
  result="$(_task_result_data)"
  result_status=$(echo "$result" | jq -r '.status // "unknown"')
  echo "cluster-a sanity: status=${result_status}"
  [[ "$result_status" == "PASS" || "$result_status" == "WARN" ]]
}

@test "sanity-check passes on cluster-b mariadb" {
  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-1",
    resource: "mariadb",
    mdb: "mariadb"
  }')

  http_post "${AQSH_B_URL}/tasks/sanity-check" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$AQSH_B_URL" "$task_id"

  local result result_status
  result="$(_task_result_data)"
  result_status=$(echo "$result" | jq -r '.status // "unknown"')
  echo "cluster-b sanity: status=${result_status}"
  [[ "$result_status" == "PASS" || "$result_status" == "WARN" ]]
}

@test "restart task completes on cluster-a" {
  http_post "${AQSH_A_URL}/tasks/restart" '{"namespace": "mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$AQSH_A_URL" "$task_id"

  local result result_status
  result="$(_task_result_data)"
  result_status=$(echo "$result" | jq -r '.status // "unknown"')
  echo "cluster-a restart dry-run: status=${result_status}"
  assert_equal "$result_status" "READY"
}

@test "restart task completes on cluster-b" {
  http_post "${AQSH_B_URL}/tasks/restart" '{"namespace": "mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$AQSH_B_URL" "$task_id"

  local result result_status
  result="$(_task_result_data)"
  result_status=$(echo "$result" | jq -r '.status // "unknown"')
  echo "cluster-b restart dry-run: status=${result_status}"
  assert_equal "$result_status" "READY"
}
