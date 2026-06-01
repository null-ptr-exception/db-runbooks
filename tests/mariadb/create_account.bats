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

_create_account_payload() {
  local dry_run="$1"
  local confirm="$2"
  jq -nc \
    --arg dry_run "$dry_run" \
    --arg confirm "$confirm" \
    '{
      namespace: "mariadb-2",
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

_task_result_data() {
  echo "$TASK_RESPONSE" | jq -c '
    .result.data as $data |
    (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))
  '
}

_primary_pod() {
  local ctx="${1:-${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}}"
  local primary

  if [[ "${USE_MARIADB_OPERATOR:-true}" == "true" ]]; then
    primary=$(kubectl --context "$ctx" -n mariadb-2 get mariadb mariadb -o jsonpath='{.status.currentPrimary}' 2>/dev/null || true)
  fi
  if [[ -z "$primary" ]]; then
    primary="mariadb-0"
  fi
  printf '%s' "$primary"
}

_root_password() {
  local ctx="${1:-${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}}"
  kubectl --context "$ctx" -n mariadb-2 get secret mariadb -o jsonpath='{.data.password}' | base64 -d
}

_sql_as_root() {
  local ctx="${1:-${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}}"
  local query="$2"
  local primary password

  primary="$(_primary_pod "$ctx")"
  password="$(_root_password "$ctx")"
  kubectl --context "$ctx" -n mariadb-2 exec "$primary" -c mariadb -- \
    mariadb -u root -p"${password}" -N -B -e "$query"
}

_prepare_database() {
  local ctx="${1:-${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}}"
  _sql_as_root "$ctx" "DROP USER IF EXISTS 'app_user'@'%'; DROP DATABASE IF EXISTS app_db; CREATE DATABASE app_db; CREATE TABLE app_db.allowed_probe (id INT PRIMARY KEY); INSERT INTO app_db.allowed_probe VALUES (1);"
}

_submit_create_account() {
  local aqsh_url="$1"
  local dry_run="$2"
  local confirm="$3"
  local payload task_id

  payload="$(_create_account_payload "$dry_run" "$confirm")"
  http_post "${aqsh_url}/tasks/create-account" "$payload"
  assert_equal "$HTTP_CODE" "202"

  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  if [[ -z "$task_id" ]]; then
    echo "expected task id in response: $HTTP_BODY" >&2
    return 1
  fi
  wait_for_task "$aqsh_url" "$task_id"
}

_generated_password() {
  local ctx="${1:-${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}}"
  kubectl --context "$ctx" -n mariadb-2 get secret mariadb-account-app-user-password -o jsonpath='{.data.password}' | base64 -d
}

_assert_user_can_select_but_not_create() {
  local ctx="${1:-${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}}"
  local primary password

  primary="$(_primary_pod "$ctx")"
  password="$(_generated_password "$ctx")"

  kubectl --context "$ctx" -n mariadb-2 exec "$primary" -c mariadb -- \
    mariadb --protocol=tcp -h 127.0.0.1 -u app_user -p"${password}" app_db \
    -N -B -e "SELECT COUNT(*) FROM allowed_probe" >/dev/null

  run kubectl --context "$ctx" -n mariadb-2 exec "$primary" -c mariadb -- \
    mariadb --protocol=tcp -h 127.0.0.1 -u app_user -p"${password}" app_db \
    -N -B -e "CREATE TABLE denied_probe (id INT)"
  [ "$status" -ne 0 ]
}

@test "create-account dry-run does not create the user" {
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
  _prepare_database "$ctx"

  _submit_create_account "$MARIADB_AQSH_URL" "true" "false"

  local result result_status reason_code account_count
  result="$(_task_result_data)"
  result_status=$(echo "$result" | jq -r '.status')
  reason_code=$(echo "$result" | jq -r '.reason_code')
  account_count=$(_sql_as_root "$ctx" "SELECT COUNT(*) FROM mysql.user WHERE User='app_user' AND Host='%'")

  [ "$result_status" = "READY" ]
  [ "$reason_code" = "DRY_RUN_READY" ]
  [ "$account_count" = "0" ]
  [ "$(echo "$result" | jq -r '.password_secret.name')" = "mariadb-account-app-user-password" ]
}

@test "create-account creates an account, stores password in Secret, and enforces scoped grants" {
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
  _prepare_database "$ctx"

  _submit_create_account "$MARIADB_AQSH_URL" "false" "true"

  local result result_status reason_code secret_name
  result="$(_task_result_data)"
  result_status=$(echo "$result" | jq -r '.status')
  reason_code=$(echo "$result" | jq -r '.reason_code')
  secret_name=$(echo "$result" | jq -r '.password_secret.name')

  [ "$result_status" = "CREATED" ]
  [ "$reason_code" != "unknown" ]
  [ "$secret_name" = "mariadb-account-app-user-password" ]
  ! echo "$result" | grep -Fq "$(_generated_password "$ctx")"

  _assert_user_can_select_but_not_create "$ctx"
}

@test "dual mode create-account completes on cluster-b" {
  if [[ "${DB_MODE:-single}" != "dual" ]]; then
    skip "DB_MODE is not dual"
  fi

  local ctx="kind-cluster-dbs-b"
  _prepare_database "$ctx"

  _submit_create_account "$MARIADB_AQSH_B_URL" "false" "true"

  local result result_status
  result="$(_task_result_data)"
  result_status=$(echo "$result" | jq -r '.status')

  [ "$result_status" = "CREATED" ]

  _assert_user_can_select_but_not_create "$ctx"
}
