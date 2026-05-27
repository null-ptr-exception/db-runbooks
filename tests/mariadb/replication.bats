REQUIRED_MARIADB_TOPOLOGY="2+1"

setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  skip_unless_mariadb_topology "$REQUIRED_MARIADB_TOPOLOGY"
  assert_mariadb_ready "mariadb-1" "kind-cluster-dbs-a"
  assert_mariadb_ready "mariadb-1" "kind-cluster-dbs-b"
}

setup() {
  load '../test_helper/common_setup'
}

peer_proxy_mariadb_ping() {
  local source_ctx="$1"
  local target_ctx="$2"
  local password

  password=$(
    kubectl --context "$target_ctx" -n mariadb-1 get secret mariadb \
      -o jsonpath='{.data.password}' | base64 -d
  )

  kubectl --context "$source_ctx" -n db-ops exec deploy/aqsh-mariadb -c aqsh -- \
    sh -ceu 'MARIADB_PWD="$1" mariadb-admin --protocol=tcp ping -h peer-db-proxy -P 3306 -u root --connect-timeout=5 --silent' \
    sh "$password"
}

@test "mariadb aqsh on cluster-a is reachable" {
  http_post "${MARIADB_AQSH_A_URL}/tasks/common%2Fhello" '{"name": "replication-test-a"}'
  assert_equal "$HTTP_CODE" "202"
}

@test "mariadb aqsh on cluster-b is reachable" {
  http_post "${MARIADB_AQSH_B_URL}/tasks/common%2Fhello" '{"name": "replication-test-b"}'
  assert_equal "$HTTP_CODE" "202"
}

@test "peer-db-proxy on cluster-a reaches mariadb on cluster-b" {
  run peer_proxy_mariadb_ping "kind-cluster-dbs-a" "kind-cluster-dbs-b"
  assert_success
}

@test "peer-db-proxy on cluster-b reaches mariadb on cluster-a" {
  run peer_proxy_mariadb_ping "kind-cluster-dbs-b" "kind-cluster-dbs-a"
  assert_success
}

@test "restart task completes on cluster-a" {
  http_post "${MARIADB_AQSH_A_URL}/tasks/restart" '{"namespace": "mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MARIADB_AQSH_A_URL" "$task_id"
}

@test "restart task completes on cluster-b" {
  http_post "${MARIADB_AQSH_B_URL}/tasks/restart" '{"namespace": "mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MARIADB_AQSH_B_URL" "$task_id"
}
