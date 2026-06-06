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
  run bash -c 'jq -e ".name == \"mariadb-blue\" and .image == \"mariadb:10.6\"" <<<"$1"' _ "$data"
  assert_success
}

@test "blue-green create-physical-backup returns bootstrap descriptor" {
  require_blue_green_demo
  if ! kubectl --context kind-cluster-dbs-a -n mariadb-bg get mariadb mariadb-blue -o json \
    | jq -e '.status.conditions[]? | select(.type == "Ready" and .status == "True")' >/dev/null; then
    skip "mariadb-blue is not Ready; physical backup provisioning is only tested before switchover"
  fi

  submit_blue_green_task "$MARIADB_AQSH_A_URL" "blue-green%2Fcreate-physical-backup" \
    '{"namespace":"mariadb-bg","mdb":"mariadb-blue","backup_name":"physicalbackup-bats","backup_bucket":"multi-cluster","backup_prefix":"blue-bats","backup_endpoint":"'"${CLUSTER_MINIO_IP}"':30092","confirm":"true"}'

  local data
  data="$(task_result_data)"
  run bash -c 'jq -e ".source == \"mariadb-blue\" and .backupName == \"physicalbackup-bats\" and .backupContentType == \"Physical\"" <<<"$1"' _ "$data"
  assert_success
}

@test "blue-green validate task accepts Green after switchover" {
  require_blue_green_demo

  submit_blue_green_task "$MARIADB_AQSH_B_URL" "blue-green%2Fvalidate" \
    '{"namespace":"mariadb-bg","mdb":"mariadb-green","expected_version":"10.11","expected_primary":"mariadb-green"}'

  local data
  data="$(task_result_data)"
  run bash -c 'jq -e ".name == \"mariadb-green\" and (.version | startswith(\"10.11\"))" <<<"$1"' _ "$data"
  assert_success
}

@test "blue-green write-probe task writes through Green primary" {
  require_blue_green_demo

  submit_blue_green_task "$MARIADB_AQSH_B_URL" "blue-green%2Fwrite-probe" \
    '{"namespace":"mariadb-bg","mdb":"mariadb-green","confirm":"true","id":"4","note":"bats-aqsh-after-switchover"}'

  local data
  data="$(task_result_data)"
  run bash -c 'jq -e ".database == \"bgtest\" and .table == \"events\" and .id == 4 and .count == 1" <<<"$1"' _ "$data"
  assert_success
}
