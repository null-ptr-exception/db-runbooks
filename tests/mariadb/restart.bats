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

@test "dry-run with include_primary plans every pod with the primary last and changes nothing" {
  local before_generation pod_count
  before_generation=$(_sts_generation)
  pod_count=$(_mariadb_pod_count)

  # dry_run defaults to true; include_primary brings the whole cluster in scope.
  _submit_restart '{"namespace": "mariadb-1", "include_primary": "true"}'

  local result result_status reason_code changed order_len order_last primary_before
  result=$(_result_json)
  result_status=$(echo "$result" | jq -r '.status')
  reason_code=$(echo "$result" | jq -r '.reason_code')
  changed=$(echo "$result" | jq -r '.changed')
  order_len=$(echo "$result" | jq -r '.restart_order | length')
  order_last=$(echo "$result" | jq -r '.restart_order[-1]')
  primary_before=$(echo "$result" | jq -r '.primary_before')

  echo "plan: status=${result_status} reason=${reason_code} order_len=${order_len} primary=${primary_before} pod_count=${pod_count}"
  assert_equal "$result_status" "READY"
  assert_equal "$reason_code" "RESTART_DRY_RUN"
  assert_equal "$changed" "false"
  # Every pod is planned, and the primary is scheduled last (replicas first).
  assert_equal "$order_len" "$pod_count"
  assert_equal "$order_last" "$primary_before"

  # Dry-run must not touch the StatefulSet.
  assert_equal "$(_sts_generation)" "$before_generation"
}

@test "confirmed replica-only restart cycles replicas and preserves the primary (no-ops on a single node)" {
  local pod_count
  pod_count=$(_mariadb_pod_count)

  # Default include_primary=false → replicas only, primary protected.
  _submit_restart '{"namespace": "mariadb-1", "dry_run": "false", "confirm": "true"}'

  # Let pods settle after the restart.
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mariadb-1 wait pod \
    -l app.kubernetes.io/name=mariadb \
    --for=condition=Ready --timeout=240s >/dev/null 2>&1

  local result result_status reason_code primary_before primary_after
  result=$(_result_json)
  result_status=$(echo "$result" | jq -r '.status')
  reason_code=$(echo "$result" | jq -r '.reason_code')
  primary_before=$(echo "$result" | jq -r '.primary_before')
  primary_after=$(echo "$result" | jq -r '.primary_after')

  echo "replica-restart: pods=${pod_count} status=${result_status} reason=${reason_code} primary=${primary_before}->${primary_after}"

  if [ "$pod_count" -le 1 ]; then
    # Single-node cluster: the only pod is the primary, excluded by default.
    assert_equal "$result_status" "BLOCKED"
    assert_equal "$reason_code" "NO_RESTART_TARGETS"
  else
    assert_equal "$result_status" "RESTARTED"
    assert_equal "$reason_code" "RESTART_COMPLETED"
    # Primary must not move when only replicas are restarted.
    assert_equal "$primary_after" "$primary_before"

    # Exactly the non-primary pods were restarted, and all came back Ready.
    local restarted expected not_ready
    restarted=$(echo "$result" | jq -rc '[.pods[] | select(.restarted == true) | .name] | sort')
    expected=$(echo "$result" | jq -rc --arg p "$primary_before" '[.pods[].name | select(. != $p)] | sort')
    not_ready=$(echo "$result" | jq -r '[.pods[] | select(.restarted == true) | select(.ready_after != true)] | length')
    assert_equal "$restarted" "$expected"
    assert_equal "$not_ready" "0"

    local ready replicas
    ready=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mariadb-1 \
      get statefulset mariadb -o jsonpath='{.status.readyReplicas}')
    replicas=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mariadb-1 \
      get statefulset mariadb -o jsonpath='{.status.replicas}')
    assert_equal "$ready" "$replicas"
  fi
}

@test "the current primary is protected from an accidental restart" {
  # Discover the primary via a dry-run plan (works in operator and native modes).
  _submit_restart '{"namespace": "mariadb-1", "include_primary": "true"}'
  local primary
  primary=$(_result_json | jq -r '.primary_before')
  [ -n "$primary" ] && [ "$primary" != "null" ]

  # Targeting the primary without include_primary must be refused, not silently run.
  _submit_restart "$(jq -nc --arg p "$primary" '{namespace: "mariadb-1", target_pod: $p}')"

  local result result_status reason_code
  result=$(_result_json)
  result_status=$(echo "$result" | jq -r '.status')
  reason_code=$(echo "$result" | jq -r '.reason_code')

  echo "protect: primary=${primary} status=${result_status} reason=${reason_code}"
  assert_equal "$result_status" "BLOCKED"
  assert_equal "$reason_code" "PRIMARY_RESTART_NOT_ALLOWED"
}
