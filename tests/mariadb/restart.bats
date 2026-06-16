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

K() {
  kubectl --context "$CTX_A" -n mariadb-1 "$@"
}

submit_restart() {
  http_post "${AQSH_URL}/tasks/restart" "$1"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"
}

pod_uids() {
  K get pods -l app.kubernetes.io/name=mariadb --sort-by=.metadata.name \
    -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}{"\n"}{end}'
}

restart_annotation() {
  K get mariadb mariadb -o json | jq -r '
    ((.spec.podMetadata.annotations // {}) + (.spec.inheritMetadata.annotations // {}))
    | to_entries[] | select(.key | test("restarted-at$")) | .value' | head -1
}

# --- Tests ---

@test "dry-run touches nothing on the cluster" {
  local before_uids
  before_uids=$(pod_uids)

  submit_restart '{"namespace": "mariadb-1"}'

  assert_equal "$(pod_uids)" "$before_uids"
}

@test "confirmed restart patches the CR and the operator rolls every pod" {
  local before_uids
  before_uids=$(pod_uids)

  submit_restart '{"namespace": "mariadb-1", "dry_run": "false", "confirm": "true"}'

  local annotation
  annotation=$(restart_annotation)
  echo "restart annotation on CR: '${annotation}'"
  assert [ -n "$annotation" ]

  K wait pod -l app.kubernetes.io/name=mariadb --for=condition=Ready --timeout=180s >/dev/null 2>&1

  local after_uids ready desired_replicas
  after_uids=$(pod_uids)
  echo "pod uids before:"; echo "$before_uids"
  echo "pod uids after:";  echo "$after_uids"
  assert_equal "$(printf '%s\n' "$after_uids" | wc -l | tr -d ' ')" "$(printf '%s\n' "$before_uids" | wc -l | tr -d ' ')"
  while IFS='=' read -r name uid; do
    local before_uid
    before_uid=$(printf '%s\n' "$before_uids" | awk -F= -v name="$name" '$1 == name { print $2 }')
    assert [ -n "$before_uid" ]
    assert_not_equal "$uid" "$before_uid"
  done <<< "$after_uids"

  ready=$(K get statefulset mariadb -o jsonpath='{.status.readyReplicas}')
  desired_replicas=$(K get statefulset mariadb -o jsonpath='{.spec.replicas}')
  echo "ready: ${ready}/${desired_replicas}"
  assert_equal "$ready" "$desired_replicas"
  assert [ "$ready" != "0" ]
}
