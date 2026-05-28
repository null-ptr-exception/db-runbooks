REQUIRED_MONGO_TOPOLOGY="2+1"

setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token

  if [[ "${MONGO_TOPOLOGY:-standalone}" != "$REQUIRED_MONGO_TOPOLOGY" ]]; then
    export RUN_MONGO_REPLICATION_TESTS="false"
    return 0
  fi

  export RUN_MONGO_REPLICATION_TESTS="true"
  assert_mongodb_ready "mongo-1" "kind-cluster-dbs-a"
  assert_mongodb_ready "mongo-1" "kind-cluster-dbs-b"
}

setup() {
  load '../test_helper/common_setup'
  if [[ "${RUN_MONGO_REPLICATION_TESTS:-false}" != "true" ]]; then
    skip "Requires MONGO_TOPOLOGY=${REQUIRED_MONGO_TOPOLOGY}, current=${MONGO_TOPOLOGY:-standalone}"
  fi
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

# ---------------------------------------------------------------------------
# RS correctness tests (require MONGO_TOPOLOGY=2+1)
# ---------------------------------------------------------------------------

@test "rs-init task initializes Replica Set on cluster-a" {
  local cluster_a_ip="${CLUSTER_DBS_A_IP}"
  local cluster_b_ip="${CLUSTER_DBS_B_IP}"

  http_post "${MONGODB_AQSH_A_URL}/tasks/rs-init" \
    "{\"namespace\":\"mongo-1\",\"topology\":\"${MONGO_TOPOLOGY}\",\"cluster_a_ip\":\"${cluster_a_ip}\",\"cluster_b_ip\":\"${cluster_b_ip}\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_A_URL" "$task_id"

  local rs_name members_count
  rs_name=$(echo "$TASK_RESPONSE" | jq -r '.result.rs_name // empty')
  members_count=$(echo "$TASK_RESPONSE" | jq -r '.result.rs_status.members_count // 0')

  echo "RS: ${rs_name}, members: ${members_count}"
  assert_equal "$rs_name" "rs0"
  assert [ "$members_count" -ge 2 ]
}

@test "sanity-check reports RS members healthy after rs-init" {
  http_post "${MONGODB_AQSH_A_URL}/tasks/sanity-check" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_A_URL" "$task_id"

  local result_status
  result_status=$(echo "$TASK_RESPONSE" | jq -r '.result.status // "unknown"')
  echo "Sanity check result: ${result_status}"
  assert [ "$result_status" != "critical" ]
}
