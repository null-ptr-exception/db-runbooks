# Tests for the mongodb/rs-init aqsh task.
# Requires MONGO_TOPOLOGY != "standalone" (any RS topology).

REQUIRED_MONGO_TOPOLOGY="any-rs"

setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  local topo="${MONGO_TOPOLOGY:-standalone}"
  if [[ "$topo" == "standalone" ]]; then
    export RUN_RS_INIT_TESTS="false"
    return 0
  fi

  export RUN_RS_INIT_TESTS="true"
  assert_mongodb_ready "mongo-1"
}

setup() {
  load '../test_helper/common_setup'
  if [[ "${RUN_RS_INIT_TESTS:-false}" != "true" ]]; then
    skip "rs-init tests require a Replica Set topology (MONGO_TOPOLOGY=2+1, 1+2, or 3+0)"
  fi
}

@test "rs-init task succeeds on cluster-a" {
  local cluster_a_ip="${CLUSTER_DBS_A_IP:-${CLUSTER_DBS_IP}}"
  local cluster_b_ip="${CLUSTER_DBS_B_IP:-}"

  http_post "${MONGODB_AQSH_URL}/tasks/rs-init" \
    "{\"namespace\":\"mongo-1\",\"topology\":\"${MONGO_TOPOLOGY}\",\"cluster_a_ip\":\"${cluster_a_ip}\",\"cluster_b_ip\":\"${cluster_b_ip}\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local rs_name members_count
  rs_name=$(echo "$TASK_RESPONSE" | jq -r '.result.rs_name // empty')
  members_count=$(echo "$TASK_RESPONSE" | jq -r '.result.rs_status.members_count // 0')

  echo "RS name: ${rs_name}, members: ${members_count}"
  assert_equal "$rs_name" "rs0"
  assert [ "$members_count" -ge 1 ]
}

@test "rs-init task is idempotent" {
  local cluster_a_ip="${CLUSTER_DBS_A_IP:-${CLUSTER_DBS_IP}}"
  local cluster_b_ip="${CLUSTER_DBS_B_IP:-}"

  # Call rs-init a second time — should succeed without error
  http_post "${MONGODB_AQSH_URL}/tasks/rs-init" \
    "{\"namespace\":\"mongo-1\",\"topology\":\"${MONGO_TOPOLOGY}\",\"cluster_a_ip\":\"${cluster_a_ip}\",\"cluster_b_ip\":\"${cluster_b_ip}\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local rs_name
  rs_name=$(echo "$TASK_RESPONSE" | jq -r '.result.rs_name // empty')
  assert_equal "$rs_name" "rs0"
}
