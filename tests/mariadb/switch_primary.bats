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
# Scope is deliberately minimal per review: happy-path switch + assert the
# primary flipped and the new primary is writable. The stuck-switch recovery
# ladder (rollback / gated pod-eviction) stays unit-tested; validating it needs a
# fault-injection harness tracked in #59.

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

  # Earlier suites (restart) roll the primary pod and trigger an operator
  # failover; wait for mariadb-1 to settle back to Ready before switching, so we
  # operate on a healthy topology rather than mid-reconcile churn.
  kubectl --context "$CTX_A" -n mariadb-1 wait \
    --for=condition=Ready mariadb/mariadb --timeout=300s || true

  export CTX_A CTX_B NS AQSH_URL TEST_POD TOKEN
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

# Always leave the primary back on podIndex 0 so later suites see the original
# topology (some assume mariadb-0 is primary).
teardown_file() {
  kubectl --context "kind-cluster-a" -n mariadb-1 patch mariadb mariadb \
    --type merge -p '{"spec":{"replication":{"primary":{"podIndex":0}}}}' >/dev/null 2>&1 || true
  kubectl --context "kind-cluster-a" -n mariadb-1 wait \
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
  local task="$1" payload="$2" task_id
  http_post "${AQSH_URL}/tasks/${task}" "$payload"
  assert_equal "$HTTP_CODE" "202"
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]] || { echo "no task id: $HTTP_BODY" >&2; return 1; }
  wait_for_task "$AQSH_URL" "$task_id"
}

_primary_index() {
  kubectl --context "$CTX_A" -n mariadb-1 get mariadb mariadb \
    -o jsonpath='{.status.currentPrimaryPodIndex}' 2>/dev/null
}

# A valid podIndex other than the current primary (replicas: 3 → 0,1,2).
_other_index() { echo $(( ( ${1:-0} + 1 ) % 3 )); }

# _switch_payload <target> [confirm] — dry_run unless a confirm arg is given.
_switch_payload() {
  if [[ -n "${2:-}" ]]; then
    printf '{"namespace":"mariadb-1","target":"%s","dry_run":"false","confirm":"true","lag_threshold":"30"}' "$1"
  else
    printf '{"namespace":"mariadb-1","target":"%s","lag_threshold":"30"}' "$1"
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
  echo "# replication: $(kubectl --context "$CTX_A" -n mariadb-1 get mariadb mariadb -o jsonpath='{.status.replicationStatus}' 2>/dev/null)" >&3
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

@test "switch-primary promotes the target replica to primary" {
  local from target; from="$(_primary_index)"; target="$(_other_index "$from")"
  echo "# switching primary ${from} -> ${target}" >&3
  _dump_state
  # lag_threshold 30 tolerates minor idle-replication lag so the pre-check
  # doesn't flake; the replicas are otherwise caught up.
  _submit "switch-primary" "$(_switch_payload "$target" true)"
  local data; data="$(_task_result_data)"
  echo "# switch result: $data" >&3
  _dump_state
  assert_equal "$(echo "$data" | jq -r '.status')" "CHANGED"
  assert_equal "$(echo "$data" | jq -r '.reason_code')" "PRIMARY_SWITCHED"

  # The operator must have actually flipped the primary...
  assert_equal "$(_primary_index)" "$target"
  # ...and the new primary must be genuinely writable (not just a status flip).
  _sql_primary "CREATE DATABASE IF NOT EXISTS switch_e2e; \
    CREATE TABLE IF NOT EXISTS switch_e2e.t (id INT PRIMARY KEY); \
    INSERT INTO switch_e2e.t VALUES (1);"
  run _sql_primary "SELECT COUNT(*) FROM switch_e2e.t"
  assert_output "1"
}
