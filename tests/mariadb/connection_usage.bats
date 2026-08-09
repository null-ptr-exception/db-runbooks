#!/usr/bin/env bats

setup_file() {
  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="db-ops"
  DB_NS="mariadb-1"
  AQSH_URL="http://aqsh-mariadb.kind-a.test:30080"
  PROBE_USER="connection_usage_probe"
  PROBE_PASSWORD="connection-usage-probe-77"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }
  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  # Regression fixture for #84: read-only collection must ignore auxiliary
  # workloads even when they share the MariaDB instance label.
  kubectl --context "$CTX_A" -n "$DB_NS" apply -f - <<'YAML'
apiVersion: v1
kind: List
items:
  - apiVersion: v1
    kind: Pod
    metadata:
      name: mariadb-metrics
      labels:
        app.kubernetes.io/instance: mariadb
        issue-84-auxiliary: "true"
    spec:
      containers:
        - name: auxiliary
          image: localhost:5005/db-runbooks:latest
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c", "sleep 3600"]
  - apiVersion: v1
    kind: Pod
    metadata:
      name: mariadb-query-exporter
      labels:
        app.kubernetes.io/instance: mariadb
        issue-84-auxiliary: "true"
    spec:
      containers:
        - name: auxiliary
          image: localhost:5005/db-runbooks:latest
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c", "sleep 3600"]
YAML
  kubectl --context "$CTX_A" -n "$DB_NS" wait pod \
    -l issue-84-auxiliary=true --for=condition=Ready --timeout=120s

  export CTX_A CTX_B NS DB_NS AQSH_URL PROBE_USER PROBE_PASSWORD TEST_POD TOKEN
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

teardown() {
  _cleanup_probe_connections
}

kexec() {
  kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"
}

http_post() {
  local url="$1" body="$2" response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\n%{http_code}' \
    -X POST '${url}' \
    -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Content-Type: application/json' \
    -d '${body}'")
  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-540}" elapsed=0 status
  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE
    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && {
      echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2
      return 1
    }
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

task_result_data() {
  echo "$TASK_RESPONSE" | jq -c '
    .result.data as $data |
    (($data | try fromjson catch null) //
      (if ($data | type) == "object" then $data else .result end))'
}

primary_pod() {
  local primary
  primary=$(kubectl --context "$CTX_A" -n "$DB_NS" get mariadb mariadb \
    -o jsonpath='{.status.currentPrimary}' 2>/dev/null || true)
  printf '%s' "${primary:-mariadb-0}"
}

root_password() {
  kubectl --context "$CTX_A" -n "$DB_NS" get secret mariadb \
    -o jsonpath='{.data.password}' | base64 -d
}

sql_as_root() {
  local query="$1" pod password
  pod="$(primary_pod)"
  password="$(root_password)"
  kubectl --context "$CTX_A" -n "$DB_NS" exec "$pod" -c mariadb -- \
    mariadb -u root -p"$password" -N -B -e "$query"
}

_cleanup_probe_connections() {
  local kills
  kills=$(sql_as_root "SELECT GROUP_CONCAT(CONCAT('KILL ', ID) SEPARATOR ';') FROM information_schema.PROCESSLIST WHERE USER='${PROBE_USER}'" 2>/dev/null || true)
  [[ -z "$kills" || "$kills" == "NULL" ]] || sql_as_root "${kills};" >/dev/null 2>&1 || true
  sql_as_root "DROP USER IF EXISTS '${PROBE_USER}'@'%';" >/dev/null 2>&1 || true
}

