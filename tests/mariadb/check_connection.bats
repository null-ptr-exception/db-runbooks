#!/usr/bin/env bats

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load 'setup_suite'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="db-ops"
  MARIADB_AQSH_URL="http://aqsh-mariadb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  # Stand up a throwaway mariadb-3 instance on cluster-a (isolated from mariadb-1).
  deploy_throwaway_mariadb "mariadb-3" "$CTX_A" || return 1

  export CTX_A CTX_B NS MARIADB_AQSH_URL TEST_POD TOKEN

  # Resolve the primary service ClusterIP so tests can pass it as --ip
  export PRIMARY_SVC_IP
  # mariadb-3 is a single-replica standalone instance — mariadb-operator does
  # not create a <name>-primary Service for those (see
  # docs/mariadb/sanity-check.md), so use the regular Service instead.
  PRIMARY_SVC_IP=$(kubectl --context "$CTX_A" \
    -n mariadb-3 get service mariadb \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

teardown_file() {
  load 'setup_suite'
  delete_namespace_and_wait "kind-cluster-a" "mariadb-3"
}

kexec() {
  kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"
}

http_post() {
  local url="$1" body="$2"
  local response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\\n%{http_code}' \
    -X POST '${url}' -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Content-Type: application/json' -d '${body}'")
  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

http_get() {
  local url="$1"
  local response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\\n%{http_code}' \
    -X GET '${url}' -H 'Authorization: Bearer ${TOKEN}'")
  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-540}"
  local elapsed=0 status
  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE
    status=$(echo "$TASK_RESPONSE" | jq -r '.status' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && { echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2; return 1; }
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

_check_connection_result_data() {
  local task_response="$1"
  echo "$task_response" | jq -r \
    '(.result.data as $d | (($d | try fromjson catch null) // (if ($d | type) == "object" then $d else null end)))'
}

@test "check-connection task is registered in aqsh-mariadb" {
  http_get "${MARIADB_AQSH_URL}/tasks"
  assert_equal "$HTTP_CODE" "200"

  run echo "$HTTP_BODY"
  assert_output --partial "check-connection"
}

@test "check-connection PASS when connecting to reachable MariaDB primary service" {
  if [[ -z "${PRIMARY_SVC_IP:-}" ]]; then
    skip "Could not resolve mariadb-primary service IP in mariadb-3"
  fi

  local payload
  payload=$(jq -nc --arg ip "$PRIMARY_SVC_IP" '{
    namespace: "mariadb-3",
    mdb: "mariadb",
    ip: $ip
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fcheck-connection" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data result_status
  data=$(_check_connection_result_data "$TASK_RESPONSE")
  result_status=$(echo "$data" | jq -r '.status')

  echo "check-connection result: ${data}" >&2
  assert_equal "$result_status" "PASS"
}

@test "check-connection pod_exec check PASS when reachable" {
  if [[ -z "${PRIMARY_SVC_IP:-}" ]]; then
    skip "Could not resolve mariadb-primary service IP in mariadb-3"
  fi

  local payload
  payload=$(jq -nc --arg ip "$PRIMARY_SVC_IP" '{
    namespace: "mariadb-3",
    ip: $ip
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fcheck-connection" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data pod_exec_status
  data=$(_check_connection_result_data "$TASK_RESPONSE")
  pod_exec_status=$(echo "$data" | jq -r '.checks[] | select(.name == "pod_exec") | .status')

  assert_equal "$pod_exec_status" "PASS"
}

@test "check-connection target pod is populated in result" {
  if [[ -z "${PRIMARY_SVC_IP:-}" ]]; then
    skip "Could not resolve mariadb-primary service IP in mariadb-3"
  fi

  local payload
  payload=$(jq -nc --arg ip "$PRIMARY_SVC_IP" '{
    namespace: "mariadb-3",
    ip: $ip
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fcheck-connection" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data pod
  data=$(_check_connection_result_data "$TASK_RESPONSE")
  pod=$(echo "$data" | jq -r '.target.pod')

  [[ -n "$pod" && "$pod" != "null" ]]
}

@test "check-connection BLOCK when connecting to unreachable IP" {
  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-3",
    ip: "192.0.2.1"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fcheck-connection" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data conn_status
  data=$(_check_connection_result_data "$TASK_RESPONSE")
  conn_status=$(echo "$data" | jq -r '.checks[] | select(.name == "connection") | .status')

  echo "connection check: ${conn_status}" >&2
  assert_equal "$conn_status" "BLOCK"
}

@test "check-connection result includes connection host and port fields" {
  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-3",
    ip: "192.0.2.1",
    port: "3306"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fcheck-connection" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data host port
  data=$(_check_connection_result_data "$TASK_RESPONSE")
  host=$(echo "$data" | jq -r '.connection.host')
  port=$(echo "$data" | jq -r '.connection.port')

  assert_equal "$host" "192.0.2.1"
  assert_equal "$port" "3306"
}

@test "dual mode check-connection PASS on cluster-b primary service" {
  if [[ "${DB_MODE:-single}" != "dual" ]]; then
    skip "DB_MODE is not dual"
  fi

  local svc_ip_b
  svc_ip_b=$(kubectl --context kind-cluster-dbs-b \
    -n mariadb-3 get service mariadb \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

  if [[ -z "$svc_ip_b" ]]; then
    skip "Could not resolve mariadb-primary service IP on cluster-b"
  fi

  local payload
  payload=$(jq -nc --arg ip "$svc_ip_b" '{
    namespace: "mariadb-3",
    ip: $ip
  }')

  http_post "${MARIADB_AQSH_B_URL}/tasks/migration%2Fcheck-connection" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "${MARIADB_AQSH_B_URL}" "$task_id"

  local data result_status
  data=$(_check_connection_result_data "$TASK_RESPONSE")
  result_status=$(echo "$data" | jq -r '.status')

  assert_equal "$result_status" "PASS"
}
