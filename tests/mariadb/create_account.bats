#!/usr/bin/env bats

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="db-ops"
  AQSH_URL="http://aqsh-mariadb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" get pod \
    -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || return 1
  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)
  export CTX_A CTX_B NS AQSH_URL TEST_POD TOKEN
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

kexec() { kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"; }

http_post() {
  local response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\n%{http_code}' \
    -X POST '$1' -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Content-Type: application/json' -d '$2'")
  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

wait_for_task() {
  local task_id="$1" elapsed=0 status
  while (( elapsed < 540 )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' '${AQSH_URL}/executions/${task_id}'")
    export TASK_RESPONSE
    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    [[ "$status" == completed ]] && return 0
    [[ "$status" != failed ]] || { echo "$TASK_RESPONSE" >&2; return 1; }
    sleep 5; elapsed=$((elapsed + 5))
  done
  return 1
}

task_result() {
  echo "$TASK_RESPONSE" | jq -c '
    .result.data as $data |
    (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))'
}

submit_create_account() {
  local payload="$1" task_id
  http_post "${AQSH_URL}/tasks/create-account" "$payload"
  assert_equal "$HTTP_CODE" 202
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$task_id"
}

primary_pod() {
  local primary
  primary=$(kubectl --context "$CTX_A" -n mariadb-1 get mariadb mariadb \
    -o jsonpath='{.status.currentPrimary}' 2>/dev/null || true)
  printf '%s' "${primary:-mariadb-0}"
}

root_password() {
  kubectl --context "$CTX_A" -n mariadb-1 get secret mariadb \
    -o jsonpath='{.data.password}' | base64 -d
}

sql_as_root() {
  kubectl --context "$CTX_A" -n mariadb-1 exec "$(primary_pod)" -c mariadb -- \
    mariadb -u root -p"$(root_password)" -N -B -e "$1"
}

sql_as_account() {
  local username="$1" password="$2" database="$3" query="$4"
  kubectl --context "$CTX_A" -n mariadb-1 exec "$(primary_pod)" -c mariadb -- \
    mariadb --protocol=tcp -h 127.0.0.1 -u "$username" -p"$password" "$database" \
    -N -B -e "$query"
}

prepare_database() {
  sql_as_root "DROP USER IF EXISTS 'app_user'@'%'; DROP USER IF EXISTS 'global_reader'@'%'; DROP USER IF EXISTS 'expiry_user'@'%'; DROP DATABASE IF EXISTS app_db; CREATE DATABASE app_db; CREATE TABLE app_db.allowed_probe (id INT PRIMARY KEY); INSERT INTO app_db.allowed_probe VALUES (1);"
}

@test "dry-run reports all-database read-only scope without creating a user" {
  prepare_database
  payload=$(jq -nc '{namespace:"mariadb-1",resource:"mariadb",mdb:"mariadb",username:"global_reader"}')
  # Keep one route invocation in the case body so review tooling can bind this
  # standalone E2E file directly to the public task capability.
  http_post "${AQSH_URL}/tasks/create-account" "$payload"
  assert_equal "$HTTP_CODE" 202
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$task_id"
  result=$(task_result)
  [ "$(echo "$result" | jq -r '.status')" = READY ]
  [ "$(echo "$result" | jq -r '.scope.kind')" = all_databases_read_only ]
  [ "$(echo "$result" | jq -r '.scope.grant')" = '*.*' ]
  [ "$(sql_as_root "SELECT COUNT(*) FROM mysql.user WHERE User='global_reader' AND Host='%'")" = 0 ]
}

@test "database-scoped account uses one-time delivery and enforced grants" {
  prepare_database
  payload=$(jq -nc '{namespace:"mariadb-1",resource:"mariadb",mdb:"mariadb",database:"app_db",username:"app_user",privileges:"SELECT",password_expire_mode:"never",dry_run:"false",confirm:"true"}')
  submit_create_account "$payload"
  result=$(task_result)
  [ "$(echo "$result" | jq -r '.status')" = CREATED ]
  [ "$(echo "$result" | jq -r '.delivery_payload.mode')" = one_time_plaintext ]
  password=$(echo "$result" | jq -r '.delivery_payload.password')
  sql_as_account app_user "$password" app_db 'SELECT COUNT(*) FROM allowed_probe' >/dev/null
  run sql_as_account app_user "$password" app_db 'CREATE TABLE denied_probe (id INT)'
  [ "$status" -ne 0 ]
  grants=$(sql_as_root "SHOW GRANTS FOR 'app_user'@'%'")
  [[ "$grants" == *'GRANT SELECT ON `app_db`.*'* ]]
}

@test "omitted database creates only an all-database read-only account" {
  prepare_database
  payload=$(jq -nc '{namespace:"mariadb-1",resource:"mariadb",mdb:"mariadb",username:"global_reader",password_expire_mode:"never",dry_run:"false",confirm:"true"}')
  submit_create_account "$payload"
  result=$(task_result)
  password=$(echo "$result" | jq -r '.delivery_payload.password')
  [ "$(echo "$result" | jq -r '.status')" = CREATED ]
  sql_as_account global_reader "$password" app_db 'SELECT COUNT(*) FROM allowed_probe' >/dev/null
  sql_as_account global_reader "$password" information_schema 'SELECT COUNT(*) FROM tables' >/dev/null
  run sql_as_account global_reader "$password" app_db 'INSERT INTO allowed_probe VALUES (2)'
  [ "$status" -ne 0 ]
  grants=$(sql_as_root "SHOW GRANTS FOR 'global_reader'@'%'")
  [[ "$grants" == *'GRANT SELECT ON *.*'* ]]
  [[ "$grants" != *'INSERT'* ]]
}

@test "allow_existing rotates credentials and removes prior broader grants" {
  prepare_database
  sql_as_root "CREATE USER 'global_reader'@'%' IDENTIFIED BY 'OldPass123!'; GRANT ALL PRIVILEGES ON app_db.* TO 'global_reader'@'%';"
  payload=$(jq -nc '{namespace:"mariadb-1",resource:"mariadb",mdb:"mariadb",username:"global_reader",allow_existing:"true",password_expire_mode:"never",dry_run:"false",confirm:"true"}')
  submit_create_account "$payload"
  result=$(task_result)
  [ "$(echo "$result" | jq -r '.status')" = RECREATED ]
  [ "$(echo "$result" | jq -r '.reason_code')" = ACCOUNT_RECREATED ]
  grants=$(sql_as_root "SHOW GRANTS FOR 'global_reader'@'%'")
  [[ "$grants" == *'GRANT SELECT ON *.*'* ]]
  [[ "$grants" != *'ALL PRIVILEGES ON `app_db`.*'* ]]
}

@test "first-login and interval expiry are stored natively by MariaDB" {
  prepare_database
  payload=$(jq -nc '{namespace:"mariadb-1",resource:"mariadb",mdb:"mariadb",database:"app_db",username:"expiry_user",password_expire_mode:"first_login",dry_run:"false",confirm:"true"}')
  submit_create_account "$payload"
  [ "$(task_result | jq -r '.status')" = CREATED ]
  create_sql=$(sql_as_root "SHOW CREATE USER 'expiry_user'@'%'")
  [[ "$create_sql" == *'PASSWORD EXPIRE'* ]]

  payload=$(jq -nc '{namespace:"mariadb-1",resource:"mariadb",mdb:"mariadb",database:"app_db",username:"expiry_user",allow_existing:"true",password_expire_mode:"interval",validity_days:"7",dry_run:"false",confirm:"true"}')
  submit_create_account "$payload"
  [ "$(task_result | jq -r '.status')" = RECREATED ]
  create_sql=$(sql_as_root "SHOW CREATE USER 'expiry_user'@'%'")
  [[ "$create_sql" == *'PASSWORD EXPIRE INTERVAL 7 DAY'* ]]
}
