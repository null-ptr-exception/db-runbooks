#!/usr/bin/env bats
# Standalone sandbox/API coverage. Never run against a company environment.
setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  export CTX_A=kind-cluster-a CTX_B=kind-cluster-b NS=db-ops DB_NS=mariadb-1
  export AQSH_URL=http://aqsh-mariadb.kind-a.test:30080
  kubectl --context "$CTX_B" -n "$NS" wait pod -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD="$(kubectl --context "$CTX_B" -n "$NS" get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')"
  DB_POD="$(kubectl --context "$CTX_A" -n "$DB_NS" get mariadb -o jsonpath='{.items[0].status.currentPrimary}')"
  [[ -n "$TEST_POD" && -n "$DB_POD" ]]
  TOKEN="$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)"
  ROOT_PASSWORD="$(kubectl --context "$CTX_A" -n "$DB_NS" exec "$DB_POD" -c mariadb -- printenv MARIADB_ROOT_PASSWORD)"
  export TEST_POD DB_POD TOKEN ROOT_PASSWORD
}
setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  TEST_USER="session_test_${BATS_TEST_NUMBER}"
  TEST_DB="session_test_${BATS_TEST_NUMBER}"
  export TEST_USER TEST_DB
  WORKERS=()
  db_sql "CREATE DATABASE $TEST_DB;
    CREATE TABLE $TEST_DB.lock_probe (id INT PRIMARY KEY, n INT) ENGINE=InnoDB;
    INSERT INTO $TEST_DB.lock_probe VALUES (1,0);
    CREATE USER '$TEST_USER'@'localhost' IDENTIFIED BY 'sandbox-session-test';
    GRANT SELECT,UPDATE ON $TEST_DB.* TO '$TEST_USER'@'localhost';"
}
teardown() {
  local ids id pid
  ids="$(db_sql "SELECT ID FROM information_schema.PROCESSLIST WHERE USER='$TEST_USER';")" || return 1
  for id in $ids; do db_sql "KILL CONNECTION $id;"; done
  for pid in "${WORKERS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then kill "$pid"; fi
    wait "$pid" 2>/dev/null || : # interrupted fixture clients are expected
  done
  db_sql "DROP USER '$TEST_USER'@'localhost'; DROP DATABASE $TEST_DB;"
}
db_sql() {
  kubectl --context "$CTX_A" -n "$DB_NS" exec "$DB_POD" -c mariadb -- \
    mariadb -u root -p"$ROOT_PASSWORD" --raw -N -B -e "$1"
}
spawn_client() {
  local query="$1" index="${#WORKERS[@]}"
  # Keep stdin open after SQL completes. --force leaves the client connected
  # after KILL QUERY, so transaction/lock persistence is really exercised.
  kubectl --context "$CTX_A" -n "$DB_NS" exec "$DB_POD" -c mariadb -- \
    sh -c '{ printf "%s\n" "$2"; sleep 90; } | MYSQL_PWD=sandbox-session-test mariadb -u "$1" --force --raw -N -B' \
    sh "$TEST_USER" "$query" >"${BATS_TEST_TMPDIR}/worker-$index.out" 2>"${BATS_TEST_TMPDIR}/worker-$index.err" &
  WORKERS+=("$!")
}
wait_value() {
  local query="$1" expected="$2" i value
  for ((i=0; i<20; i++)); do
    value="$(db_sql "$query")" || return 1
    [[ "$value" == "$expected" ]] && return 0
    sleep 1
  done
  echo "Condition did not reach expected value: $expected (last: $value)" >&2
  return 1
}
start_blocker() {
  spawn_client "START TRANSACTION; UPDATE $TEST_DB.lock_probe SET n=n+1 WHERE id=1;"
  wait_value "SELECT COUNT(*) FROM information_schema.INNODB_TRX t JOIN information_schema.PROCESSLIST p
    ON p.ID=t.TRX_MYSQL_THREAD_ID WHERE p.USER='$TEST_USER' AND p.COMMAND='Sleep';" 1
  BLOCKER="$(db_sql "SELECT p.ID FROM information_schema.INNODB_TRX t JOIN information_schema.PROCESSLIST p
    ON p.ID=t.TRX_MYSQL_THREAD_ID WHERE p.USER='$TEST_USER';")"
}
start_waiter() {
  spawn_client "UPDATE $TEST_DB.lock_probe SET n=n+10 WHERE id=1;"
  wait_value "SELECT COUNT(*) FROM information_schema.INNODB_LOCK_WAITS w JOIN information_schema.INNODB_TRX b
    ON b.TRX_ID=w.BLOCKING_TRX_ID WHERE b.TRX_MYSQL_THREAD_ID=$BLOCKER;" 1
}
submit_sessions() {
  local body="$1" response id state i
  response="$(kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- curl -fsS \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$body" \
    "$AQSH_URL/tasks/sessions")" || return 1
  id="$(jq -er .id <<< "$response")" || return 1
  for ((i=0; i<60; i++)); do
    response="$(kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- curl -fsS \
      -H "Authorization: Bearer $TOKEN" "$AQSH_URL/executions/$id")" || return 1
    state="$(jq -r .status <<< "$response")"
    if [[ "$state" == completed || "$state" == failed ]]; then
      TASK_RESULT="$(jq -ec '.result.data | if type=="string" then fromjson else . end' <<< "$response")"
      return
    fi
    sleep 2
  done
  echo 'sessions API execution timed out' >&2; return 1
}
payload() {
  jq -nc --arg ns "$DB_NS" --arg pod "$DB_POD" --arg action "$1" --arg id "${2:-}" \
    '{namespace:$ns,target_pod:$pod,action:$action,connection_id:$id}'
}

