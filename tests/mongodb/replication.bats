REQUIRED_MONGO_TOPOLOGY="2+1"

setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  skip_unless_mongo_topology "$REQUIRED_MONGO_TOPOLOGY"
  assert_mongodb_ready "mongo-1" "kind-cluster-dbs-a"
  assert_mongodb_ready "mongo-1" "kind-cluster-dbs-b"
}

setup() {
  load '../test_helper/common_setup'
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
    'command -v nc >/dev/null && nc -zv peer-db-proxy 27017'
  assert_success
}

@test "peer-db-proxy on cluster-b reaches mongodb on cluster-a" {
  run kubectl --context kind-cluster-dbs-b -n db-ops exec \
    deploy/nginx-proxy -- sh -c \
    'command -v nc >/dev/null && nc -zv peer-db-proxy 27017'
  assert_success
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
