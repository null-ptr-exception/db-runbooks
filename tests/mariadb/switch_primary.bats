#!/usr/bin/env bats
#
# e2e: MariaDB switch-primary — promote a replica to primary on the REAL operator
# (#59). The unit tests (tests/unit/mariadb/switch-primary.bats) mock kubectl and
# only exercise the guard / recovery state machine; this proves the operator
# actually performs the spec.replication.primary.podIndex switchover on the
# 2-cluster lab's replicated mariadb-1 (helmfile sets replicas: 3) — catching the
# things a mock can't, e.g. the operator ignoring the patch or currentPrimary not
# converging.
#
# Scope covers the happy-path switch plus the live SQL-health fallback: the
# latter pauses the controller and removes only its replica status map so the
# real task must query the still-running replicas with SHOW ALL SLAVES STATUS. The
# stuck-switch recovery ladder (rollback / gated pod-eviction) stays unit-tested;
# validating it needs a fault-injection harness tracked in #59.

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="db-ops"
  AQSH_URL="http://aqsh-mariadb.kind-a.test:30080"
  OPERATOR_NS="db-ops"
  OPERATOR_DEPLOYMENT="mariadb-operator"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  export CTX_A CTX_B NS AQSH_URL TEST_POD TOKEN OPERATOR_NS OPERATOR_DEPLOYMENT

  # Make this file runnable in isolation (not only when it runs last): wait for
  # Ready AND for the operator to finish populating .status.replication.replicas,
  # which it does asynchronously *after* Ready. Fail loudly if it never settles.
  kubectl --context "$CTX_A" -n mariadb-1 wait \
    --for=condition=Ready mariadb/mariadb --timeout=300s
  _wait_for_replication_map 180
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  OPERATOR_SCALED_DOWN=false
  OPERATOR_ORIGINAL_REPLICAS=""
  WRITER_PID=""
}

teardown() {
  _stop_writer
  # The SQL-fallback e2e deliberately pauses the controller. Always restore it,
  # including when an assertion in that test fails midway through.
  if [[ "${OPERATOR_SCALED_DOWN:-false}" == "true" ]]; then
    _restore_operator
  fi
}

_stop_writer() {
  if [[ -n "${WRITER_PID:-}" ]]; then
    kill "$WRITER_PID" >/dev/null 2>&1 || true
    wait "$WRITER_PID" >/dev/null 2>&1 || true
    WRITER_PID=""
  fi
}

# Always leave the primary back on podIndex 0 so later suites see the original
# topology (some assume mariadb-0 is primary).
teardown_file() {
  kubectl --context "$CTX_A" -n mariadb-1 patch mariadb mariadb \
    --type merge -p '{"spec":{"replication":{"primary":{"podIndex":0}}}}' >/dev/null 2>&1 || true
  kubectl --context "$CTX_A" -n mariadb-1 wait \
    --for=jsonpath='{.status.currentPrimaryPodIndex}'=0 mariadb/mariadb --timeout=300s >/dev/null 2>&1 || true
}

kexec() { kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"; }

http_post() {
  local url="$1" body="$2" response
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
  local base_url="$1" task_id="$2" max_wait="${3:-960}"
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

_submit() {
  local task="$1" payload="$2" max_wait="${3:-960}" task_id
  http_post "${AQSH_URL}/tasks/${task}" "$payload"
  assert_equal "$HTTP_CODE" "202"
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]] || { echo "no task id: $HTTP_BODY" >&2; return 1; }
  wait_for_task "$AQSH_URL" "$task_id" "$max_wait"
}

_primary_index() {
  kubectl --context "$CTX_A" -n mariadb-1 get mariadb mariadb \
    -o jsonpath='{.status.currentPrimaryPodIndex}' 2>/dev/null
}

_replica_count() {
  kubectl --context "$CTX_A" -n mariadb-1 get mariadb mariadb -o jsonpath='{.spec.replicas}'
}

_wait_for_replication_map() {
  local max_wait="${1:-180}" elapsed=0 count=0
  while (( elapsed < max_wait )); do
    count=$(kubectl --context "$CTX_A" -n mariadb-1 get mariadb mariadb \
      -o json | jq '.status.replication.replicas // {} | length') || count=0
    [[ "$count" -ge 2 ]] && return 0
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "replication status not populated (replicas=$count) after ${elapsed}s" >&2
  return 1
}

