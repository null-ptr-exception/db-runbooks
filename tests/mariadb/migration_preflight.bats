#!/usr/bin/env bats

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load 'setup_suite'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="db-ops"
  MARIADB_AQSH_URL="http://aqsh-mariadb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  # Stand up a throwaway mariadb-3 instance on cluster-a (isolated from mariadb-1).
  deploy_throwaway_mariadb "mariadb-3" "$CTX_A" || return 1

  export CTX_A CTX_B NS MARIADB_AQSH_URL TEST_POD TOKEN
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

teardown_file() {
  load 'setup_suite'
  delete_namespace_and_wait "kind-cluster-a" "mariadb-3"
}

kexec() {
  kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"
}

http_post() {
  local url="$1" body="$2"
  local response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\\n%{http_code}' \
    -X POST '${url}' -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Content-Type: application/json' -d '${body}'")
  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

http_get() {
  local url="$1"
  local response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\\n%{http_code}' \
    -X GET '${url}' -H 'Authorization: Bearer ${TOKEN}'")
  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-540}"
  local elapsed=0 status
  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE
    status=$(echo "$TASK_RESPONSE" | jq -r '.status' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && { echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2; return 1; }
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

_preflight_result_data() {
  local task_response="$1"
  echo "$task_response" | jq -r \
    '(.result.data as $d | (($d | try fromjson catch null) // (if ($d | type) == "object" then $d else null end)))'
}

@test "migration-preflight task is registered in aqsh-mariadb" {
  http_get "${MARIADB_AQSH_URL}/tasks"
  assert_equal "$HTTP_CODE" "200"

  run echo "$HTTP_BODY"
  assert_output --partial "migration/preflight"
}

@test "migration-preflight PASS when only pod exec is checked (no MinIO endpoint)" {
  local payload
  payload=$(jq -nc '{namespace: "mariadb-3"}')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fpreflight" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data result_status
  data=$(_preflight_result_data "$TASK_RESPONSE")
  result_status=$(echo "$data" | jq -r '.status')

  echo "preflight result: ${data}" >&2
  # Without a minio endpoint the overall status is WARN (endpoint not provided)
  # but pod_exec must be PASS
  local pod_exec_status
  pod_exec_status=$(echo "$data" | jq -r '.checks[] | select(.name == "pod_exec") | .status')
  assert_equal "$pod_exec_status" "PASS"

  case "$result_status" in
    PASS|WARN) ;;
    *)
      echo "Unexpected preflight status: ${result_status}" >&2
      echo "$data" | jq -r '.checks[] | "check=" + .name + " status=" + .status + " reason=" + .reason_code' >&2
      return 1
      ;;
  esac
}

@test "migration-preflight target pod is populated in result" {
  local payload
  payload=$(jq -nc '{namespace: "mariadb-3"}')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fpreflight" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data pod
  data=$(_preflight_result_data "$TASK_RESPONSE")
  pod=$(echo "$data" | jq -r '.target.pod')

  [[ -n "$pod" && "$pod" != "null" ]]
}

@test "migration-preflight WARN check present when minio endpoint is omitted" {
  local payload
  payload=$(jq -nc '{namespace: "mariadb-3"}')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fpreflight" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data minio_reason
  data=$(_preflight_result_data "$TASK_RESPONSE")
  minio_reason=$(echo "$data" | jq -r '.checks[] | select(.name == "minio") | .reason_code')

  assert_equal "$minio_reason" "MINIO_ENDPOINT_NOT_PROVIDED"
}

@test "migration-preflight with unreachable minio endpoint returns BLOCK on minio_tcp" {
  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-3",
    minio_endpoint: "http://192.0.2.1:9000"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fpreflight" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data tcp_status
  data=$(_preflight_result_data "$TASK_RESPONSE")
  tcp_status=$(echo "$data" | jq -r '.checks[] | select(.name == "minio_tcp") | .status')

  echo "minio_tcp check: ${tcp_status}" >&2
  assert_equal "$tcp_status" "BLOCK"
}

@test "migration-preflight with minio endpoint includes minio checks in result" {
  if [[ "${ENABLE_MINIO:-false}" != "true" ]]; then
    skip "MinIO not enabled (ENABLE_MINIO!=true)"
  fi

  local payload
  payload=$(jq -nc --arg ep "http://minio.kind-b.test:30080" '{
    namespace: "mariadb-3",
    minio_endpoint: $ep,
    minio_access_key: "minioadmin",
    minio_secret_key: "minioadmin-changeme-prod",
    minio_bucket: "db-backups"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fpreflight" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data
  data=$(_preflight_result_data "$TASK_RESPONSE")
  echo "preflight result: ${data}" >&2

  local tcp_status auth_status
  tcp_status=$(echo "$data" | jq -r '.checks[] | select(.name == "minio_tcp") | .status')
  auth_status=$(echo "$data" | jq -r '.checks[] | select(.name == "minio_auth") | .status')

  assert_equal "$tcp_status" "PASS"
  assert_equal "$auth_status" "PASS"
}

@test "dual mode migration-preflight PASS on cluster-b" {
  if [[ "${DB_MODE:-single}" != "dual" ]]; then
    skip "DB_MODE is not dual"
  fi

  local payload
  payload=$(jq -nc '{namespace: "mariadb-3"}')

  http_post "$MARIADB_AQSH_B_URL/tasks/migration%2Fpreflight" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_B_URL" "$task_id"

  local data pod_exec_status
  data=$(_preflight_result_data "$TASK_RESPONSE")
  pod_exec_status=$(echo "$data" | jq -r '.checks[] | select(.name == "pod_exec") | .status')

  assert_equal "$pod_exec_status" "PASS"
}
