setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  deploy_mariadb "mariadb-2"
}

setup() {
  load '../test_helper/common_setup'
}

teardown_file() {
  kubectl --context kind-cluster-dbs delete ns mariadb-2 --ignore-not-found
}

@test "sanity-check completes without blocking issues" {
  http_post "${MARIADB_AQSH_URL}/tasks/sanity-check" \
    '{"namespace": "mariadb-2", "resource": "mariadb", "mdb": "mariadb"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  if [[ -z "$task_id" ]]; then
    echo "expected task id in response: $HTTP_BODY" >&2
    return 1
  fi
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local result_status reason_code
  result_status=$(echo "$TASK_RESPONSE" | jq -r '((.result.data as $data | (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))) | .status // "unknown")')
  reason_code=$(echo "$TASK_RESPONSE" | jq -r '((.result.data as $data | (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))) | .reason_code // "unknown")')

  echo "sanity result: status=${result_status} reason=${reason_code}"
  case "$result_status" in
    PASS|WARN) ;;
    *)
      echo "expected sanity status PASS or WARN, got ${result_status}" >&2
      return 1
      ;;
  esac
  assert [ "$reason_code" != "unknown" ]
  assert [ -n "$reason_code" ]
}
