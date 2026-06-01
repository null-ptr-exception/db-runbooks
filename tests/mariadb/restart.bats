setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  deploy_mariadb "mariadb-1"
}

setup() {
  load '../test_helper/common_setup'
}

teardown_file() {
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" delete ns mariadb-1 --ignore-not-found
}

# Extract the structured task result object from TASK_RESPONSE. The AQSH result
# payload may arrive as a JSON string (.result.data) or an already-parsed object.
_result_json() {
  echo "$TASK_RESPONSE" | jq -c '
    (.result.data as $data
      | (($data | try fromjson catch null)
         // (if ($data | type) == "object" then $data else .result end)))'
}

_sts_generation() {
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mariadb-1 \
    get statefulset mariadb -o jsonpath='{.status.observedGeneration}'
}

# Number of running MariaDB pods. The two test modes deploy different
# topologies: operator mode (USE_MARIADB_OPERATOR=true) is a single-node CR
# (1 pod), while native mode is a 3-replica StatefulSet. These tests assert
# behaviour relative to the actual pod count rather than hard-coding either.
_mariadb_pod_count() {
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mariadb-1 \
    get pods -l app.kubernetes.io/name=mariadb \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}' | wc -w | tr -d '[:space:]'
}

_submit_restart() {
  local payload="$1"
  http_post "${MARIADB_AQSH_URL}/tasks/restart" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"
}

@test "dry-run reports operator-controlled restart plan and changes nothing" {
  local before_generation pod_count
  before_generation=$(_sts_generation)
  pod_count=$(_mariadb_pod_count)

  # dry_run defaults to true; restart order is delegated to mariadb-operator.
  _submit_restart '{"namespace": "mariadb-1"}'

  local result result_status reason_code changed operator_controlled order_len primary_before
  result=$(_result_json)
  result_status=$(echo "$result" | jq -r '.status')
  reason_code=$(echo "$result" | jq -r '.reason_code')
  changed=$(echo "$result" | jq -r '.changed')
  operator_controlled=$(echo "$result" | jq -r '.operator_controlled')
  order_len=$(echo "$result" | jq -r '.restart_order | length')
  primary_before=$(echo "$result" | jq -r '.primary_before')

  echo "plan: status=${result_status} reason=${reason_code} order_len=${order_len} primary=${primary_before} pod_count=${pod_count}"
  if [[ "${USE_MARIADB_OPERATOR:-true}" != "true" ]]; then
    assert_equal "$result_status" "BLOCKED"
    assert_equal "$reason_code" "MARIADB_OPERATOR_REQUIRED"
  else
    assert_equal "$result_status" "READY"
    assert_equal "$reason_code" "RESTART_DRY_RUN"
    assert_equal "$changed" "false"
    assert_equal "$operator_controlled" "true"
    assert_equal "$order_len" "0"
  fi

  # Dry-run must not touch the StatefulSet.
  assert_equal "$(_sts_generation)" "$before_generation"
}

@test "confirmed restart patches the MariaDB CR and lets the operator control rollout" {
  local pod_count
  pod_count=$(_mariadb_pod_count)

  _submit_restart '{"namespace": "mariadb-1", "dry_run": "false", "confirm": "true"}'

  local result result_status reason_code primary_before primary_after changed
  result=$(_result_json)
  result_status=$(echo "$result" | jq -r '.status')
  reason_code=$(echo "$result" | jq -r '.reason_code')
  primary_before=$(echo "$result" | jq -r '.primary_before')
  primary_after=$(echo "$result" | jq -r '.primary_after')
  changed=$(echo "$result" | jq -r '.changed')

  echo "operator-restart: pods=${pod_count} status=${result_status} reason=${reason_code} primary=${primary_before}->${primary_after}"

  if [[ "${USE_MARIADB_OPERATOR:-true}" != "true" ]]; then
    assert_equal "$result_status" "BLOCKED"
    assert_equal "$reason_code" "MARIADB_OPERATOR_REQUIRED"
  else
    assert_equal "$result_status" "RESTARTED"
    assert_equal "$reason_code" "RESTART_COMPLETED"
    assert_equal "$changed" "true"

    local restarted not_ready
    restarted=$(echo "$result" | jq -rc '[.pods[] | select(.restarted == true) | .name] | sort')
    not_ready=$(echo "$result" | jq -r '[.pods[] | select(.restarted == true) | select(.ready_after != true)] | length')
    assert_equal "$restarted" "$(echo "$result" | jq -rc '[.pods[].name] | sort')"
    assert_equal "$not_ready" "0"

    local ready replicas
    ready=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mariadb-1 \
      get statefulset mariadb -o jsonpath='{.status.readyReplicas}')
    replicas=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mariadb-1 \
      get statefulset mariadb -o jsonpath='{.status.replicas}')
    assert_equal "$ready" "$replicas"
  fi
}

@test "target_pod is refused because operator-driven restart is resource-scoped" {
  _submit_restart '{"namespace": "mariadb-1", "target_pod": "mariadb-0"}'

  local result result_status reason_code
  result=$(_result_json)
  result_status=$(echo "$result" | jq -r '.status')
  reason_code=$(echo "$result" | jq -r '.reason_code')

  echo "target-pod: status=${result_status} reason=${reason_code}"
  assert_equal "$result_status" "BLOCKED"
  assert_equal "$reason_code" "TARGET_POD_UNSUPPORTED"
}
