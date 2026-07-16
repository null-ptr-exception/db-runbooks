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

# Clean up any restore targets this suite created so later suites still see a
# clean namespace.
teardown() {
  if [[ -n "${RESTORE_TARGET:-}" ]]; then
    kubectl --context kind-cluster-a \
      -n mariadb-3 delete mariadb "$RESTORE_TARGET" --ignore-not-found >/dev/null 2>&1 || true
    unset RESTORE_TARGET
  fi
}

_restore_result_data() {
  local task_response="$1"
  echo "$task_response" | jq -r \
    '(.result.data as $d | (($d | try fromjson catch null) // (if ($d | type) == "object" then $d else null end)))'
}

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

@test "migration/restore task is registered in aqsh-mariadb" {
  http_get "${MARIADB_AQSH_URL}/tasks"
  assert_equal "$HTTP_CODE" "200"

  run echo "$HTTP_BODY"
  assert_output --partial "migration/restore"
}

# ---------------------------------------------------------------------------
# Dry run (no MinIO server needed, no confirm needed)
# ---------------------------------------------------------------------------

@test "migration/restore dry run renders manifest and returns dryRun=true" {
  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-3",
    backup_file: "mariadb/mariadb-3/mariadb-migration-20260712000000",
    minio_endpoint: "http://minio.example.test:9000",
    minio_access_key: "testkey",
    minio_secret_key: "testsecret",
    minio_bucket: "db-backups",
    image: "mariadb:11.4",
    storage_size: "1Gi",
    dry_run: "true"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Frestore" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]]
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data dry_run restored manifest
  data=$(_restore_result_data "$TASK_RESPONSE")
  echo "result: ${data}" >&2

  dry_run=$(echo "$data" | jq -r '.data.dryRun')
  restored=$(echo "$data" | jq -r '.data.restored')
  manifest=$(echo "$data" | jq -r '.data.manifest')

  assert_equal "$dry_run" "true"
  assert_equal "$restored" "false"
  assert [ "$manifest" != "null" ]
  assert [ -n "$manifest" ]
}

