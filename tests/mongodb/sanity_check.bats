setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  deploy_mongodb "mongo-1"
}

setup() {
  load '../test_helper/common_setup'
}

teardown_file() {
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" delete ns mongo-1 --ignore-not-found
}

@test "sanity-check completes without critical issues" {
  http_post "${MONGODB_AQSH_URL}/tasks/sanity-check" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result_status pass_count warn_count fail_count
  result_status=$(echo "$TASK_RESPONSE" | jq -r '.result.status // "unknown"')
  pass_count=$(echo "$TASK_RESPONSE" | jq -r '.result.pass // 0')
  warn_count=$(echo "$TASK_RESPONSE" | jq -r '.result.warn // 0')
  fail_count=$(echo "$TASK_RESPONSE" | jq -r '.result.fail // 0')

  echo "sanity result: status=${result_status} pass=${pass_count} warn=${warn_count} fail=${fail_count}"
  assert [ "$result_status" != "critical" ]
}
