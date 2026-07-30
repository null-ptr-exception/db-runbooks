#!/usr/bin/env bats
# =============================================================================
# Integration tests for the MariaDB pods gateway task API
# (pods/list, pods/delete) — see docs/mariadb/pods.md.
#
# Runs against the suite's shared "mariadb-1" instance (same pattern as
# restart.bats) rather than provisioning a dedicated throwaway instance —
# standing up a new mariadb-operator-managed instance per file is expensive,
# and restart.bats already proves cycling every pod of this shared instance
# and waiting for it to come back Ready is an accepted pattern here.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="db-ops"
  DB_NS="mariadb-1"
  AQSH_URL="http://aqsh-mariadb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }
  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  # An auxiliary Pod sharing the instance label but with no StatefulSet
  # ownerReference/ordinal-name membership — proves pods/list and
  # pods/delete's membership check is exact, not a label-selector guess
  # (same fixture pattern as connection_usage.bats's issue-84 regression).
  kubectl --context "$CTX_A" -n "$DB_NS" apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: mariadb-pods-test-auxiliary
  labels:
    app.kubernetes.io/instance: mariadb
    pods-test-auxiliary: "true"
spec:
  containers:
    - name: auxiliary
      image: localhost:5005/db-runbooks:latest
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 3600"]
YAML
  kubectl --context "$CTX_A" -n "$DB_NS" wait pod mariadb-pods-test-auxiliary \
    --for=condition=Ready --timeout=120s

  export CTX_A CTX_B NS DB_NS AQSH_URL TEST_POD TOKEN
}

teardown_file() {
  kubectl --context "kind-cluster-a" -n "mariadb-1" delete pod mariadb-pods-test-auxiliary \
    --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  OPERATOR_SCALED_DOWN=false
  OPERATOR_ORIGINAL_REPLICAS=""
  STS_SCALED_DOWN=false
  STS_ORIGINAL_REPLICAS=""
}

teardown() {
  # The "already gone" test below briefly pauses the mariadb-operator (same
  # pattern as switch_primary.bats) AND scales the StatefulSet itself down
  # by one — pausing the operator alone stops it fighting a manual scale,
  # but the StatefulSet's own (built-in, not operator-managed) controller
  # would otherwise still recreate a deleted Pod to match its existing
  # replica count. Always restore both, including when an assertion or wait
  # in that test fails midway.
  if [[ "${STS_SCALED_DOWN:-false}" == "true" ]]; then
    kubectl --context "$CTX_A" -n "$DB_NS" scale statefulset/mariadb \
      --replicas="${STS_ORIGINAL_REPLICAS:-3}"
  fi
  if [[ "${OPERATOR_SCALED_DOWN:-false}" == "true" ]]; then
    kubectl --context "$CTX_A" -n "$NS" scale deployment mariadb-operator \
      --replicas="${OPERATOR_ORIGINAL_REPLICAS:-1}"
  fi
}

kexec() {
  kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"
}

