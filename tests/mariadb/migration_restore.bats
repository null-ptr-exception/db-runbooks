#!/usr/bin/env bats

setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  if [[ "${DB_MODE:-single}" == "dual" ]]; then
    deploy_mariadb_dual "mariadb-3"
  else
    deploy_mariadb "mariadb-3"
  fi
}

setup() {
  load '../test_helper/common_setup'
}

teardown_file() {
  if [[ "${DB_MODE:-single}" == "dual" ]]; then
    kubectl --context kind-cluster-dbs-a delete ns mariadb-3 --ignore-not-found
    kubectl --context kind-cluster-dbs-b delete ns mariadb-3 --ignore-not-found
  else
    kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" delete ns mariadb-3 --ignore-not-found
  fi
}

# Clean up any restore targets this suite created so later suites still see a
# clean namespace.
teardown() {
  if [[ -n "${RESTORE_TARGET:-}" ]]; then
    kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" \
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

  dry_run=$(echo "$data" | jq -r '.dryRun')
  restored=$(echo "$data" | jq -r '.restored')
  manifest=$(echo "$data" | jq -r '.manifest')

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
  prefix=$(echo "$data" | jq -r '.manifest | fromjson | .spec.bootstrapFrom.s3.prefix')

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
  image=$(echo "$data" | jq -r '.image')

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
  host=$(echo "$data" | jq -r '.connection.host')
  port=$(echo "$data" | jq -r '.connection.port')

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
    --arg ep "http://${CLUSTER_DBS_IP}:30083/minio" \
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
  message=$(echo "$TASK_RESPONSE" | jq -r '.result.message // empty')

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
  minio_endpoint="http://${CLUSTER_DBS_IP}:30083/minio"
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
  backup_file=$(echo "$backup_data" | jq -r '.backup.prefix + "/" + .backupName')
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

  restored=$(echo "$data" | jq -r '.restored')
  target=$(echo "$data" | jq -r '.target')

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
  dry_run=$(echo "$data" | jq -r '.dryRun')

  assert_equal "$dry_run" "true"
}