_wait_for_all_replicas_caught_up() {
  local max_wait="${1:-120}" elapsed=0 replicas expected cr
  replicas="$(_replica_count)"
  expected=$((replicas - 1))
  while (( elapsed < max_wait )); do
    cr=$(kubectl --context "$CTX_A" -n mariadb-1 get mariadb mariadb -o json) || cr='{}'
    if jq -e --argjson expected "$expected" '
      (.status.replication.replicas // {}) as $r
      | (($r | length) == $expected)
        and all($r[];
          .slaveIORunning == true
          and .slaveSQLRunning == true
          and .secondsBehindMaster == 0)
    ' <<<"$cr" >/dev/null; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "replicas did not become fully caught up within ${max_wait}s" >&2
  return 1
}

_wait_for_operator_scaled_down() {
  local max_wait="${1:-60}" elapsed=0 running=1
  while (( elapsed < max_wait )); do
    running=$(kubectl --context "$CTX_A" -n "$OPERATOR_NS" \
      get deployment "$OPERATOR_DEPLOYMENT" -o json | jq '.status.replicas // 0') || running=1
    [[ "$running" == "0" ]] && return 0
    sleep 2
    elapsed=$((elapsed + 2))
  done
  echo "${OPERATOR_DEPLOYMENT} still has ${running} replicas after ${max_wait}s" >&2
  return 1
}

_restore_operator() {
  local replicas="${OPERATOR_ORIGINAL_REPLICAS:-1}"
  kubectl --context "$CTX_A" -n "$OPERATOR_NS" scale \
    deployment "$OPERATOR_DEPLOYMENT" --replicas="$replicas"
  if (( replicas > 0 )); then
    kubectl --context "$CTX_A" -n "$OPERATOR_NS" rollout status \
      deployment "$OPERATOR_DEPLOYMENT" --timeout=180s
    kubectl --context "$CTX_A" -n mariadb-1 wait \
      --for=condition=Ready mariadb/mariadb --timeout=300s
    _wait_for_replication_map 180
  fi
  OPERATOR_SCALED_DOWN=false
}

# A valid podIndex other than the current primary, derived from the live
# replica count rather than a hardcoded topology.
_other_index() { local n; n="$(_replica_count)"; echo $(( ( ${1:-0} + 1 ) % ${n:-3} )); }

# _switch_payload <target> [confirm] — dry_run unless a confirm arg is given.
# lag_threshold is intentionally NOT sent (it's internal policy, not a task
# input); the setup_file readiness wait leaves replicas fully synced (lag 0).
_switch_payload() {
  if [[ -n "${2:-}" ]]; then
    printf '{"namespace":"mariadb-1","target":"%s","dry_run":"false","confirm":"true"}' "$1"
  else
    printf '{"namespace":"mariadb-1","target":"%s"}' "$1"
  fi
}

_root_password() {
  kubectl --context "$CTX_A" -n mariadb-1 get secret mariadb \
    -o jsonpath='{.data.password}' | base64 -d
}

# Run SQL as root on the CURRENT primary pod.
_sql_primary() {
  local query="$1" primary password
  primary="$(kubectl --context "$CTX_A" -n mariadb-1 get mariadb mariadb -o jsonpath='{.status.currentPrimary}')"
  password="$(_root_password)"
  kubectl --context "$CTX_A" -n mariadb-1 exec "$primary" -c mariadb -- \
    mariadb -u root -p"${password}" -N -B -e "$query"
}

_writer_loop() {
  local seq=0
  while true; do
    seq=$((seq + 1))
    _sql_primary "INSERT INTO switch_e2e.events(note) VALUES ('continuous-${seq}')" >/dev/null 2>&1 || true
    sleep 0.2
  done
}

_event_count() { _sql_primary 'SELECT COUNT(*) FROM switch_e2e.events'; }

_wait_for_event_count_greater_than() {
  local baseline="$1" max_wait="${2:-60}" elapsed=0 count=0
  while (( elapsed < max_wait )); do
    count="$(_event_count 2>/dev/null || echo 0)"
    [[ "$count" =~ ^[0-9]+$ ]] && (( count > baseline )) && return 0
    sleep 1
    elapsed=$((elapsed + 1))
  done
  echo "continuous writer did not advance beyond ${baseline} rows" >&2
  return 1
}

# --- Tests ---

@test "switch-primary is registered" {
  local body
  body=$(kexec "curl -s --connect-timeout 5 -m 10 \
    -H 'Authorization: Bearer ${TOKEN}' '${AQSH_URL}/tasks'")
  run echo "$body"
  assert_output --partial "switch-primary"
}

@test "mariadb-1 is replicated with a well-defined primary" {
  # The primary's podIndex is NOT assumed to be 0: earlier suites (e.g. restart)
  # roll the primary pod, and the operator fails over to another replica. Assert
  # only that it's a replicated instance with some current primary in range.
  assert_equal "$(kubectl --context "$CTX_A" -n mariadb-1 get mariadb mariadb -o jsonpath='{.spec.replicas}')" "3"
  run _primary_index
  assert_output --regexp '^[0-2]$'
}

_dump_state() {
  echo "# CR: index=$(_primary_index) ready=$(kubectl --context "$CTX_A" -n mariadb-1 get mariadb mariadb -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" >&3
  echo "# replication: $(kubectl --context "$CTX_A" -n mariadb-1 get mariadb mariadb -o jsonpath='{.status.replication}' 2>/dev/null)" >&3
}

@test "switch-primary dry_run shows the plan without switching" {
  local from target; from="$(_primary_index)"; target="$(_other_index "$from")"
  _submit "switch-primary" "$(_switch_payload "$target")"
  local data; data="$(_task_result_data)"
  echo "# dry_run result: $data" >&3
  assert_equal "$(echo "$data" | jq -r '.reason_code')" "SWITCH_DRY_RUN"
  assert_equal "$(echo "$data" | jq -r '.from_pod_index')" "$from"
  assert_equal "$(echo "$data" | jq -r '.to_pod_index')" "$target"
  assert_equal "$(_primary_index)" "$from"   # unchanged
}

@test "switch-primary auto-selects a target when none is given (dry_run)" {
  local from; from="$(_primary_index)"
  _submit "switch-primary" '{"namespace":"mariadb-1"}' 180
  local data; data="$(_task_result_data)"
  echo "# auto dry_run result: $data" >&3
  assert_equal "$(echo "$data" | jq -r '.reason_code')" "SWITCH_DRY_RUN"
  assert_equal "$(echo "$data" | jq -r '.target_auto_selected')" "true"
  # picked a real replica that isn't the current primary
  local to; to="$(echo "$data" | jq -r '.to_pod_index')"
  [ "$to" != "$from" ]
  [[ "$to" =~ ^[0-2]$ ]]
}

@test "switch-primary reads live SQL health when the CR replica map is absent" {
  # The current operator normally publishes status.replication.replicas, so
  # briefly stop only its controller and remove that status field. The database
  # pods stay running. This deterministically drives the production task through
  # real pod exec + SHOW ALL SLAVES STATUS without adding a test-only code switch.
  _wait_for_all_replicas_caught_up 120
  local from data to
  from="$(_primary_index)"
  OPERATOR_ORIGINAL_REPLICAS=$(kubectl --context "$CTX_A" -n "$OPERATOR_NS" \
    get deployment "$OPERATOR_DEPLOYMENT" -o jsonpath='{.spec.replicas}')
  [[ "$OPERATOR_ORIGINAL_REPLICAS" =~ ^[1-9][0-9]*$ ]]

  OPERATOR_SCALED_DOWN=true
  kubectl --context "$CTX_A" -n "$OPERATOR_NS" scale \
    deployment "$OPERATOR_DEPLOYMENT" --replicas=0
  _wait_for_operator_scaled_down 60
  kubectl --context "$CTX_A" -n mariadb-1 patch \
    --subresource=status mariadbs.k8s.mariadb.com mariadb --type merge \
    -p '{"status":{"replication":null}}'
  assert_equal "$(kubectl --context "$CTX_A" -n mariadb-1 get \
    mariadbs.k8s.mariadb.com mariadb -o json | jq '.status.replication.replicas // {} | length')" "0"

  _submit "switch-primary" '{"namespace":"mariadb-1"}' 180
  data="$(_task_result_data)"
  echo "# SQL fallback dry_run result: $data" >&3
  assert_equal "$(echo "$data" | jq -r '.reason_code')" "SWITCH_DRY_RUN"
  assert_equal "$(echo "$data" | jq -r '.replicas_source')" "show_all_slaves_status"
  assert_equal "$(echo "$data" | jq -r '.target_auto_selected')" "true"
  to="$(echo "$data" | jq -r '.to_pod_index')"
  [ "$to" != "$from" ]
  [[ "$to" =~ ^[0-2]$ ]]
  assert_equal "$(_primary_index)" "$from"

  _restore_operator
}

@test "switch-primary promotes the target replica to primary" {
  local from target; from="$(_primary_index)"; target="$(_other_index "$from")"
  echo "# switching primary ${from} -> ${target}" >&3
  _dump_state
  _sql_primary "CREATE DATABASE IF NOT EXISTS switch_e2e; \
    CREATE TABLE IF NOT EXISTS switch_e2e.events (id BIGINT AUTO_INCREMENT PRIMARY KEY, note VARCHAR(128)); \
    INSERT INTO switch_e2e.events(note) VALUES ('pre-switch-sentinel');"
  local before_count
  before_count="$(_event_count)"
  _writer_loop &
  WRITER_PID=$!
  _wait_for_event_count_greater_than "$before_count" 30
  before_count="$(_event_count)"

  _submit "switch-primary" "$(_switch_payload "$target" true)"
  local data; data="$(_task_result_data)"
  echo "# switch result: $data" >&3
  _dump_state
  assert_equal "$(echo "$data" | jq -r '.status')" "CHANGED"
  assert_equal "$(echo "$data" | jq -r '.reason_code')" "PRIMARY_SWITCHED"

  # The operator must have actually flipped the primary...
  assert_equal "$(_primary_index)" "$target"
  # ...the fenced pre-switch position must be present, and the service must
  # resume accepting the continuous writer on the new primary.
  run _sql_primary "SELECT COUNT(*) FROM switch_e2e.events WHERE note='pre-switch-sentinel'"
  assert_output --regexp '^[1-9][0-9]*$'
  local post_switch_count
  post_switch_count="$(_event_count)"
  _wait_for_event_count_greater_than "$post_switch_count" 60
  _stop_writer
}
