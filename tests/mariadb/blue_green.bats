setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
}

setup() {
  load '../test_helper/common_setup'
}

require_blue_green_demo() {
  if [[ "${DB_MODE:-single}" != "dual" ]]; then
    skip "DB_MODE is not dual"
  fi
  if [[ "${ENABLE_MINIO:-false}" != "true" ]]; then
    skip "ENABLE_MINIO is not true"
  fi
  if ! kubectl --context kind-cluster-dbs-a -n mariadb-bg get mariadb mariadb-blue >/dev/null 2>&1; then
    skip "mariadb-bg demo is not applied; run scripts/mariadb-blue-green-demo.sh apply first"
  fi
  if ! kubectl --context kind-cluster-dbs-b -n mariadb-bg get mariadb mariadb-green >/dev/null 2>&1; then
    skip "mariadb-bg demo is not applied; run scripts/mariadb-blue-green-demo.sh apply first"
  fi
}

submit_blue_green_task() {
  local aqsh_url="$1" task="$2" payload="$3"

  http_post "${aqsh_url}/tasks/${task}" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  if [[ -z "$task_id" ]]; then
    echo "expected task id in response: $HTTP_BODY" >&2
    return 1
  fi

  wait_for_task "$aqsh_url" "$task_id" 180
}

task_result_data() {
  # aqsh task results may return .result.data either as a JSON string or object.
  echo "$TASK_RESPONSE" | jq -r '
    .result.data as $data
    | (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else {} end))
    | .data
  '
}

@test "blue-green status task reads Blue multiCluster state" {
  require_blue_green_demo

  submit_blue_green_task "$MARIADB_AQSH_A_URL" "blue-green%2Fstatus" \
    '{"namespace":"mariadb-bg","mdb":"mariadb-blue"}'

  local data
  data="$(task_result_data)"
  run bash -c 'jq -e ".name == \"mariadb-blue\" and (.image | startswith(\"mariadb:10.6\"))" <<<"$1"' _ "$data"
  assert_success
}

@test "blue-green create requires confirm" {
  require_blue_green_demo

  # No confirm -> the orchestrator must refuse before provisioning anything.
  http_post "${MARIADB_AQSH_A_URL}/tasks/blue-green%2Fcreate" \
    "$(jq -nc --arg url "$MARIADB_AQSH_B_URL" --arg tok "$TOKEN" \
      '{namespace:"mariadb-bg",blue_name:"mariadb-blue",green_name:"mariadb-green",green_image:"mariadb:10.6",peer_aqsh_url:$url,peer_token:$tok,backup_bucket:"multi-cluster",backup_prefix:"blue-bats",backup_endpoint:"minio:30092"}')"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]] || { echo "no task id: $HTTP_BODY" >&2; return 1; }

  wait_for_task "$MARIADB_AQSH_A_URL" "$task_id" 60 || true
  assert_equal "$(echo "$TASK_RESPONSE" | jq -r '.status')" "failed"
  echo "$TASK_RESPONSE" | grep -qi "confirm"
}

@test "blue-green switchover guardrails block before mutating anything" {
  require_blue_green_demo

  # Force a deterministic guardrail failure regardless of fixture state: the
  # green validate (phase 1, read-only) must reject an impossible expected
  # version before the orchestrator mutates anything. Without this pin, the
  # payload would perform a REAL switchover on a fresh fixture where Blue is
  # still primary.
  http_post "${MARIADB_AQSH_A_URL}/tasks/blue-green%2Fswitchover" \
    "$(jq -nc --arg url "$MARIADB_AQSH_B_URL" --arg tok "$TOKEN" \
      '{namespace:"mariadb-bg",blue_name:"mariadb-blue",green_name:"mariadb-green",expected_green_version:"0.0-bats-guardrail-pin",peer_aqsh_url:$url,peer_token:$tok,confirm:"true"}')"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]] || { echo "no task id: $HTTP_BODY" >&2; return 1; }

  wait_for_task "$MARIADB_AQSH_A_URL" "$task_id" 180 || true
  assert_equal "$(echo "$TASK_RESPONSE" | jq -r '.status')" "failed"
  echo "$TASK_RESPONSE" | grep -qi "guardrail"
}

@test "blue-green delete requires confirm" {
  require_blue_green_demo

  # No confirm -> the task must refuse before deleting anything.
  http_post "${MARIADB_AQSH_B_URL}/tasks/blue-green%2Fdelete" \
    '{"namespace":"mariadb-bg","mdb":"mariadb-green"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]] || { echo "no task id: $HTTP_BODY" >&2; return 1; }

  wait_for_task "$MARIADB_AQSH_B_URL" "$task_id" 60 || true
  assert_equal "$(echo "$TASK_RESPONSE" | jq -r '.status')" "failed"
  echo "$TASK_RESPONSE" | grep -qi "confirm"
}