@test "migration/restore dry run backup_file is reflected in bootstrapFrom.s3.prefix" {
  local backup_path="mariadb/mariadb-3/mariadb-migration-20260712000000"
  local payload
  payload=$(jq -nc --arg bf "$backup_path" '{
    namespace: "mariadb-3",
    backup_file: $bf,
    minio_endpoint: "http://minio.example.test:9000",
    minio_access_key: "testkey",
    minio_secret_key: "testsecret",
    minio_bucket: "db-backups",
    image: "mariadb:11.4",
    storage_size: "1Gi",
    dry_run: "true"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Frestore" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data prefix
  data=$(_restore_result_data "$TASK_RESPONSE")
  prefix=$(echo "$data" | jq -r '.data.manifest | fromjson | .spec.bootstrapFrom.s3.prefix')

  assert_equal "$prefix" "$backup_path"
}

@test "migration/restore dry run image auto-detected from existing instance when not provided" {
  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-3",
    backup_file: "mariadb/mariadb-3/mariadb-migration-20260712000000",
    minio_endpoint: "http://minio.example.test:9000",
    minio_access_key: "testkey",
    minio_secret_key: "testsecret",
    minio_bucket: "db-backups",
    storage_size: "1Gi",
    dry_run: "true"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Frestore" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data image
  data=$(_restore_result_data "$TASK_RESPONSE")
  image=$(echo "$data" | jq -r '.data.image')

  # The mariadb-3 instance was deployed by setup_file; image should be non-empty.
  echo "detected image: ${image}" >&2
  assert [ -n "$image" ]
  assert [ "$image" != "null" ]
}

@test "migration/restore dry run returns connection endpoint" {
  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-3",
    backup_file: "mariadb/mariadb-3/mariadb-migration-20260712000000",
    minio_endpoint: "http://minio.example.test:9000",
    minio_access_key: "testkey",
    minio_secret_key: "testsecret",
    minio_bucket: "db-backups",
    image: "mariadb:11.4",
    storage_size: "1Gi",
    target: "mariadb-3-migrated",
    dry_run: "true"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Frestore" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local data host port
  data=$(_restore_result_data "$TASK_RESPONSE")
  host=$(echo "$data" | jq -r '.data.connection.host')
  port=$(echo "$data" | jq -r '.data.connection.port')

  assert_equal "$host" "mariadb-3-migrated-primary.mariadb-3.svc.cluster.local"
  assert_equal "$port" "3306"
}

# ---------------------------------------------------------------------------
# Security: minio_secret_key must not appear in the task response
# ---------------------------------------------------------------------------

@test "migration/restore dry run does not expose minio_secret_key in result" {
  local secret_sentinel="m1gr4t10n-secret-sentinel-xyz"
  local payload
  payload=$(jq -nc --arg sk "$secret_sentinel" '{
    namespace: "mariadb-3",
    backup_file: "mariadb/mariadb-3/mariadb-migration-20260712000000",
    minio_endpoint: "http://minio.example.test:9000",
    minio_access_key: "testkey",
    minio_secret_key: $sk,
    minio_bucket: "db-backups",
    image: "mariadb:11.4",
    storage_size: "1Gi",
    dry_run: "true"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Frestore" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  run echo "$TASK_RESPONSE"
  refute_output --partial "$secret_sentinel"
}

# ---------------------------------------------------------------------------
# Confirm gate
# ---------------------------------------------------------------------------

@test "migration/restore real run fails without confirm" {
  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-3",
    backup_file: "mariadb/mariadb-3/mariadb-migration-20260712000000",
    minio_endpoint: "http://minio.example.test:9000",
    minio_access_key: "testkey",
    minio_secret_key: "testsecret",
    minio_bucket: "db-backups",
    image: "mariadb:11.4",
    storage_size: "1Gi",
    dry_run: "false",
    confirm: "false"
  }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Frestore" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id" || true

  local task_status
  task_status=$(echo "$TASK_RESPONSE" | jq -r '.status')
  assert_equal "$task_status" "failed"
}

# ---------------------------------------------------------------------------
# Backup not found error
# ---------------------------------------------------------------------------

@test "migration/restore fails with clear error when backup_file does not exist in MinIO" {
  if [[ "${ENABLE_MINIO:-false}" != "true" ]]; then
    skip "MinIO not enabled (ENABLE_MINIO!=true)"
  fi

  local payload
  payload=$(jq -nc \
    --arg ep "http://minio.kind-b.test:30080" \
    '{
      namespace: "mariadb-3",
      backup_file: "mariadb/mariadb-3/nonexistent-backup-99999999999999",
      minio_endpoint: $ep,
      minio_access_key: "minioadmin",
      minio_secret_key: "minioadmin-changeme-prod",
      minio_bucket: "db-backups",
      image: "mariadb:11.4",
      storage_size: "1Gi",
      dry_run: "false",
      confirm: "true"
    }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Frestore" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id" || true

  local data message
  data=$(_restore_result_data "$TASK_RESPONSE")
  message=$(echo "$data" | jq -r '.message // empty')

  echo "error result: ${data}" >&2
  run echo "$message"
  assert_output --partial "backup not found"
}

# ---------------------------------------------------------------------------
# Full restore round-trip (gated — only when ENABLE_MINIO=true)
# ---------------------------------------------------------------------------

@test "migration/restore completes from a real backup and secret key not in result" {
  if [[ "${ENABLE_MINIO:-false}" != "true" ]]; then
    skip "MinIO not enabled (ENABLE_MINIO!=true)"
  fi

  local minio_endpoint secret_key
  minio_endpoint="http://minio.kind-b.test:30080"
  secret_key="minioadmin-changeme-prod"

  # Step 1: Run migration/sourcedb-backup to create the backup we will restore.
  local backup_payload
  backup_payload=$(jq -nc \
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

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fsourcedb-backup" "$backup_payload"
  assert_equal "$HTTP_CODE" "202"

  local backup_task_id
  backup_task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$backup_task_id"

  local backup_data backup_file
  backup_data=$(_restore_result_data "$TASK_RESPONSE")
  backup_file=$(echo "$backup_data" | jq -r '.data.backup.prefix + "/" + .data.backupName')
  echo "backup_file for restore: ${backup_file}" >&2
  [[ -n "$backup_file" && "$backup_file" != "null/null" ]]

  # Step 2: Restore from that specific backup.
  local restore_payload
  restore_payload=$(jq -nc \
    --arg ep "$minio_endpoint" \
    --arg sk "$secret_key" \
    --arg bf "$backup_file" \
    '{
      namespace: "mariadb-3",
      backup_file: $bf,
      minio_endpoint: $ep,
      minio_access_key: "minioadmin",
      minio_secret_key: $sk,
      minio_bucket: "db-backups",
      storage_size: "1Gi",
      dry_run: "false",
      confirm: "true",
      wait_timeout: "10m"
    }')

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Frestore" "$restore_payload"
  assert_equal "$HTTP_CODE" "202"

  local restore_task_id
  restore_task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$restore_task_id" 960

  local data restored target
  data=$(_restore_result_data "$TASK_RESPONSE")
  echo "restore result: ${data}" >&2

  restored=$(echo "$data" | jq -r '.data.restored')
  target=$(echo "$data" | jq -r '.data.target')

  assert_equal "$restored" "true"
  [[ -n "$target" && "$target" != "null" ]]
  export RESTORE_TARGET="$target"

  # Raw secret key must never appear anywhere in the response.
  run echo "$TASK_RESPONSE"
  refute_output --partial "$secret_key"
}

# ---------------------------------------------------------------------------
# Dual-mode
# ---------------------------------------------------------------------------

@test "dual mode migration/restore dry run PASS on cluster-b" {
  if [[ "${DB_MODE:-single}" != "dual" ]]; then
    skip "DB_MODE is not dual"
  fi

  local payload
  payload=$(jq -nc '{
    namespace: "mariadb-3",
    backup_file: "mariadb/mariadb-3/mariadb-migration-20260712000000",
    minio_endpoint: "http://minio.example.test:9000",
    minio_access_key: "testkey",
    minio_secret_key: "testsecret",
    minio_bucket: "db-backups",
    image: "mariadb:11.4",
    storage_size: "1Gi",
    dry_run: "true"
  }')

  http_post "${MARIADB_AQSH_B_URL}/tasks/migration%2Frestore" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_B_URL" "$task_id"

  local data dry_run
  data=$(_restore_result_data "$TASK_RESPONSE")
  dry_run=$(echo "$data" | jq -r '.data.dryRun')

  assert_equal "$dry_run" "true"
}
