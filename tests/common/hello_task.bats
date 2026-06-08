setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
}

setup() {
  load '../test_helper/common_setup'
}

@test "hello task completes with expected logs via aqsh-mariadb" {
  http_post "${MARIADB_AQSH_URL}/tasks/common%2Fhello" '{"name": "World"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')

  wait_for_task "$MARIADB_AQSH_URL" "$task_id" 30

  # Verify logs contain expected output
  local logs
  logs=$(kexec "curl -s -m 5 \
    -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Accept: text/event-stream' \
    '${MARIADB_AQSH_URL}/executions/${task_id}/logs?follow=false'" 2>/dev/null || true)

  echo "$logs"  # visible on failure
  [[ "$logs" == *"Hello, World!"* ]]
}

@test "hello task submits via aqsh-mongodb" {
  http_post "${MONGODB_AQSH_URL}/tasks/common%2Fhello" '{"name": "World"}'
  assert_equal "$HTTP_CODE" "202"
}