@test "sessions API diagnoses a real idle blocker and its waiting transaction" {
  start_blocker
  start_waiter
  submit_sessions "$(payload diagnose)"
  assert_equal "$(jq -r .reason_code <<< "$TASK_RESULT")" SESSION_DIAGNOSTICS_READY
  jq -e --arg blocker "$BLOCKER" '
    .sections.transactions.rows | any(.connection_id==$blocker and .command=="Sleep")' <<< "$TASK_RESULT"
  jq -e --arg blocker "$BLOCKER" '
    .sections.lock_waits.rows | any(.blocking_connection_id==$blocker)' <<< "$TASK_RESULT"
  jq -e '.sections.processlist.rows | any((.sql // "") | contains("lock_probe"))' <<< "$TASK_RESULT"
  assert_equal "$(jq -r .changed <<< "$TASK_RESULT")" false
}

@test "sessions API KILL QUERY stops a real statement but leaves its transaction active" {
  spawn_client "START TRANSACTION; UPDATE $TEST_DB.lock_probe SET n=n+1 WHERE id=1; SELECT SLEEP(90);"
  wait_value "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='$TEST_USER' AND INFO='SELECT SLEEP(90)';" 1
  local id preview request
  id="$(db_sql "SELECT ID FROM information_schema.PROCESSLIST WHERE USER='$TEST_USER' AND INFO='SELECT SLEEP(90)';")"
  submit_sessions "$(payload kill-query "$id")"
  assert_equal "$(jq -r .reason_code <<< "$TASK_RESULT")" SESSION_DRY_RUN_READY
  preview="$(jq -r .before.fingerprint <<< "$TASK_RESULT")"
  request="$(payload kill-query "$id" | jq -c --arg token "$preview" \
    '.+{dry_run:"false",confirm:"true",expected_session:$token}')"
  submit_sessions "$request"
  assert_equal "$(jq -r .reason_code <<< "$TASK_RESULT")" SESSION_TERMINATION_VERIFIED
  assert_equal "$(jq -r .verification.original_transaction_present <<< "$TASK_RESULT")" 1
  assert_equal "$(db_sql "SELECT COUNT(*) FROM information_schema.INNODB_TRX WHERE TRX_MYSQL_THREAD_ID=$id;")" 1
}

@test "sessions API KILL CONNECTION rolls back a real blocker and releases its waiter" {
  start_blocker
  start_waiter
  local preview request
  submit_sessions "$(payload kill-connection "$BLOCKER")"
  preview="$(jq -r .before.fingerprint <<< "$TASK_RESULT")"
  request="$(payload kill-connection "$BLOCKER" | jq -c --arg token "$preview" \
    '.+{dry_run:"false",confirm:"true",expected_session:$token}')"
  submit_sessions "$request"
  assert_equal "$(jq -r .reason_code <<< "$TASK_RESULT")" SESSION_TERMINATION_VERIFIED
  assert_equal "$(jq -r .verification.original_transaction_present <<< "$TASK_RESULT")" 0
  wait_value "SELECT n FROM $TEST_DB.lock_probe WHERE id=1;" 10
}

@test "sessions API refuses missing confirmation and stale preview without changing the blocker" {
  start_blocker
  local request
  request="$(payload kill-connection "$BLOCKER" | jq -c '.+{dry_run:"false"}')"
  submit_sessions "$request"
  assert_equal "$(jq -r .reason_code <<< "$TASK_RESULT")" SESSION_CONFIRM_REQUIRED
  request="$(payload kill-connection "$BLOCKER" | jq -c \
    '.+{dry_run:"false",confirm:"true",expected_session:("0"*64)}')"
  submit_sessions "$request"
  assert_equal "$(jq -r .reason_code <<< "$TASK_RESULT")" SESSION_TARGET_CHANGED
  assert_equal "$(db_sql "SELECT COUNT(*) FROM information_schema.INNODB_TRX WHERE TRX_MYSQL_THREAD_ID=$BLOCKER;")" 1
}

@test "sessions API rejects a valid identity outside the operator namespace" {
  local unprivileged_token response
  unprivileged_token="$(kubectl --context "$CTX_B" -n "$DB_NS" create token default --duration=10m)"
  response="$(kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- curl -sS \
    -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $unprivileged_token" \
    -H 'Content-Type: application/json' --data "$(payload diagnose)" "$AQSH_URL/tasks/sessions")"
  assert_equal "$response" 403
}
