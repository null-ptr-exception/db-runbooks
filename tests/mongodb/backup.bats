#!/usr/bin/env bats

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"
  MINIO_ENDPOINT="http://minio.kind-b.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=2h)

  # Wait for MinIO to be ready on cluster-b
  kubectl --context "$CTX_B" -n minio rollout status deployment/minio --timeout=120s

  export CTX_A CTX_B NS AQSH_URL MINIO_ENDPOINT TEST_POD TOKEN
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
    [[ -z "$status" && -n "$TASK_RESPONSE" ]] && { echo "Task ${task_id} invalid response: ${TASK_RESPONSE}" >&2; return 1; }

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

# --- Tests ---

@test "backup task is registered" {
  local response
  response=$(kexec "curl -s --connect-timeout 5 -m 10 -w '\\n%{http_code}' \
    -H 'Authorization: Bearer ${TOKEN}' \
    '${AQSH_URL}/tasks'")
  local code body
  code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')
  assert_equal "$code" "200"

  run echo "$body"
  assert_output --partial "backup"
}

@test "backup completes successfully" {
  http_post "${AQSH_URL}/tasks/backup" \
    "{\"namespace\":\"mongo-1\",\"minio_endpoint\":\"${MINIO_ENDPOINT}\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result data
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  data=$(echo "$result" | jq -r '.data // empty')

  local status namespace bucket
  status=$(echo "$TASK_RESPONSE" | jq -r '.status')
  namespace=$(echo "$data" | jq -r '.namespace // empty')
  bucket=$(echo "$data" | jq -r '.bucket // empty')

  echo "Task status: $status, namespace: $namespace, bucket: $bucket"
  assert_equal "$status" "completed"
  assert_equal "$namespace" "mongo-1"
  assert_equal "$bucket" "db-backups"
}

@test "backup with custom bucket works" {
  http_post "${AQSH_URL}/tasks/backup" \
    "{\"namespace\":\"mongo-1\",\"minio_endpoint\":\"${MINIO_ENDPOINT}\",\"minio_bucket\":\"test-backups\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result data bucket
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  data=$(echo "$result" | jq -r '.data // empty')
  bucket=$(echo "$data" | jq -r '.bucket // empty')

  assert_equal "$bucket" "test-backups"
}

@test "backup returns size and timestamp" {
  http_post "${AQSH_URL}/tasks/backup" \
    "{\"namespace\":\"mongo-1\",\"minio_endpoint\":\"${MINIO_ENDPOINT}\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result data size_bytes timestamp
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  data=$(echo "$result" | jq -r '.data // empty')
  size_bytes=$(echo "$data" | jq -r '.size_bytes // empty')
  timestamp=$(echo "$data" | jq -r '.timestamp // empty')

  echo "size_bytes: $size_bytes, timestamp: $timestamp"
  [[ -n "$size_bytes" && "$size_bytes" -gt 0 ]]
  [[ "$timestamp" =~ ^[0-9]{8}-[0-9]{6}$ ]]
}
