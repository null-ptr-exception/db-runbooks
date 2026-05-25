setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  deploy_mongodb_dual "mongo-1"
}

setup() {
  load '../test_helper/common_setup'
}

teardown_file() {
  kubectl --context kind-cluster-dbs-a delete ns mongo-1 --ignore-not-found
  kubectl --context kind-cluster-dbs-b delete ns mongo-1 --ignore-not-found
}

@test "mongodb aqsh on cluster-a is reachable" {
  http_post "${MONGODB_AQSH_A_URL}/tasks/common%2Fhello" '{"name": "replication-test-a"}'
  assert_equal "$HTTP_CODE" "202"
}

@test "mongodb aqsh on cluster-b is reachable" {
  http_post "${MONGODB_AQSH_B_URL}/tasks/common%2Fhello" '{"name": "replication-test-b"}'
  assert_equal "$HTTP_CODE" "202"
}

@test "peer-db-proxy on cluster-a reaches mongodb on cluster-b" {
  run kubectl --context kind-cluster-dbs-a -n db-ops exec \
    deploy/nginx-proxy -- sh -c \
    'nc -zv peer-db-proxy 27017 2>&1; echo "exit:$?"'
  refute_output --partial "FAILED"
}

@test "peer-db-proxy on cluster-b reaches mongodb on cluster-a" {
  run kubectl --context kind-cluster-dbs-b -n db-ops exec \
    deploy/nginx-proxy -- sh -c \
    'nc -zv peer-db-proxy 27017 2>&1; echo "exit:$?"'
  refute_output --partial "FAILED"
}

@test "restart task completes on cluster-a" {
  http_post "${MONGODB_AQSH_A_URL}/tasks/restart" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_A_URL" "$task_id"
}

@test "restart task completes on cluster-b" {
  http_post "${MONGODB_AQSH_B_URL}/tasks/restart" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_B_URL" "$task_id"
}