# Same helper as switch_primary.bats' _wait_for_operator_scaled_down.
_wait_for_operator_scaled_down() {
  local max_wait="${1:-60}" elapsed=0 running
  while ((elapsed < max_wait)); do
    running=$(kubectl --context "$CTX_A" -n "$NS" \
      get deployment mariadb-operator -o json | jq '.status.replicas // 0') || running=1
    [[ "$running" -eq 0 ]] && return 0
    sleep 2
    elapsed=$((elapsed + 2))
  done
  echo "mariadb-operator still has ${running} replicas after ${max_wait}s" >&2
  return 1
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
  local base_url="$1" task_id="$2" max_wait="${3:-300}"
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE

    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    if [[ "$status" == "completed" || "$status" == "failed" ]]; then
      TASK_STATUS="$status"
      export TASK_STATUS
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

# mariadb/pods/*.sh use the native mdbt_write_result/response_ok envelope
# (like backup.bats/logical_backup_restore.bats, not the flat secrets.bats
# shape): .result.data is {status,code,operation,message,data,timestamp,
# reason}. RESULT_REASON is the top-level "reason" (present on both success
# and mdbt_fail error paths); RESULT_DATA is the inner domain payload.
run_pods_task() {
  local endpoint="$1" body="$2" max_wait="${3:-120}"
  http_post "${AQSH_URL}/tasks/pods%2F${endpoint}" "$body"
  [[ "$HTTP_CODE" == "202" ]] || { echo "submit ${endpoint} got HTTP ${HTTP_CODE}: ${HTTP_BODY}" >&2; return 1; }
  local task_id envelope
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" "$max_wait" || return 1
  envelope=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  RESULT_REASON=$(echo "$envelope" | jq -r '.reason // empty')
  RESULT_DATA=$(echo "$envelope" | jq -r '.data // empty')
  export RESULT_REASON RESULT_DATA
}

# ── pods/list ────────────────────────────────────────────────────────────────

@test "pods/list reports exactly the instance's member pods" {
  run_pods_task "list" "{\"namespace\":\"${DB_NS}\"}"
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.instance')" "mariadb"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.count')" "3"

  local names
  names=$(echo "$RESULT_DATA" | jq -r '.pods[].name' | sort | paste -sd,)
  assert_equal "$names" "mariadb-0,mariadb-1,mariadb-2"

  local pod0
  pod0=$(echo "$RESULT_DATA" | jq -c '.pods[] | select(.name == "mariadb-0")')
  assert_equal "$(echo "$pod0" | jq -r '.ordinal')" "0"
  assert_equal "$(echo "$pod0" | jq -r '.phase')" "Running"
  [[ "$(echo "$pod0" | jq -r '.node')" != "null" ]]

  local ready
  ready=$(echo "$pod0" | jq -r '.ready')
  [[ "$ready" =~ ^([0-9]+)/([0-9]+)$ ]]
  assert_equal "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

@test "pods/list excludes an auxiliary Pod sharing the instance label" {
  run_pods_task "list" "{\"namespace\":\"${DB_NS}\"}"
  assert_equal "$TASK_STATUS" "completed"
  local aux_count
  aux_count=$(echo "$RESULT_DATA" | jq '[.pods[] | select(.name == "mariadb-pods-test-auxiliary")] | length')
  assert_equal "$aux_count" "0"
}

# ── pods/delete gating ───────────────────────────────────────────────────────

@test "pods/delete requires confirm=true when dry_run=false" {
  run_pods_task "delete" "{\"namespace\":\"${DB_NS}\",\"target_pod\":\"mariadb-2\",\"dry_run\":\"false\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$RESULT_REASON" "INVALID_REQUEST"
}

@test "pods/delete requires pod_uid when dry_run=false" {
  run_pods_task "delete" "{\"namespace\":\"${DB_NS}\",\"target_pod\":\"mariadb-2\",\"dry_run\":\"false\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$RESULT_REASON" "INVALID_REQUEST"
}

# Note: there is no "dry_run=flase (typo)" test here — the tasks.yaml
# pattern for `dry_run` (`^(true|false)$`) already rejects it at submission
# (HTTP 400, before the script — and its own belt-and-braces literal
# comparison — ever runs), the same "not worth double-testing a format
# guard" call fcv.bats/profiler.bats make on the MongoDB side for their own
# pattern-guarded inputs. dry_run is safety-critical (an unrecognized value
# must never be silently treated as false and fall through to a real
# delete), which is exactly why it gets a strict enum pattern instead of
# the free-form `type: string` most other boolean-ish inputs use.

@test "pods/delete rejects a target_pod that is not a member of the instance" {
  run_pods_task "delete" "{\"namespace\":\"${DB_NS}\",\"target_pod\":\"mariadb-pods-test-auxiliary\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$RESULT_REASON" "POD_NOT_MEMBER"
}

# ── pods/delete execution ────────────────────────────────────────────────────

@test "pods/delete dry_run previews the delete without touching the pod" {
  local before_uid
  before_uid=$(kubectl --context "$CTX_A" -n "$DB_NS" get pod mariadb-2 -o jsonpath='{.metadata.uid}')

  run_pods_task "delete" "{\"namespace\":\"${DB_NS}\",\"target_pod\":\"mariadb-2\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$RESULT_REASON" "DRY_RUN_READY"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.deleted')" "false"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.force')" "false"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.pod_uid')" "$before_uid"

  local after_uid
  after_uid=$(kubectl --context "$CTX_A" -n "$DB_NS" get pod mariadb-2 -o jsonpath='{.metadata.uid}')
  assert_equal "$after_uid" "$before_uid"
}

@test "pods/delete confirmed deletes the pod and the StatefulSet recreates it" {
  local before_uid
  before_uid=$(kubectl --context "$CTX_A" -n "$DB_NS" get pod mariadb-2 -o jsonpath='{.metadata.uid}')

  run_pods_task "delete" "{\"namespace\":\"${DB_NS}\",\"target_pod\":\"mariadb-2\",\"dry_run\":\"false\",\"confirm\":\"true\",\"pod_uid\":\"${before_uid}\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$RESULT_REASON" "POD_DELETED"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.deleted')" "true"

  kubectl --context "$CTX_A" -n "$DB_NS" wait pod mariadb-2 --for=condition=Ready --timeout=180s

  local after_uid
  after_uid=$(kubectl --context "$CTX_A" -n "$DB_NS" get pod mariadb-2 -o jsonpath='{.metadata.uid}')
  assert_not_equal "$after_uid" "$before_uid"

  run_pods_task "list" "{\"namespace\":\"${DB_NS}\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.count')" "3"
}

