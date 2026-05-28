#!/usr/bin/env bats

setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token

  if [[ "${ENABLE_MINIO:-false}" != "true" ]]; then
    skip "MinIO not enabled (ENABLE_MINIO!=true)"
  fi

  # Deploy test databases for backup testing
  deploy_mariadb "mariadb-1"
  deploy_mongodb "mongo-1"
}

setup() {
  load '../test_helper/common_setup'
}

teardown_file() {
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" delete ns mariadb-1 --ignore-not-found
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" delete ns mongo-1 --ignore-not-found
}

@test "backup task is registered in aqsh-mariadb" {
  http_post "${MARIADB_AQSH_URL}/tasks" ''
  assert_equal "$HTTP_CODE" "200"

  run echo "$HTTP_BODY"
  assert_output --partial "backup"
}

@test "backup task is registered in aqsh-mongodb" {
  http_post "${MONGODB_AQSH_URL}/tasks" ''
  assert_equal "$HTTP_CODE" "200"

  run echo "$HTTP_BODY"
  assert_output --partial "backup"
}

@test "MariaDB backup task completes successfully" {
  http_post "${MARIADB_AQSH_URL}/tasks/backup" '{"namespace": "mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')

  wait_for_task "$MARIADB_AQSH_URL" "$task_id" 960

  local status namespace bucket
  status=$(echo "$TASK_RESPONSE" | jq -r '.status')
  namespace=$(echo "$TASK_RESPONSE" | jq -r '.result.namespace // empty')
  bucket=$(echo "$TASK_RESPONSE" | jq -r '.result.bucket // empty')

  echo "Task status: $status"
  echo "Namespace: $namespace"
  echo "Bucket: $bucket"

  assert_equal "$status" "completed"
  assert_equal "$namespace" "mariadb-1"
  assert_equal "$bucket" "db-backups"
}

@test "MongoDB backup task completes successfully" {
  http_post "${MONGODB_AQSH_URL}/tasks/backup" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')

  wait_for_task "$MONGODB_AQSH_URL" "$task_id" 960

  local status namespace bucket
  status=$(echo "$TASK_RESPONSE" | jq -r '.status')
  namespace=$(echo "$TASK_RESPONSE" | jq -r '.result.namespace // empty')
  bucket=$(echo "$TASK_RESPONSE" | jq -r '.result.bucket // empty')

  echo "Task status: $status"
  echo "Namespace: $namespace"
  echo "Bucket: $bucket"

  assert_equal "$status" "completed"
  assert_equal "$namespace" "mongo-1"
  assert_equal "$bucket" "db-backups"
}

@test "backup task with custom bucket works" {
  http_post "${MARIADB_AQSH_URL}/tasks/backup" '{"namespace": "mariadb-1", "minio_bucket": "test-backups"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')

  wait_for_task "$MARIADB_AQSH_URL" "$task_id" 960

  local bucket
  bucket=$(echo "$TASK_RESPONSE" | jq -r '.result.bucket // empty')

  assert_equal "$bucket" "test-backups"
}

@test "backup task returns size and timestamp" {
  http_post "${MONGODB_AQSH_URL}/tasks/backup" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')

  wait_for_task "$MONGODB_AQSH_URL" "$task_id" 960

  local size_bytes timestamp
  size_bytes=$(echo "$TASK_RESPONSE" | jq -r '.result.size_bytes // empty')
  timestamp=$(echo "$TASK_RESPONSE" | jq -r '.result.timestamp // empty')

  # Size should be greater than 0
  [[ -n "$size_bytes" && "$size_bytes" -gt 0 ]]

  # Timestamp should match YYYYMMDD-HHMMSS pattern
  [[ "$timestamp" =~ ^[0-9]{8}-[0-9]{6}$ ]]
}
