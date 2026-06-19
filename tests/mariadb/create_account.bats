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
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  export CTX_A CTX_B NS AQSH_URL TEST_POD TOKEN
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

kexec() {
  kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"
}

http_post() {
  local url="$1" body="$2"
  local response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\\n%{http_code}' \
    -X POST '${url}' \
    -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Content-Type: application/json' \
    -d '${body}'")

  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-540}"
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE

    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && { echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2; return 1; }

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

_task_result_data() {
  echo "$TASK_RESPONSE" | jq -c '
    .result.data as $data |
    (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))
  '
}

_create_account_payload() {
  local dry_run="$1"
  local confirm="$2"
  jq -nc \
    --arg dry_run "$dry_run" \
    --arg confirm "$confirm" \
    '{
      namespace: "mariadb-1",
      resource: "mariadb",
      mdb: "mariadb",
      database: "app_db",
      username: "app_user",
      host: "%",
      privileges: "SELECT",
      password_secret_name: "mariadb-account-app-user-password",
      password_secret_key: "password",
      generate_password: "true",
      dry_run: $dry_run,
      confirm: $confirm
    }'
}

_primary_pod() {
  local primary
  primary=$(kubectl --context "$CTX_A" -n mariadb-1 get mariadb mariadb \
    -o jsonpath='{.status.currentPrimary}' 2>/dev/null || true)
  if [[ -z "$primary" ]]; then
    primary="mariadb-0"
  fi
  printf '%s' "$primary"
}

_root_password() {
  kubectl --context "$CTX_A" -n mariadb-1 get secret mariadb \
    -o jsonpath='{.data.password}' | base64 -d
}

_sql_as_root() {
  local query="$1"
  local primary password
  primary="$(_primary_pod)"
  password="$(_root_password)"
  kubectl --context "$CTX_A" -n mariadb-1 exec "$primary" -c mariadb -- \
    mariadb -u root -p"${password}" -N -B -e "$query"
}

_prepare_database() {
  _sql_as_root "DROP USER IF EXISTS 'app_user'@'%'; DROP DATABASE IF EXISTS app_db; CREATE DATABASE app_db; CREATE TABLE app_db.allowed_probe (id INT PRIMARY KEY); INSERT INTO app_db.allowed_probe VALUES (1);"
}

_submit_create_account() {
  local dry_run="$1"
  local confirm="$2"
  local payload task_id

  payload="$(_create_account_payload "$dry_run" "$confirm")"
  http_post "${AQSH_URL}/tasks/create-account" "$payload"
  assert_equal "$HTTP_CODE" "202"

  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]] || { echo "expected task id in response: $HTTP_BODY" >&2; return 1; }
  wait_for_task "$AQSH_URL" "$task_id"
}

_generated_password() {
  kubectl --context "$CTX_A" -n mariadb-1 get secret mariadb-account-app-user-password \
    -o jsonpath='{.data.password}' | base64 -d
}

_assert_user_can_select_but_not_create() {
  local primary password
  primary="$(_primary_pod)"
  password="$(_generated_password)"

  kubectl --context "$CTX_A" -n mariadb-1 exec "$primary" -c mariadb -- \
    mariadb --protocol=tcp -h 127.0.0.1 -u app_user -p"${password}" app_db \
    -N -B -e "SELECT COUNT(*) FROM allowed_probe" >/dev/null

  run kubectl --context "$CTX_A" -n mariadb-1 exec "$primary" -c mariadb -- \
    mariadb --protocol=tcp -h 127.0.0.1 -u app_user -p"${password}" app_db \
    -N -B -e "CREATE TABLE denied_probe (id INT)"
  [ "$status" -ne 0 ]
}

# --- Tests ---

@test "create-account dry-run does not create the user" {
  _prepare_database

  _submit_create_account "true" "false"

  local result result_status reason_code account_count
  result="$(_task_result_data)"
  result_status=$(echo "$result" | jq -r '.status')
  reason_code=$(echo "$result" | jq -r '.reason_code')
  account_count=$(_sql_as_root "SELECT COUNT(*) FROM mysql.user WHERE User='app_user' AND Host='%'")

  [ "$result_status" = "READY" ]
  [ "$reason_code" = "DRY_RUN_READY" ]
  [ "$account_count" = "0" ]
  [ "$(echo "$result" | jq -r '.password_secret.name')" = "mariadb-account-app-user-password" ]
}

@test "create-account creates an account, stores password in Secret, and enforces scoped grants" {
  _prepare_database

  _submit_create_account "false" "true"

  local result result_status reason_code secret_name
  result="$(_task_result_data)"
  result_status=$(echo "$result" | jq -r '.status')
  reason_code=$(echo "$result" | jq -r '.reason_code')
  secret_name=$(echo "$result" | jq -r '.password_secret.name')

  [ "$result_status" = "CREATED" ]
  [ "$reason_code" != "unknown" ]
  [ "$secret_name" = "mariadb-account-app-user-password" ]
  ! echo "$result" | grep -Fq "$(_generated_password)"

  _assert_user_can_select_but_not_create
}
