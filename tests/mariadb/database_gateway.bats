#!/usr/bin/env bats

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX="kind-cluster-a"
  DB_NS="mariadb-1"
  MDB="mariadb"
  GATEWAY="database-gateway"
  CLIENT="database-gateway-client"
  TEST_USER="gateway_test"
  TEST_PASSWORD="gateway-test-pass"
  TEST_DATABASE="gateway_e2e"

  kubectl --context "$CTX" -n "$DB_NS" wait pod \
    -l app="$CLIENT" --for=condition=Ready --timeout=120s

  PRIMARY_POD=$(kubectl --context "$CTX" -n "$DB_NS" get mariadb "$MDB" \
    -o jsonpath='{.status.currentPrimary}')
  [[ -n "$PRIMARY_POD" ]] || { echo "MariaDB current primary is empty" >&2; return 1; }

  ROOT_PASSWORD=$(kubectl --context "$CTX" -n "$DB_NS" get secret mariadb \
    -o jsonpath='{.data.password}' | base64 -d)

  export CTX DB_NS MDB GATEWAY CLIENT TEST_USER TEST_PASSWORD TEST_DATABASE
  export PRIMARY_POD ROOT_PASSWORD

  root_sql "DROP DATABASE IF EXISTS ${TEST_DATABASE};
    CREATE DATABASE ${TEST_DATABASE};
    DROP USER IF EXISTS '${TEST_USER}'@'%';
    CREATE USER '${TEST_USER}'@'%' IDENTIFIED BY '${TEST_PASSWORD}';
    GRANT ALL PRIVILEGES ON ${TEST_DATABASE}.* TO '${TEST_USER}'@'%';
    CREATE TABLE ${TEST_DATABASE}.replica_marker (id INT PRIMARY KEY, value VARCHAR(32));
    INSERT INTO ${TEST_DATABASE}.replica_marker VALUES (1, 'replicated');"

  wait_for_gateway_connection 3306 60
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

teardown_file() {
  PRIMARY_POD=$(kubectl --context "$CTX" -n "$DB_NS" get mariadb "$MDB" \
    -o jsonpath='{.status.currentPrimary}' 2>/dev/null || true)
  if [[ -n "$PRIMARY_POD" && -n "${ROOT_PASSWORD:-}" ]]; then
    root_sql "DROP DATABASE IF EXISTS ${TEST_DATABASE}; DROP USER IF EXISTS '${TEST_USER}'@'%';" \
      >/dev/null 2>&1 || true
  fi
}

root_sql() {
  local query="$1"
  kubectl --context "$CTX" -n "$DB_NS" exec "$PRIMARY_POD" -c mariadb -- \
    env MYSQL_PWD="$ROOT_PASSWORD" mariadb -u root -N -B -e "$query"
}

gateway_sql() {
  local port="$1" query="$2"
  kubectl --context "$CTX" -n "$DB_NS" exec "deployment/${CLIENT}" -c mariadb-client -- \
    env MYSQL_PWD="$TEST_PASSWORD" mariadb --protocol=TCP --connect-timeout=5 \
      -h "$GATEWAY" -P "$port" -u "$TEST_USER" -N -B -e "$query"
}

wait_for_gateway_connection() {
  local port="$1" timeout="${2:-60}" elapsed=0
  while (( elapsed < timeout )); do
    gateway_sql "$port" "SELECT 1;" >/dev/null 2>&1 && return 0
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo "database gateway port ${port} did not become ready within ${timeout}s" >&2
  return 1
}

wait_for_replica_value() {
  local expected="$1" query="$2" timeout="${3:-120}" elapsed=0 value
  while (( elapsed < timeout )); do
    value=$(gateway_sql 3307 "$query" 2>/dev/null || true)
    [[ "$value" == "$expected" ]] && return 0
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo "read-only route did not return '${expected}' within ${timeout}s (last value: ${value})" >&2
  return 1
}

@test "database gateway resources are namespace-local and select the gateway workload" {
  run kubectl --context "$CTX" -n "$DB_NS" get deployment "$GATEWAY" \
    -o jsonpath='{.spec.template.metadata.labels.app}'
  assert_success
  assert_output "$GATEWAY"

  run kubectl --context "$CTX" -n "$DB_NS" get gateways.networking.istio.io "$GATEWAY" \
    -o json
  assert_success
  assert_equal "$(echo "$output" | jq -c '.spec.selector')" \
    "{\"app\":\"$GATEWAY\"}"

  run kubectl --context "$CTX" -n "$DB_NS" get service "$GATEWAY" -o json
  assert_success
  assert_equal "$(echo "$output" | jq -r '.spec.type')" "ClusterIP"
  assert_equal "$(echo "$output" | jq -c '[.spec.ports[] | {name,port}] | sort_by(.port)')" \
    '[{"name":"tcp-mariadb-rw","port":3306},{"name":"tcp-mariadb-ro","port":3307},{"name":"status-port","port":15021}]'
}

@test "database gateway routes target the operator-native primary and secondary Services" {
  run kubectl --context "$CTX" -n "$DB_NS" get virtualservices.networking.istio.io "$GATEWAY" -o json
  assert_success

  assert_equal "$(echo "$output" | jq -r '.spec.gateways[0]')" \
    "$DB_NS/$GATEWAY"
  assert_equal "$(echo "$output" | jq -r '.spec.tcp[] | select(.match[0].port == 3306) | .route[0].destination.host')" \
    "mariadb-primary"
  assert_equal "$(echo "$output" | jq -r '.spec.tcp[] | select(.match[0].port == 3307) | .route[0].destination.host')" \
    "mariadb-secondary"

  run kubectl --context "$CTX" -n "$DB_NS" get service mariadb-primary mariadb-secondary
  assert_success
}

@test "read-write gateway port writes through the operator primary Service" {
  run gateway_sql 3306 "CREATE TABLE ${TEST_DATABASE}.rw_marker (id INT PRIMARY KEY); INSERT INTO ${TEST_DATABASE}.rw_marker VALUES (1); SELECT COUNT(*) FROM ${TEST_DATABASE}.rw_marker;"
  assert_success
  assert_output "1"

  run root_sql "SELECT COUNT(*) FROM ${TEST_DATABASE}.rw_marker;"
  assert_success
  assert_output "1"
}

@test "read-only gateway port reads replicas and rejects writes" {
  run wait_for_replica_value "replicated" \
    "SELECT value FROM ${TEST_DATABASE}.replica_marker WHERE id = 1;" 120
  assert_success

  run gateway_sql 3307 "INSERT INTO ${TEST_DATABASE}.replica_marker VALUES (2, 'must-fail');"
  assert_failure

  run root_sql "SELECT COUNT(*) FROM ${TEST_DATABASE}.replica_marker WHERE id = 2;"
  assert_success
  assert_output "0"
}
