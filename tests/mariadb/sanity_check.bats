setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  if [[ "${DB_MODE:-single}" == "dual" ]]; then
    deploy_mariadb_dual "mariadb-2"
  else
    deploy_mariadb "mariadb-2"
  fi
}

setup() {
  load '../test_helper/common_setup'
}

teardown_file() {
  if [[ "${DB_MODE:-single}" == "dual" ]]; then
    kubectl --context kind-cluster-dbs-a delete ns mariadb-2 --ignore-not-found
    kubectl --context kind-cluster-dbs-b delete ns mariadb-2 --ignore-not-found
  else
    kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" delete ns mariadb-2 --ignore-not-found
  fi
}

_mariadb_sanity_payload() {
  if [[ "${USE_MARIADB_OPERATOR:-true}" == "true" ]]; then
    jq -nc '{
      namespace: "mariadb-2",
      resource: "mariadb",
      mdb: "mariadb"
    }'
  else
    jq -nc '{
      namespace: "mariadb-2",
      resource: "mariadb",
      mdb: "mariadb",
      check_operator: "false",
      check_pods: "false",
      check_service: "false",
      check_replication: "false",
      check_semi_sync: "false"
    }'
  fi
}

_assert_mariadb_sanity_ok() {
  local aqsh_url="$1"
  local label="$2"
  local payload

  payload="$(_mariadb_sanity_payload)"
  http_post "${aqsh_url}/tasks/sanity-check" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  if [[ -z "$task_id" ]]; then
    echo "expected task id in response: $HTTP_BODY" >&2
    return 1
  fi
  wait_for_task "$aqsh_url" "$task_id"

  local result_status reason_code
  result_status=$(echo "$TASK_RESPONSE" | jq -r '((.result.data as $data | (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))) | .status // "unknown")')
  reason_code=$(echo "$TASK_RESPONSE" | jq -r '((.result.data as $data | (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))) | .reason_code // "unknown")')

  echo "${label} sanity result: status=${result_status} reason=${reason_code}"
  case "$result_status" in
    PASS|WARN) ;;
    *)
      echo "$TASK_RESPONSE" | jq -r '
        ((.result.data as $data | (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))) | .checks[]? |
        "check=" + .name + " status=" + .status + " reason=" + .reason_code + " detail=" + .detail
        )
      ' >&2
      echo "expected ${label} sanity status PASS or WARN, got ${result_status}" >&2
      return 1
      ;;
  esac
  assert [ "$reason_code" != "unknown" ]
  assert [ -n "$reason_code" ]
}

@test "sanity-check completes without blocking issues" {
  _assert_mariadb_sanity_ok "$MARIADB_AQSH_URL" "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
}

@test "dual mode sanity-check completes on cluster-b" {
  if [[ "${DB_MODE:-single}" != "dual" ]]; then
    skip "DB_MODE is not dual"
  fi

  _assert_mariadb_sanity_ok "$MARIADB_AQSH_B_URL" "kind-cluster-dbs-b"
}
