#!/usr/bin/env bats

setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  if [[ "${DB_MODE:-single}" == "dual" ]]; then
    deploy_mariadb_dual "mariadb-3"
  else
    deploy_mariadb "mariadb-3"
  fi

  # Resolve the primary service ClusterIP so tests can pass it as --ip
  export PRIMARY_SVC_IP
  PRIMARY_SVC_IP=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" \
    -n mariadb-3 get service mariadb-primary \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
}

setup() {
  load '../test_helper/common_setup'
}

teardown_file() {
  if [[ "${DB_MODE:-single}" == "dual" ]]; then
    kubectl --context kind-cluster-dbs-a delete ns mariadb-3 --ignore-not-found
    kubectl --context kind-cluster-dbs-b delete ns mariadb-3 --ignore-not-found
  else
    kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" delete ns mariadb-3 --ignore-not-found
  fi
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
    resource: "mariadb",
    mdb: "mariadb",
    ip: $ip
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/check-connection" "$payload"
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

  http_post "${MARIADB_AQSH_URL}/tasks/check-connection" "$payload"
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

  http_post "${MARIADB_AQSH_URL}/tasks/check-connection" "$payload"
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

  http_post "${MARIADB_AQSH_URL}/tasks/check-connection" "$payload"
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

  http_post "${MARIADB_AQSH_URL}/tasks/check-connection" "$payload"
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
    -n mariadb-3 get service mariadb-primary \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

  if [[ -z "$svc_ip_b" ]]; then
    skip "Could not resolve mariadb-primary service IP on cluster-b"
  fi

  local payload
  payload=$(jq -nc --arg ip "$svc_ip_b" '{
    namespace: "mariadb-3",
    ip: $ip
  }')

  http_post "${MARIADB_AQSH_B_URL}/tasks/check-connection" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "${MARIADB_AQSH_B_URL}" "$task_id"

  local data result_status
  data=$(_check_connection_result_data "$TASK_RESPONSE")
  result_status=$(echo "$data" | jq -r '.status')

  assert_equal "$result_status" "PASS"
}