@test "pods/delete on an already-gone target reports POD_ALREADY_DELETED, not POD_NOT_MEMBER" {
  # Pause the mariadb-operator's reconciliation (same pattern as
  # switch_primary.bats) so it won't fight a manual StatefulSet scale, THEN
  # scale the StatefulSet itself down by one. Pausing only the operator is
  # not enough on its own: the StatefulSet is still a plain Kubernetes
  # object owned by the built-in (non-operator) StatefulSet controller,
  # which would otherwise recreate a deleted mariadb-2 to match the STS's
  # existing replica count regardless of whether the operator is running.
  # Scaling the STS down removes that replacement source, so mariadb-2 stays
  # gone long enough to prove POD_ALREADY_DELETED is reachable, rather than
  # shadowed by POD_NOT_MEMBER: mariadb_list_member_pods only lists
  # currently-live, owned Pods, so an absent target previously always
  # failed that check first.
  OPERATOR_ORIGINAL_REPLICAS=$(kubectl --context "$CTX_A" -n "$NS" \
    get deployment mariadb-operator -o jsonpath='{.spec.replicas}')
  [[ "$OPERATOR_ORIGINAL_REPLICAS" =~ ^[1-9][0-9]*$ ]]
  OPERATOR_SCALED_DOWN=true
  kubectl --context "$CTX_A" -n "$NS" scale deployment mariadb-operator --replicas=0
  _wait_for_operator_scaled_down 60

  STS_ORIGINAL_REPLICAS=$(kubectl --context "$CTX_A" -n "$DB_NS" \
    get statefulset mariadb -o jsonpath='{.spec.replicas}')
  [[ "$STS_ORIGINAL_REPLICAS" =~ ^[1-9][0-9]*$ ]]
  STS_SCALED_DOWN=true
  kubectl --context "$CTX_A" -n "$DB_NS" scale statefulset/mariadb --replicas=2
  kubectl --context "$CTX_A" -n "$DB_NS" wait pod mariadb-2 --for=delete --timeout=120s

  run_pods_task "delete" "{\"namespace\":\"${DB_NS}\",\"target_pod\":\"mariadb-2\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$RESULT_REASON" "POD_ALREADY_DELETED"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.deleted')" "false"

  kubectl --context "$CTX_A" -n "$DB_NS" scale statefulset/mariadb --replicas="$STS_ORIGINAL_REPLICAS"
  STS_SCALED_DOWN=false
  kubectl --context "$CTX_A" -n "$NS" scale deployment mariadb-operator --replicas="$OPERATOR_ORIGINAL_REPLICAS"
  OPERATOR_SCALED_DOWN=false
  kubectl --context "$CTX_A" -n "$DB_NS" wait pod mariadb-2 --for=condition=Ready --timeout=180s
}

@test "pods/delete rejects a confirm whose pod_uid no longer matches a same-name replacement" {
  local stale_uid
  stale_uid=$(kubectl --context "$CTX_A" -n "$DB_NS" get pod mariadb-2 -o jsonpath='{.metadata.uid}')

  # Recreate mariadb-2 out from under that observation, independent of the
  # task under test, so its live UID no longer matches stale_uid —
  # simulating a retry issued after the instance already replaced it.
  kubectl --context "$CTX_A" -n "$DB_NS" delete pod mariadb-2 --wait=true --timeout=60s
  kubectl --context "$CTX_A" -n "$DB_NS" wait pod mariadb-2 --for=condition=Ready --timeout=180s
  local new_uid
  new_uid=$(kubectl --context "$CTX_A" -n "$DB_NS" get pod mariadb-2 -o jsonpath='{.metadata.uid}')
  assert_not_equal "$new_uid" "$stale_uid"

  run_pods_task "delete" "{\"namespace\":\"${DB_NS}\",\"target_pod\":\"mariadb-2\",\"dry_run\":\"false\",\"confirm\":\"true\",\"pod_uid\":\"${stale_uid}\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$RESULT_REASON" "POD_REPLACED"

  # The replacement Pod must survive the rejected delete untouched.
  local after_uid
  after_uid=$(kubectl --context "$CTX_A" -n "$DB_NS" get pod mariadb-2 -o jsonpath='{.metadata.uid}')
  assert_equal "$after_uid" "$new_uid"
}
