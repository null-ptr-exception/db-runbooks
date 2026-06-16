#!/usr/bin/env bats

setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  if [[ "${DB_MODE:-single}" == "dual" ]]; then
    deploy_mariadb_dual "mariadb-3"
  else
    deploy_mariadb "mariadb-3"
  fi
}

setup() {
  load '../test_helper/common_setup'
}

teardown_file() {
  if [[ "${DB_MODE:-single}" == "dual" ]]; then
    kubectl --context kind-cluster-dbs-a delete ns mariadb-3 --ignore-not-found
    kubectl --context kind-cluster-dbs-b delete ns mariadb-3 --ignore-not-found
  else
    kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" delete ns mariadb-3 --ignore-not-found
  fi
}

_preflight_result_data() {
  local task_response="$1"
  echo "$task_response" | jq -r \
    '(.result.data as $d | (($d | try fromjson catch null) // (if ($d | type) == "object" then $d else null end)))'
}

@test "migration-preflight task is registered in aqsh-mariadb" {
  http_post "${MARIADB_AQSH_URL}/tasks" ''
  assert_equal "$HTTP_CODE" "200"

  run echo "$HTTP_BODY"
  assert_output --partial "migration-preflight"
}

@test "migration-preflight PASS when only pod exec is checked (no MinIO endpoint)" {
  local payload
  payload=$(jq -nc '{namespace: "mariadb-3"}')

  http_post "${MARIADB_AQSH_URL}/tasks/migration-preflight" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data result_status
  data=$(_preflight_result_data "$TASK_RESPONSE")
  result_status=$(echo "$data" | jq -r '.status')

  echo "preflight result: ${data}" >&2
  # Without a minio endpoint the overall status is WARN (endpoint not provided)
  # but pod_exec must be PASS
  local pod_exec_status
  pod_exec_status=$(echo "$data" | jq -r '.checks[] | select(.name == "pod_exec") | .status')
  assert_equal "$pod_exec_status" "PASS"

  case "$result_status" in
    PASS|WARN) ;;
    *)
      echo "Unexpected preflight status: ${result_status}" >&2
      echo "$data" | jq -r '.checks[] | "check=" + .name + " status=" + .status + " reason=" + .reason_code' >&2
      return 1
      ;;
  esac
}

@test "migration-preflight target pod is populated in result" {
  local payload
  payload=$(jq -nc '{namespace: "mariadb-3"}')

  http_post "${MARIADB_AQSH_URL}/tasks/migration-preflight" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data pod
  data=$(_preflight_result_data "$TASK_RESPONSE")
  pod=$(echo "$data" | jq -r '.target.pod')

  [[ -n "$pod" && "$pod" != "null" ]]
}

@test "migration-preflight WARN check present when minio endpoint is omitted" {
  local payload
  payload=$(jq -nc '{namespace: "mariadb-3"}')

  http_post "${MARIADB_AQSH_URL}/tasks/migration-preflight" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data minio_reason
  data=$(_preflight_result_data "$TASK_RESPONSE")
  minio_reason=$(echo "$data" | jq -r '.checks[] | select(.name == "minio") | .reason_code')

  assert_equal "$minio_reason" "MINIO_ENDPOINT_NOT_PROVIDED"
}

@test "migration-preflight with unreachable minio endpoint returns BLOCK on minio_tcp" {
  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-3",
    minio_endpoint: "http://192.0.2.1:9000"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration-preflight" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data tcp_status
  data=$(_preflight_result_data "$TASK_RESPONSE")
  tcp_status=$(echo "$data" | jq -r '.checks[] | select(.name == "minio_tcp") | .status')

  echo "minio_tcp check: ${tcp_status}" >&2
  assert_equal "$tcp_status" "BLOCK"
}

@test "migration-preflight with minio endpoint includes minio checks in result" {
  if [[ "${ENABLE_MINIO:-false}" != "true" ]]; then
    skip "MinIO not enabled (ENABLE_MINIO!=true)"
  fi

  local payload
  payload=$(jq -nc --arg ep "http://${CLUSTER_DBS_IP}:30083/minio" '{
    namespace: "mariadb-3",
    minio_endpoint: $ep,
    minio_access_key: "minioadmin",
    minio_secret_key: "minioadmin-changeme-prod",
    minio_bucket: "db-backups"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration-preflight" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data
  data=$(_preflight_result_data "$TASK_RESPONSE")
  echo "preflight result: ${data}" >&2

  local tcp_status auth_status
  tcp_status=$(echo "$data" | jq -r '.checks[] | select(.name == "minio_tcp") | .status')
  auth_status=$(echo "$data" | jq -r '.checks[] | select(.name == "minio_auth") | .status')

  assert_equal "$tcp_status" "PASS"
  assert_equal "$auth_status" "PASS"
}

@test "dual mode migration-preflight PASS on cluster-b" {
  if [[ "${DB_MODE:-single}" != "dual" ]]; then
    skip "DB_MODE is not dual"
  fi

  local payload
  payload=$(jq -nc '{namespace: "mariadb-3"}')

  http_post "$MARIADB_AQSH_B_URL/tasks/migration-preflight" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_B_URL" "$task_id"

  local data pod_exec_status
  data=$(_preflight_result_data "$TASK_RESPONSE")
  pod_exec_status=$(echo "$data" | jq -r '.checks[] | select(.name == "pod_exec") | .status')

  assert_equal "$pod_exec_status" "PASS"
}
