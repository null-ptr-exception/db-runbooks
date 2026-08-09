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

assert_public_data_keys() {
  local data="$1" expected="$2"
  assert_equal "$(echo "$data" | jq -r 'keys | sort | join(",")')" "$expected"
}

assert_no_internal_result_keys() {
  local data="$1" leaked
  leaked=$(echo "$data" | jq -r '
    [.. | objects | keys[]]
    | map(select(
        . == "bucket" or . == "endpoint" or . == "prefix" or . == "path" or
        . == "location" or . == "secret" or . == "secretRef" or
        . == "credentialsRef" or . == "sourcePod" or . == "manifest" or
        . == "plan" or . == "operatorGroup" or . == "apiVersion" or
        . == "conditions"
      ))
    | unique | join(",")')
  assert_equal "$leaked" ""
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

  local status namespace
  status=$(echo "$TASK_RESPONSE" | jq -r '.status')
  namespace=$(echo "$data" | jq -r '.namespace // empty')

  echo "Task status: $status, namespace: $namespace"
  assert_equal "$status" "completed"
  assert_equal "$namespace" "mariadb-1"
  assert_equal "$(echo "$data" | jq -r '.created')" "true"
  assert_equal "$(echo "$data" | jq -r '.state')" "COMPLETED"
  assert_equal "$(echo "$data" | jq -r '.contentType')" "Logical"
  assert_public_data_keys "$data" "backupName,contentType,created,createdAt,namespace,sizeBytes,state"
  assert_no_internal_result_keys "$data"
}

@test "backup returns size and timestamp" {
  http_post "${AQSH_URL}/tasks/backup" \
    '{"namespace":"mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]] || { echo "missing task id in response: $HTTP_BODY" >&2; return 1; }
  wait_for_task "$AQSH_URL" "$task_id"

  local result data size_bytes created_at backup_name
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  data=$(echo "$result" | jq -r '.data // empty')
  size_bytes=$(echo "$data" | jq -r '.sizeBytes // empty')
  created_at=$(echo "$data" | jq -r '.createdAt // empty')
  backup_name=$(echo "$data" | jq -r '.backupName // empty')

  echo "sizeBytes: $size_bytes, createdAt: $created_at, backupName: $backup_name"
  [[ -n "$size_bytes" && "$size_bytes" -gt 0 ]]
  [[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  [[ "$backup_name" =~ ^logical-[0-9]{8}-[0-9]{6}\.sql\.gz$ ]]
  assert_public_data_keys "$data" "backupName,contentType,created,createdAt,namespace,sizeBytes,state"
  assert_no_internal_result_keys "$data"

  # stash this backup's object name for the list/delete round-trip below
  printf '%s\n' "$backup_name" > "${BATS_FILE_TMPDIR:-/tmp}/backup_e2e_name"
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
  assert_public_data_keys "$data" "backups,count,namespace"
  assert_equal "$(echo "$data" | jq -r '[.backups[] | keys | sort | join(",")] | unique | join(";")')" \
    "lastModified,name,sizeBytes"
  assert_no_internal_result_keys "$data"
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
  assert_equal "$(echo "$data" | jq -r '.state')" "DELETED"
  assert_public_data_keys "$data" "backup,deleted,dryRun,namespace,state"
  assert_no_internal_result_keys "$data"

  # and the listing must no longer contain it
  http_post "${AQSH_URL}/tasks/list-backups" '{"namespace":"mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$AQSH_URL" "$task_id"
  data=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty' | jq -r '.data // empty')
  assert_equal "$(echo "$data" | jq --arg n "$name" '[.backups[] | select(.name == $n)] | length')" "0"
}

@test "one AQSH isolates two workload-resolved backup prefixes" {
  local ref_a ref_b task_id data_a data_b name_a name_b listed
  ref_a=$(kubectl --context "$CTX_A" -n mariadb-1 get mariadb mariadb \
    -o jsonpath='{.spec.envFrom[0].secretRef.name}')
  ref_b=$(kubectl --context "$CTX_A" -n mariadb-2 get mariadb mariadb \
    -o jsonpath='{.spec.envFrom[0].secretRef.name}')
  [[ -n "$ref_a" && -n "$ref_b" && "$ref_a" != "$ref_b" ]]

  http_post "${AQSH_URL}/tasks/backup" '{"namespace":"mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$AQSH_URL" "$task_id"
  data_a=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty' | jq -c '.data // empty')
  name_a=$(echo "$data_a" | jq -r '.backupName')
  assert_public_data_keys "$data_a" "backupName,contentType,created,createdAt,namespace,sizeBytes,state"
  assert_no_internal_result_keys "$data_a"
  [[ "$TASK_RESPONSE" != *"$ref_a"* ]]
  [[ "$TASK_RESPONSE" != *"tenant-a/database"* ]]

  http_post "${AQSH_URL}/tasks/backup" '{"namespace":"mariadb-2"}'
  assert_equal "$HTTP_CODE" "202"
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$AQSH_URL" "$task_id"
  data_b=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty' | jq -c '.data // empty')
  name_b=$(echo "$data_b" | jq -r '.backupName')
  assert_public_data_keys "$data_b" "backupName,contentType,created,createdAt,namespace,sizeBytes,state"
  assert_no_internal_result_keys "$data_b"
  [[ "$TASK_RESPONSE" != *"$ref_b"* ]]
  [[ "$TASK_RESPONSE" != *"db-backups-secondary"* ]]
  [[ "$TASK_RESPONSE" != *"minio-secondary.kind-b.test"* ]]
  [[ "$TASK_RESPONSE" != *"tenant-b/database"* ]]

  http_post "${AQSH_URL}/tasks/list-backups" '{"namespace":"mariadb-1"}'
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$AQSH_URL" "$task_id"
  listed=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty' | jq -c '.data // empty')
  assert_public_data_keys "$listed" "backups,count,namespace"
  assert_no_internal_result_keys "$listed"
  assert_equal "$(echo "$listed" | jq --arg n "$name_a" '[.backups[] | select(.name == $n)] | length')" "1"
  assert_equal "$(echo "$listed" | jq --arg n "$name_b" '[.backups[] | select(.name == $n)] | length')" "0"

  http_post "${AQSH_URL}/tasks/list-backups" '{"namespace":"mariadb-2"}'
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$AQSH_URL" "$task_id"
  listed=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty' | jq -c '.data // empty')
  assert_public_data_keys "$listed" "backups,count,namespace"
  assert_no_internal_result_keys "$listed"
  assert_equal "$(echo "$listed" | jq --arg n "$name_b" '[.backups[] | select(.name == $n)] | length')" "1"
  assert_equal "$(echo "$listed" | jq --arg n "$name_a" '[.backups[] | select(.name == $n)] | length')" "0"
  [[ "$TASK_RESPONSE" != *"$ref_b"* ]]
  [[ "$TASK_RESPONSE" != *"db-backups-secondary"* ]]
  [[ "$TASK_RESPONSE" != *"minio-secondary.kind-b.test"* ]]
  [[ "$TASK_RESPONSE" != *"tenant-b/database"* ]]

  # Best-effort fixture cleanup; each delete remains scoped by its workload
  # prefix, exercising the same isolation on the mutating path.
  http_post "${AQSH_URL}/tasks/delete-backup" \
    "{\"namespace\":\"mariadb-1\",\"backup\":\"${name_a}\",\"dry_run\":\"false\",\"confirm\":\"true\"}"
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty'); wait_for_task "$AQSH_URL" "$task_id"
  http_post "${AQSH_URL}/tasks/delete-backup" \
    "{\"namespace\":\"mariadb-2\",\"backup\":\"${name_b}\",\"dry_run\":\"false\",\"confirm\":\"true\"}"
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty'); wait_for_task "$AQSH_URL" "$task_id"
}
