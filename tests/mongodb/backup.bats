setup_file() {
  load 'test_helper'
  mongodb_suite_setup --create-token
}

setup() {
  load 'test_helper'
}

@test "backup task completes for mongo-1" {
  local payload
  payload=$(jq -nc \
    --arg endpoint "$MINIO_ENDPOINT" \
    '{namespace: "mongo-1", minio_endpoint: $endpoint}')

  http_post "${MONGODB_AQSH_URL}/tasks/backup" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result_json
  result_json=$(echo "$TASK_RESPONSE" | jq -r '.result.data')
  if [[ "$result_json" == "null" ]] || [[ -z "$result_json" ]]; then
    echo "No result data in task response"
    false
  fi

  local resp_status backup_path backup_size
  resp_status=$(echo "$result_json" | jq -r '.status // empty')
  backup_path=$(echo "$result_json" | jq -r '.data.path // .path // empty')
  backup_size=$(echo "$result_json" | jq -r '.data.size_bytes // .size_bytes // 0')

  echo "backup result: status=${resp_status} path=${backup_path} size=${backup_size}"
  assert_equal "$resp_status" "success"
  assert [ "$backup_size" -gt 0 ]
}
