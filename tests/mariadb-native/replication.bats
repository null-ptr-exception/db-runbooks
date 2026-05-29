setup_file() {
  load 'test_helper'
  mariadb_suite_setup --create-token

  MARIADB_POD_A=$(kubectl --context "$CTX_A" -n mariadb-1 \
    get pod -l app=mariadb -o jsonpath='{.items[0].metadata.name}')
  MARIADB_POD_B=$(kubectl --context "$CTX_B" -n mariadb-2 \
    get pod -l app=mariadb -o jsonpath='{.items[0].metadata.name}')
  export MARIADB_POD_A MARIADB_POD_B
}

setup() {
  load 'test_helper'
}

@test "aqsh-mariadb on cluster-a is reachable" {
  http_post "${MARIADB_AQSH_URL}/tasks/common%2Fhello" '{"name": "replication-test-a"}'
  assert_equal "$HTTP_CODE" "202"
}

@test "cross-cluster TCP: mariadb-1 on cluster-a connects to mariadb-2 on cluster-b via Istio Gateway" {
  # Use mariadb-2's password to authenticate against the remote instance
  run kubectl --context "$CTX_A" -n mariadb-1 exec "$MARIADB_POD_A" -- \
    sh -c "mariadb -u root -p'mariadb2-root-pass' -h 'mariadb.kind-b.test' -P '30091' --connect-timeout=5 -e 'SELECT 1' 2>/dev/null"
  assert_success
}

@test "cross-cluster TCP: mariadb-2 on cluster-b connects to mariadb-1 on cluster-a via Istio Gateway" {
  # Use mariadb-1's password to authenticate against the remote instance
  run kubectl --context "$CTX_B" -n mariadb-2 exec "$MARIADB_POD_B" -- \
    sh -c "mariadb -u root -p'mariadb1-root-pass' -h 'mariadb.kind-a.test' -P '30091' --connect-timeout=5 -e 'SELECT 1' 2>/dev/null"
  assert_success
}

@test "restart task completes on cluster-a (mariadb-1)" {
  http_post "${MARIADB_AQSH_URL}/tasks/restart" '{"namespace": "mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"
}
