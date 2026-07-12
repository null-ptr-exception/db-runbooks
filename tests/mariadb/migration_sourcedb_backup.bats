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

  dry_run=$(echo "$data" | jq -r '.dryRun')
  created=$(echo "$data" | jq -r '.created')
  manifest=$(echo "$data" | jq -r '.manifest')

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

  endpoint=$(echo "$data" | jq -r '.backup.endpoint')
  bucket=$(echo "$data" | jq -r '.backup.bucket')
  prefix=$(echo "$data" | jq -r '.backup.prefix')

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
  minio_endpoint="http://${CLUSTER_DBS_IP}:30083/minio"
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

  created=$(echo "$data" | jq -r '.created')
  bucket=$(echo "$data" | jq -r '.backup.bucket')

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
  dry_run=$(echo "$data" | jq -r '.dryRun')

  assert_equal "$dry_run" "true"
}
