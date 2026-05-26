setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  deploy_mariadb_dual "mariadb-1"
}

setup() {
  load '../test_helper/common_setup'
}

teardown_file() {
  kubectl --context kind-cluster-dbs-a delete ns mariadb-1 --ignore-not-found
  kubectl --context kind-cluster-dbs-b delete ns mariadb-1 --ignore-not-found
}

@test "mariadb aqsh on cluster-a is reachable" {
  http_post "${MARIADB_AQSH_A_URL}/tasks/common%2Fhello" '{"name": "replication-test-a"}'
  assert_equal "$HTTP_CODE" "202"
}

@test "mariadb aqsh on cluster-b is reachable" {
  http_post "${MARIADB_AQSH_B_URL}/tasks/common%2Fhello" '{"name": "replication-test-b"}'
  assert_equal "$HTTP_CODE" "202"
}

@test "restart task completes on cluster-a" {
  http_post "${MARIADB_AQSH_A_URL}/tasks/restart" '{"namespace": "mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MARIADB_AQSH_A_URL" "$task_id"
}

@test "restart task completes on cluster-b" {
  http_post "${MARIADB_AQSH_B_URL}/tasks/restart" '{"namespace": "mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MARIADB_AQSH_B_URL" "$task_id"
}
