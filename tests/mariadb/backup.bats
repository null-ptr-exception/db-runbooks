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

  # Wait for MinIO to be ready on cluster-b
  kubectl --context "$CTX_B" -n minio rollout status deployment/minio --timeout=120s

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
    '{"namespace":"mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]] || { echo "missing task id in response: $HTTP_BODY" >&2; return 1; }
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
  assert_equal "$namespace" "mariadb-1"
  assert_equal "$bucket" "db-backups"
}

@test "backup returns size and timestamp" {
  http_post "${AQSH_URL}/tasks/backup" \
    '{"namespace":"mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]] || { echo "missing task id in response: $HTTP_BODY" >&2; return 1; }
  wait_for_task "$AQSH_URL" "$task_id"

  local result data size_bytes timestamp
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  data=$(echo "$result" | jq -r '.data // empty')
  size_bytes=$(echo "$data" | jq -r '.size_bytes // empty')
  timestamp=$(echo "$data" | jq -r '.timestamp // empty')

  echo "size_bytes: $size_bytes, timestamp: $timestamp"
  [[ -n "$size_bytes" && "$size_bytes" -gt 0 ]]
  [[ "$timestamp" =~ ^[0-9]{8}-[0-9]{6}$ ]]

  # stash this backup's object name for the list/delete round-trip below
  echo "$data" | jq -r '.path' | awk -F/ '{print $NF}' > "${BATS_FILE_TMPDIR:-/tmp}/backup_e2e_name"
}

# The two tests below complete the snapshot-lifecycle round-trip on the REAL
# MinIO — they are what validates the s5cmd listing schema and the type-aware
# delete (#57), which unit mocks can only approximate.

@test "list-backups shows the uploaded backup (real s5cmd listing)" {
  local name; name="$(cat "${BATS_FILE_TMPDIR:-/tmp}/backup_e2e_name")"
  [[ -n "$name" ]]

  http_post "${AQSH_URL}/tasks/list-backups" '{"namespace":"mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"
  local task_id; task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$AQSH_URL" "$task_id"

  local data; data=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty' | jq -r '.data // empty')
  echo "list result: $(echo "$data" | jq -c '{count, names: [.backups[].name]}')"
  # the backup created above must be listed, with a real lastModified
  assert_equal "$(echo "$data" | jq --arg n "$name" '[.backups[] | select(.name == $n)] | length')" "1"
  [[ "$(echo "$data" | jq -r --arg n "$name" '.backups[] | select(.name == $n) | .lastModified')" != "null" ]]
}

@test "delete-backup removes the backup and list no longer shows it" {
  local name; name="$(cat "${BATS_FILE_TMPDIR:-/tmp}/backup_e2e_name")"
  [[ -n "$name" ]]

  http_post "${AQSH_URL}/tasks/delete-backup" \
    "{\"namespace\":\"mariadb-1\",\"backup\":\"${name}\",\"dry_run\":\"false\",\"confirm\":\"true\"}"
  assert_equal "$HTTP_CODE" "202"
  local task_id; task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$AQSH_URL" "$task_id"
  local data; data=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty' | jq -r '.data // empty')
  assert_equal "$(echo "$data" | jq -r '.deleted')" "true"

  # and the listing must no longer contain it
  http_post "${AQSH_URL}/tasks/list-backups" '{"namespace":"mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$AQSH_URL" "$task_id"
  data=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty' | jq -r '.data // empty')
  assert_equal "$(echo "$data" | jq --arg n "$name" '[.backups[] | select(.name == $n)] | length')" "0"
}
