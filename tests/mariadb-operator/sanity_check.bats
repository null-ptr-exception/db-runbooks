setup_file() {
  load 'test_helper'
  mariadb_suite_setup --create-token
}

setup() {
  load 'test_helper'
}

@test "sanity-check completes without blocking issues" {
  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-1",
    resource: "mariadb",
    mdb: "mariadb"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/sanity-check" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local result_status
  result_status=$(echo "$TASK_RESPONSE" | jq -r '
    (.result.data as $data |
      (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))
    ) | .status // "unknown"')

  echo "sanity result: status=${result_status}"
  assert [ "$result_status" != "CRITICAL" ]
  assert [ "$result_status" != "unknown" ]
}
