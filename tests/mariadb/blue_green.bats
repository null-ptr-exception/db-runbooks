#!/usr/bin/env bats
#
# Blue-green deployment tests: verify blue-green tasks across two clusters.
#
# cluster-a: Blue MariaDB + aqsh (orchestrator)
# cluster-b: Green MariaDB + aqsh (peer)

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
  local base_url="$1" task_id="$2" max_wait="${3:-540}" accept_failed="${4:-}"
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE

    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    if [[ "$status" == "failed" ]]; then
      [[ "$accept_failed" == "true" ]] && return 0
      echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2; return 1
    fi

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

@test "blue-green status task reads Blue multiCluster state" {
  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-1",
    mdb: "mariadb"
  }')

  http_post "${AQSH_A_URL}/tasks/blue-green%2Fstatus" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$AQSH_A_URL" "$task_id"

  local result result_status
  result="$(_task_result_data)"
  result_status=$(echo "$result" | jq -r '.status // "unknown"')
  echo "blue-green/status result: ${result_status}"
  echo "$result" | jq .
  [[ "$result_status" == "ok" || "$result_status" == "OK" ]]
}

@test "blue-green create requires confirm" {
  local payload
  payload=$(jq -nc \
    --arg peer_url "$AQSH_B_URL" \
    --arg peer_token "$TOKEN" \
    '{
      namespace: "mariadb-1",
      blue_name: "mariadb",
      green_name: "mariadb-green",
      green_image: "mariadb:10.6",
      peer_aqsh_url: $peer_url,
      peer_token: $peer_token,
      backup_bucket: "db-backups",
      backup_prefix: "blue-green-test",
      backup_endpoint: "http://minio.kind-b.test:30080"
    }')

  http_post "${AQSH_A_URL}/tasks/blue-green%2Fcreate" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$AQSH_A_URL" "$task_id" 540 true

  local result result_status
  result="$(_task_result_data)"
  result_status=$(echo "$result" | jq -r '.status // "unknown"')
  local message
  message=$(echo "$result" | jq -r '.message // ""')
  echo "blue-green/create result: status=${result_status} message=${message}"
  assert_equal "$result_status" "error"
  [[ "$message" == *"confirm"* ]]
}

@test "blue-green switchover guardrails block before mutating anything" {
  local payload
  payload=$(jq -nc \
    --arg peer_url "$AQSH_B_URL" \
    --arg peer_token "$TOKEN" \
    '{
      namespace: "mariadb-1",
      blue_name: "mariadb",
      green_name: "mariadb-green",
      peer_aqsh_url: $peer_url,
      peer_token: $peer_token
    }')

  http_post "${AQSH_A_URL}/tasks/blue-green%2Fswitchover" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$AQSH_A_URL" "$task_id" 540 true

  local result result_status
  result="$(_task_result_data)"
  result_status=$(echo "$result" | jq -r '.status // "unknown"')
  local message
  message=$(echo "$result" | jq -r '.message // ""')
  echo "blue-green/switchover result: status=${result_status} message=${message}"
  assert_equal "$result_status" "error"
  [[ "$message" == *"confirm"* ]]
}

@test "blue-green delete requires confirm" {
  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-1",
    mdb: "mariadb-green"
  }')

  http_post "${AQSH_A_URL}/tasks/blue-green%2Fdelete" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$AQSH_A_URL" "$task_id" 540 true

  local result result_status
  result="$(_task_result_data)"
  result_status=$(echo "$result" | jq -r '.status // "unknown"')
  local message
  message=$(echo "$result" | jq -r '.message // ""')
  echo "blue-green/delete result: status=${result_status} message=${message}"
  assert_equal "$result_status" "error"
  [[ "$message" == *"confirm"* ]]
}