start_probe_connections() {
  local count="$1" pod password observed=0
  pod="$(primary_pod)"
  password="$(root_password)"
  sql_as_root "DROP USER IF EXISTS '${PROBE_USER}'@'%'; CREATE USER '${PROBE_USER}'@'%' IDENTIFIED BY '${PROBE_PASSWORD}';" >/dev/null

  kubectl --context "$CTX_A" -n "$DB_NS" exec "$pod" -c mariadb -- sh -c "
    i=0
    while [ \"\$i\" -lt '${count}' ]; do
      mariadb --protocol=tcp -h 127.0.0.1 -u '${PROBE_USER}' -p'${PROBE_PASSWORD}' \
        -N -B -e 'SELECT SLEEP(120)' >/tmp/connection-usage-\$i.log 2>&1 &
      i=\$((i + 1))
    done
  "

  for _ in $(seq 1 20); do
    observed=$(sql_as_root "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='${PROBE_USER}'")
    (( observed >= count )) && return 0
    sleep 1
  done
  echo "expected ${count} probe connections, observed ${observed}" >&2
  return 1
}

submit_connection_usage() {
  local task_id
  http_post "${AQSH_URL}/tasks/connection-usage" \
    '{"namespace":"mariadb-1","account_limit":"10"}'
  assert_equal "$HTTP_CODE" "202"
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]] || { echo "no task id: $HTTP_BODY" >&2; return 1; }
  wait_for_task "$AQSH_URL" "$task_id"
}

@test "connection-usage is registered" {
  local body
  body=$(kexec "curl -s --connect-timeout 5 -m 10 -H 'Authorization: Bearer ${TOKEN}' '${AQSH_URL}/tasks'")
  run echo "$body"
  assert_output --partial "connection-usage"
}

@test "connection-usage excludes shared-label auxiliary pods" {
  local task_id result
  http_post "${AQSH_URL}/tasks/connection-usage" \
    '{"namespace":"mariadb-1","account_limit":"10"}'
  assert_equal "$HTTP_CODE" "202"
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]] || { echo "no task id: $HTTP_BODY" >&2; return 1; }
  wait_for_task "$AQSH_URL" "$task_id"

  result="$(task_result_data)"
  case "$(echo "$result" | jq -r '.status')" in
    READY | WARN) ;;
    *) echo "$result" | jq '.' >&2; return 1 ;;
  esac
  assert_equal "$(echo "$result" | jq -r '.partial')" "false"
  assert_equal "$(echo "$result" | jq -r '.requested_pods')" "3"
  assert_equal "$(echo "$result" | jq -r '.pods | map(.pod) | sort | join(",")')" \
    "mariadb-0,mariadb-1,mariadb-2"
}

@test "connection-usage reports real active connections by account without sensitive rows" {
  start_probe_connections 3
  submit_connection_usage

  local result account
  result="$(task_result_data)"
  account=$(echo "$result" | jq -c --arg account "$PROBE_USER" \
    '.accounts[] | select(.account==$account)')

  case "$(echo "$result" | jq -r '.status')" in
    READY | WARN) ;;
    *) echo "$result" | jq '.' >&2; return 1 ;;
  esac
  [ "$(echo "$result" | jq -r '.partial')" = "false" ]
  [ "$(echo "$result" | jq -r '.account_limit')" = "10" ]
  [ "$(echo "$result" | jq -r '.returned_account_count == (.accounts | length)')" = "true" ]
  [ "$(echo "$result" | jq -r '.queried_pods == .requested_pods')" = "true" ]
  [ "$(echo "$result" | jq -r '.requested_pods')" = "3" ]
  [ "$(echo "$result" | jq -r '.pods | map(.pod) | sort | join(",")')" = \
    "mariadb-0,mariadb-1,mariadb-2" ]
  [ "$(echo "$account" | jq -r '.current_connections >= 3')" = "true" ]
  [ "$(echo "$account" | jq -r '.active_connections >= 3')" = "true" ]
  [ "$(echo "$account" | jq -r '.idle_connections')" = "0" ]
  [ "$(echo "$result" | jq -r '.connection_capacity == ([.pods[].max_connections] | add)')" = "true" ]
  run grep -Eqi 'SELECT SLEEP|connection_id|client.address|"host"|"id"' <<<"$result"
  [ "$status" -ne 0 ]
}
