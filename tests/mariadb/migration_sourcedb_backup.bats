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

_sourcedb_backup_result_data() {
  local task_response="$1"
  echo "$task_response" | jq -r \
    '(.result.data as $d | (($d | try fromjson catch null) // (if ($d | type) == "object" then $d else null end)))'
}

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

@test "migration/sourcedb-backup task is registered in aqsh-mariadb" {
  http_get "${MARIADB_AQSH_URL}/tasks"
  assert_equal "$HTTP_CODE" "200"

  run echo "$HTTP_BODY"
  assert_output --partial "sourcedb-backup"
}

# ---------------------------------------------------------------------------
# Dry-run (no MinIO server needed, no confirm needed)
# ---------------------------------------------------------------------------

@test "migration/sourcedb-backup dry run renders manifest and returns dryRun=true" {
  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-3",
    minio_endpoint: "http://minio.example.test:9000",
    minio_access_key: "testkey",
    minio_secret_key: "testsecret",
    minio_bucket: "db-backups",
    dry_run: "true"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fsourcedb-backup" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data dry_run created manifest
  data=$(_sourcedb_backup_result_data "$TASK_RESPONSE")
  echo "result: ${data}" >&2

  dry_run=$(echo "$data" | jq -r '.data.dryRun')
  created=$(echo "$data" | jq -r '.data.created')
  manifest=$(echo "$data" | jq -r '.data.manifest')

  assert_equal "$dry_run" "true"
  assert_equal "$created" "false"
  assert [ "$manifest" != "null" ]
  assert [ -n "$manifest" ]
}

@test "migration/sourcedb-backup dry run result contains backup location fields" {
  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-3",
    minio_endpoint: "http://minio.example.test:9000",
    minio_access_key: "testkey",
    minio_secret_key: "testsecret",
    minio_bucket: "mybucket",
    dry_run: "true"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fsourcedb-backup" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data endpoint bucket prefix
  data=$(_sourcedb_backup_result_data "$TASK_RESPONSE")

  endpoint=$(echo "$data" | jq -r '.data.backup.endpoint')
  bucket=$(echo "$data" | jq -r '.data.backup.bucket')
  prefix=$(echo "$data" | jq -r '.data.backup.prefix')

  assert_equal "$endpoint" "http://minio.example.test:9000"
  assert_equal "$bucket" "mybucket"
  assert_equal "$prefix" "mariadb/mariadb-3"
}

# ---------------------------------------------------------------------------
# Security: minio_secret_key must not appear in the task response
# ---------------------------------------------------------------------------

@test "migration/sourcedb-backup dry run does not expose minio_secret_key in result" {
  local secret_sentinel="supersecret-sentinel-12345"
  local payload
  payload=$(jq -nc --arg sk "$secret_sentinel" '{
    namespace: "mariadb-3",
    minio_endpoint: "http://minio.example.test:9000",
    minio_access_key: "testkey",
    minio_secret_key: $sk,
    minio_bucket: "db-backups",
    dry_run: "true"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fsourcedb-backup" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  run echo "$TASK_RESPONSE"
  refute_output --partial "$secret_sentinel"
}

# ---------------------------------------------------------------------------
# Confirm gate: real run requires confirm=true
# ---------------------------------------------------------------------------

@test "migration/sourcedb-backup real run fails without confirm" {
  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-3",
    minio_endpoint: "http://minio.example.test:9000",
    minio_access_key: "testkey",
    minio_secret_key: "testsecret",
    minio_bucket: "db-backups",
    dry_run: "false",
    confirm: "false"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fsourcedb-backup" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id" || true

  local task_status
  task_status=$(echo "$TASK_RESPONSE" | jq -r '.status')
  assert_equal "$task_status" "failed"
}

# ---------------------------------------------------------------------------
# Full backup with real MinIO (gated — only when ENABLE_MINIO=true)
# ---------------------------------------------------------------------------

@test "migration/sourcedb-backup completes with real MinIO and secret key not in result" {
  if [[ "${ENABLE_MINIO:-false}" != "true" ]]; then
    skip "MinIO not enabled (ENABLE_MINIO!=true)"
  fi

  local minio_endpoint secret_key
  minio_endpoint="http://minio.kind-b.test:30080"
  secret_key="minioadmin-changeme-prod"

  local payload
  payload=$(jq -nc \
    --arg ep "$minio_endpoint" \
    --arg sk "$secret_key" \
    '{
      namespace: "mariadb-3",
      minio_endpoint: $ep,
      minio_access_key: "minioadmin",
      minio_secret_key: $sk,
      minio_bucket: "db-backups",
      dry_run: "false",
      confirm: "true",
      wait_timeout: "10m"
    }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fsourcedb-backup" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data created bucket
  data=$(_sourcedb_backup_result_data "$TASK_RESPONSE")
  echo "sourcedb-backup result: ${data}" >&2

  created=$(echo "$data" | jq -r '.data.created')
  bucket=$(echo "$data" | jq -r '.data.backup.bucket')

  assert_equal "$created" "true"
  assert_equal "$bucket" "db-backups"

  # Raw secret key must never appear anywhere in the task response
  run echo "$TASK_RESPONSE"
  refute_output --partial "$secret_key"
}

@test "dual mode migration/sourcedb-backup dry run PASS on cluster-b" {
  if [[ "${DB_MODE:-single}" != "dual" ]]; then
    skip "DB_MODE is not dual"
  fi

  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-3",
    minio_endpoint: "http://minio.example.test:9000",
    minio_access_key: "testkey",
    minio_secret_key: "testsecret",
    minio_bucket: "db-backups",
    dry_run: "true"
  }')

  http_post "${MARIADB_AQSH_B_URL}/tasks/migration%2Fsourcedb-backup" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_B_URL" "$task_id"

  local data dry_run
  data=$(_sourcedb_backup_result_data "$TASK_RESPONSE")
  dry_run=$(echo "$data" | jq -r '.data.dryRun')

  assert_equal "$dry_run" "true"
}
