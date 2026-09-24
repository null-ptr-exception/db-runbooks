#!/usr/bin/env bats
#
# e2e: MariaDB set-runtime-param on the real operator (#65). Unit tests mock
# kubectl; this proves SET GLOBAL actually lands on the live pods of the
# replicated mariadb-1. Scope: list + dry_run + apply-and-verify for
# max_connections (the #1 break-glass knob). The change is ephemeral, so
# teardown restores the original value.

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="db-ops"
  AQSH_URL="http://aqsh-mariadb.kind-a.test:30080"
  ORIG_FILE="${BATS_FILE_TMPDIR:-/tmp}/srp_orig_max_connections"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }
  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  kubectl --context "$CTX_A" -n mariadb-1 wait \
    --for=condition=Ready mariadb/mariadb --timeout=300s

  # Regression fixture for #84: non-database Pods share the instance label but
  # must never become scope=all mutation targets.
  kubectl --context "$CTX_A" -n mariadb-1 apply -f - <<'YAML'
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
  kubectl --context "$CTX_A" -n mariadb-1 wait pod \
    -l issue-84-auxiliary=true --for=condition=Ready --timeout=120s

  REPORT_PRIMARY=$(kubectl --context "$CTX_A" -n mariadb-1 get mariadb mariadb \
    -o jsonpath='{.status.currentPrimary}')
  [[ -n "$REPORT_PRIMARY" ]] || { echo 'No primary for report fixture' >&2; return 1; }
  export CTX_A CTX_B NS AQSH_URL TEST_POD TOKEN ORIG_FILE REPORT_PRIMARY
  _report_sql "DROP DATABASE IF EXISTS job_report_e2e;
    CREATE DATABASE job_report_e2e CHARACTER SET utf8mb4;
    CREATE TABLE job_report_e2e.executions (
      job_name VARCHAR(80) NOT NULL, start_time DATETIME NOT NULL,
      end_time DATETIME NULL, status VARCHAR(16) NOT NULL, flag INT NOT NULL,
      host VARCHAR(80) NOT NULL, message VARCHAR(255) NOT NULL
    );"
  # Capture before any test executes, so filtered standalone tests restore too.
  _pod_max_conn "$REPORT_PRIMARY" > "$ORIG_FILE"
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

teardown_file() {
  # Restore before report cleanup so a failed DROP cannot skip restoration.
  local orig; orig="$(cat "${ORIG_FILE:-}" 2>/dev/null || true)"
  if [[ -n "$orig" ]]; then
    local pods pod
    pods=$(kubectl --context "kind-cluster-a" -n mariadb-1 get pods \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep '^mariadb-[0-9]' || true)
    local pw; pw=$(kubectl --context "kind-cluster-a" -n mariadb-1 get secret mariadb -o jsonpath='{.data.password}' | base64 -d)
    for pod in $pods; do
      kubectl --context "kind-cluster-a" -n mariadb-1 exec "$pod" -c mariadb -- \
        mariadb -u root -p"$pw" -e "SET GLOBAL max_connections = ${orig}" >/dev/null 2>&1 || true
    done
  fi
  if [[ -n "${REPORT_PRIMARY:-}" ]]; then
    _report_sql 'DROP DATABASE IF EXISTS job_report_e2e' >/dev/null 2>&1 || true
  fi
}

kexec() { kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"; }

http_post() {
  local url="$1" body="$2" response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\\n%{http_code}' \
    -X POST '${url}' -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Content-Type: application/json' -d '${body}'")
  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-300}"
  local elapsed=0 status
  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE
    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && { echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2; return 1; }
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "Task ${task_id} timed out (status: ${status})" >&2; return 1
}

_task_result_data() {
  echo "$TASK_RESPONSE" | jq -c '
    .result.data as $data |
    (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))'
}

_submit() {
  local task="$1" payload="$2" task_id
  http_post "${AQSH_URL}/tasks/${task}" "$payload"
  assert_equal "$HTTP_CODE" "202"
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]] || { echo "no task id: $HTTP_BODY" >&2; return 1; }
  wait_for_task "$AQSH_URL" "$task_id"
}

_pod_max_conn() {
  local pod="$1" pw
  pw=$(kubectl --context "$CTX_A" -n mariadb-1 get secret mariadb -o jsonpath='{.data.password}' | base64 -d)
  kubectl --context "$CTX_A" -n mariadb-1 exec "$pod" -c mariadb -- \
    mariadb -u root -p"$pw" -N -B -e "SELECT @@GLOBAL.max_connections"
}

_report_sql() {
  local pw
  pw=$(kubectl --context "$CTX_A" -n mariadb-1 get secret mariadb -o jsonpath='{.data.password}' | base64 -d)
  kubectl --context "$CTX_A" -n mariadb-1 exec "$REPORT_PRIMARY" -c mariadb -- \
    mariadb -u root -p"$pw" --default-character-set=utf8mb4 -N -B -e "$1"
}

