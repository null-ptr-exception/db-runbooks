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

_get_db_env_payload() {
  local envs="${1:?envs required}"
  jq -nc --arg envs "$envs" '{
    namespace: "mariadb-3",
    resource: "mariadb",
    mdb: "mariadb",
    envs: $envs
  }'
}

_task_result_vars() {
  echo "$TASK_RESPONSE" | jq -r '
    (.result.data as $data |
      (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))
    ) | .vars'
}

@test "get-db-env returns MARIADB_ROOT_PASSWORD from the pod" {
  local payload
  payload="$(_get_db_env_payload "MARIADB_ROOT_PASSWORD")"

  http_post "${MARIADB_AQSH_URL}/tasks/get-db-env" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  if [[ -z "$task_id" ]]; then
    echo "expected task id in response: $HTTP_BODY" >&2
    return 1
  fi
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local result_status vars password
  result_status=$(echo "$TASK_RESPONSE" | jq -r '
    (.result.data as $data |
      (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))
    ) | .status')
  vars="$(_task_result_vars)"
  password=$(echo "$vars" | jq -r '.MARIADB_ROOT_PASSWORD // empty')

  assert_equal "$result_status" "OK"
  assert [ -n "$password" ]
}

@test "get-db-env returns null for an unset env var" {
  local payload
  payload="$(_get_db_env_payload "MARIADB_ROOT_PASSWORD,THIS_VAR_DOES_NOT_EXIST")"

  http_post "${MARIADB_AQSH_URL}/tasks/get-db-env" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local vars missing
  vars="$(_task_result_vars)"
  missing=$(echo "$vars" | jq -r '.THIS_VAR_DOES_NOT_EXIST')

  assert_equal "$missing" "null"
}
