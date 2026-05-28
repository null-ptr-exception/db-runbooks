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

_mariadb_status_payload() {
  if [[ "${USE_MARIADB_OPERATOR:-true}" == "true" ]]; then
    jq -nc '{
      namespace: "mariadb-3",
      resource: "mariadb",
      mdb: "mariadb"
    }'
  else
    jq -nc '{
      namespace: "mariadb-3",
      resource: "mariadb",
      mdb: "mariadb"
    }'
  fi
}

_assert_mariadb_status_ok() {
  local aqsh_url="$1"
  local label="$2"
  local payload

  payload="$(_mariadb_status_payload)"
  http_post "${aqsh_url}/tasks/status" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  if [[ -z "$task_id" ]]; then
    echo "expected task id in response: $HTTP_BODY" >&2
    return 1
  fi
  wait_for_task "$aqsh_url" "$task_id"

  local result_status pod_count
  result_status=$(echo "$TASK_RESPONSE" | jq -r '((.result.data as $data | (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))) | .status // "unknown")')
  pod_count=$(echo "$TASK_RESPONSE" | jq -r '((.result.data as $data | (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))) | .pods | length)')

  echo "${label} status result: status=${result_status} pods=${pod_count}"
  case "$result_status" in
    OK|WARN) ;;
    *)
      echo "$TASK_RESPONSE" | jq '.' >&2
      echo "expected ${label} status OK or WARN, got ${result_status}" >&2
      return 1
      ;;
  esac
  assert [ "$pod_count" -gt 0 ]
}

@test "status returns MariaDB summary" {
  _assert_mariadb_status_ok "$MARIADB_AQSH_URL" "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
}

@test "dual mode status returns MariaDB summary on cluster-b" {
  if [[ "${DB_MODE:-single}" != "dual" ]]; then
    skip "DB_MODE is not dual"
  fi

  _assert_mariadb_status_ok "$MARIADB_AQSH_B_URL" "kind-cluster-dbs-b"
}