# --- Tests ---

@test "set-runtime-param is registered" {
  local body
  body=$(kexec "curl -s --connect-timeout 5 -m 10 -H 'Authorization: Bearer ${TOKEN}' '${AQSH_URL}/tasks'")
  run echo "$body"
  assert_output --partial "set-runtime-param"
}

@test "set-runtime-param lists max_connections (discovery)" {
  _submit "set-runtime-param" '{"namespace":"mariadb-1"}'
  local data; data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.reason_code')" "SRP_LIST"
  assert_equal "$(echo "$data" | jq -r '.params | map(.param) | index("max_connections") | type')" "number"
  # capture the current value for teardown restore
  echo "$data" | jq -r '.params[] | select(.param=="max_connections") | .current' > "${ORIG_FILE}"
}

@test "set-runtime-param dry_run does not change the value" {
  local before count_before
  before="$(_pod_max_conn mariadb-0)"
  count_before="$(_report_sql 'SELECT COUNT(*) FROM job_report_e2e.executions')"
  _submit "set-runtime-param" '{"namespace":"mariadb-1","param":"max_connections","value":"512"}'
  local data; data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.reason_code')" "SRP_DRY_RUN"
  assert_equal "$(echo "$data" | jq -r '.ephemeral')" "true"
  assert_equal "$(_pod_max_conn mariadb-0)" "$before"   # unchanged
  assert_equal "$(_report_sql 'SELECT COUNT(*) FROM job_report_e2e.executions')" "$count_before"
}

@test "set-runtime-param applies max_connections on all pods (verified live)" {
  local count_before
  count_before="$(_report_sql 'SELECT COUNT(*) FROM job_report_e2e.executions')"
  _submit "set-runtime-param" \
    '{"namespace":"mariadb-1","param":"max_connections","value":"512","dry_run":"false","confirm":"true"}'
  local data; data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.status')" "CHANGED"
  assert_equal "$(echo "$data" | jq -r '.reason_code')" "SRP_APPLIED"
  assert_equal "$(echo "$data" | jq -r '.results | map(.pod) | sort | join(",")')" \
    "mariadb-0,mariadb-1,mariadb-2"
  # the operator/server must actually report the new value on every pod
  assert_equal "$(_pod_max_conn mariadb-0)" "512"
  assert_equal "$(_pod_max_conn mariadb-1)" "512"
  assert_equal "$(_pod_max_conn mariadb-2)" "512"
  assert_equal "$(_report_sql 'SELECT COUNT(*) FROM job_report_e2e.executions')" "$((count_before + 1))"
  assert_equal "$(_report_sql "SELECT COUNT(*) FROM job_report_e2e.executions
    WHERE job_name='max_connections' AND host='$REPORT_PRIMARY' AND status='Finish'
      AND flag=1 AND end_time >= start_time AND end_time <= NOW()
      AND message LIKE 'SET GLOBAL max_connections=512%'")" 1
}

@test "set-runtime-param applies a relative value (+100) computed from live" {
  local before; before="$(_pod_max_conn mariadb-0)"
  _submit "set-runtime-param" \
    '{"namespace":"mariadb-1","param":"max_connections","value":"+100","dry_run":"false","confirm":"true"}'
  local data; data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.status')" "CHANGED"
  assert_equal "$(echo "$data" | jq -r '.value_expr != null')" "true"
  assert_equal "$(_pod_max_conn mariadb-0)" "$((before + 100))"
}


@test "set-runtime-param blocked request writes Failed even with completed execution" {
  local before
  before="$(_pod_max_conn "$REPORT_PRIMARY")"
  _submit "set-runtime-param" \
    '{"namespace":"mariadb-1","param":"max_connections","value":"invalid","dry_run":"false","confirm":"true"}'
  local data; data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.status')" BLOCKED
  assert_equal "$(echo "$data" | jq -r '.reason_code')" VALUE_INVALID
  assert_equal "$(_pod_max_conn "$REPORT_PRIMARY")" "$before"
  assert_equal "$(_report_sql "SELECT COUNT(*) FROM job_report_e2e.executions
    WHERE job_name='max_connections' AND host='$REPORT_PRIMARY' AND status='Failed'
      AND flag=4 AND end_time >= start_time AND message LIKE '%invalid%'")" 1
}

@test "set-runtime-param succeeds when report destination is unavailable" {
  _report_sql 'RENAME TABLE job_report_e2e.executions TO job_report_e2e.saved_executions'
  _submit "set-runtime-param" \
    '{"namespace":"mariadb-1","param":"max_connections","value":"513","dry_run":"false","confirm":"true"}'
  local data; data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.reason_code')" SRP_APPLIED
  assert_equal "$(_pod_max_conn "$REPORT_PRIMARY")" 513
  _report_sql 'RENAME TABLE job_report_e2e.saved_executions TO job_report_e2e.executions'
}
