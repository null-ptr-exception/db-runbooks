#!/usr/bin/env bats
# =============================================================================
# E2E for the pbm/* task family (docs/mongodb/pbm.md) against an
# official-convention 2-member replica set with pbm-agent sidecars, in its
# own namespace (mongo-pbm — mongo-1 is only used as the agent-less negative
# fixture and is never mutated).
#
# Covers: fresh-deployment status (storage unconfigured), physical-type
# rejection, logical backup with storage auto-ensure + the artifact actually
# landing in MinIO (cluster-b), list/describe, config in-sync no-op,
# the drop -> dry-run -> confirm -> data-back restore round trip, XOR input
# validation, delete dry-run/confirm, and the NO_PBM_AGENT error path.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load 'pbm_helpers'

  SNS="mongo-pbm"
  export SNS

  _pbm_common_env
  _pbm_apply_fixture "$SNS" "official"
}

teardown_file() {
  kubectl --context "kind-cluster-a" delete namespace "mongo-pbm" \
    --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load 'pbm_helpers'
}

@test "pbm/status on a fresh deployment: agents registered, storage unconfigured, pitr off" {
  run_pbm_task "status" "{\"namespace\":\"${SNS}\"}"
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.sts')" "mongodb"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.agent_container')" "pbm-agent"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '[.agents[].nodes[]] | length')" "2"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.storage.configured')" "false"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.pitr.enabled')" "false"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.storage.resolved.bucket')" "db-backups"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.storage.resolved.prefix')" "mongodb/${SNS}"
}

@test "pbm/backup type=physical on a community-engine deployment fails PSMDB_REQUIRED" {
  # This fixture runs vanilla mongo:7 — no $backupCursor. The live engine
  # gate must catch it and name the detected engine.
  run_pbm_task "backup" "{\"namespace\":\"${SNS}\",\"type\":\"physical\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "PSMDB_REQUIRED"
  echo "$RESULT_DATA" | jq -r '.details.engine' | grep -q "^community:"
  echo "$RESULT_DATA" | jq -r '.details.hint' | grep -qi "percona-server-mongodb"
}

@test "pbm/backup type=external stays rejected" {
  run_pbm_task "backup" "{\"namespace\":\"${SNS}\",\"type\":\"external\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "UNSUPPORTED_BACKUP_TYPE"
}

@test "pbm/backup runs a logical backup, auto-ensures storage, and the artifact lands in MinIO" {
  _pbm_mongo_eval "$SNS" "
    var c = db.getSiblingDB('e2e').orders;
    c.drop();
    c.insertMany([{_id:1,v:'a'},{_id:2,v:'b'},{_id:3,v:'c'}]);
    print('seeded: ' + c.countDocuments({}));"

  run_pbm_task "backup" "{\"namespace\":\"${SNS}\"}" 600
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.status')" "done"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.type')" "logical"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.storage.bucket')" "db-backups"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.storage.prefix')" "mongodb/${SNS}"

  local backup_name
  backup_name=$(echo "$RESULT_DATA" | jq -r '.backup_name')
  [[ -n "$backup_name" && "$backup_name" != "null" ]]
  echo "$backup_name" > "${BATS_FILE_TMPDIR}/backup_name"

  # The user-visible proof: the backup object graph actually exists in MinIO
  # on cluster-b under db-backups/mongodb/<ns>/.
  run _pbm_minio_ls "mongodb/${SNS}"
  assert_success
  echo "MinIO contents under mongodb/${SNS}: $output"
}

@test "pbm/list shows the backup; name= returns describe-backup detail" {
  local backup_name
  backup_name=$(cat "${BATS_FILE_TMPDIR}/backup_name")

  run_pbm_task "list" "{\"namespace\":\"${SNS}\"}"
  assert_equal "$TASK_STATUS" "completed"
  echo "$RESULT_DATA" | jq -e --arg n "$backup_name" \
    '[.snapshots[] | select(.name == $n and .status == "done")] | length == 1'

  run_pbm_task "list" "{\"namespace\":\"${SNS}\",\"name\":\"${backup_name}\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.backup.status')" "done"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.backup.type')" "logical"
}

@test "pbm/config dry-run reports in-sync after the auto-ensure; confirm is an already-in-sync no-op" {
  run_pbm_task "config" "{\"namespace\":\"${SNS}\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.dry_run')" "true"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.storage.in_sync')" "true"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.action')" "none"

  run_pbm_task "config" "{\"namespace\":\"${SNS}\",\"dry_run\":\"false\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.applied')" "false"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason')" "already-in-sync"
}

@test "restore round trip: drop -> dry-run changes nothing -> confirm brings the data back" {
  local backup_name
  backup_name=$(cat "${BATS_FILE_TMPDIR}/backup_name")

  _pbm_mongo_eval "$SNS" "db.getSiblingDB('e2e').orders.drop(); print('dropped');"
  local count
  count=$(_pbm_mongo_eval "$SNS" "print(db.getSiblingDB('e2e').orders.countDocuments({}))" | tail -1 | tr -d '\r')
  assert_equal "$count" "0"

  run_pbm_task "restore" "{\"namespace\":\"${SNS}\",\"backup_name\":\"${backup_name}\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.dry_run')" "true"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.would_restore.backup_name')" "$backup_name"
  # dry-run must not have touched the data
  count=$(_pbm_mongo_eval "$SNS" "print(db.getSiblingDB('e2e').orders.countDocuments({}))" | tail -1 | tr -d '\r')
  assert_equal "$count" "0"

  run_pbm_task "restore" \
    "{\"namespace\":\"${SNS}\",\"backup_name\":\"${backup_name}\",\"dry_run\":\"false\",\"confirm\":\"true\"}" 900
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.status')" "done"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.pitr_was_enabled')" "false"

  count=$(_pbm_mongo_eval "$SNS" "print(db.getSiblingDB('e2e').orders.countDocuments({}))" | tail -1 | tr -d '\r')
  assert_equal "$count" "3"
}

@test "pbm/restore rejects both and neither of backup_name/time" {
  run_pbm_task "restore" \
    "{\"namespace\":\"${SNS}\",\"backup_name\":\"2026-01-01T00:00:00Z\",\"time\":\"2026-01-01T00:00:00\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"

  run_pbm_task "restore" "{\"namespace\":\"${SNS}\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"
}

@test "pbm/delete dry-run previews, confirm removes the backup from the inventory" {
  local backup_name
  backup_name=$(cat "${BATS_FILE_TMPDIR}/backup_name")

  run_pbm_task "delete" "{\"namespace\":\"${SNS}\",\"backup_name\":\"${backup_name}\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.dry_run')" "true"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.would_delete | length')" "1"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.would_delete[0].name')" "$backup_name"

  run_pbm_task "delete" \
    "{\"namespace\":\"${SNS}\",\"backup_name\":\"${backup_name}\",\"dry_run\":\"false\",\"confirm\":\"true\"}" 600
  assert_equal "$TASK_STATUS" "completed"

  run_pbm_task "list" "{\"namespace\":\"${SNS}\"}"
  assert_equal "$TASK_STATUS" "completed"
  echo "$RESULT_DATA" | jq -e --arg n "$backup_name" \
    '[.snapshots[]? | select(.name == $n)] | length == 0'
}

@test "pbm/delete of an unknown backup fails BACKUP_NOT_FOUND" {
  run_pbm_task "delete" "{\"namespace\":\"${SNS}\",\"backup_name\":\"2020-01-01T00:00:00Z\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "BACKUP_NOT_FOUND"
}

@test "namespace without a pbm-agent sidecar fails NO_PBM_AGENT with actionable guidance" {
  # mongo-1 is the chart's plain mongo deployment — no sidecar, read-only use.
  run_pbm_task "status" '{"namespace":"mongo-1"}'
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "NO_PBM_AGENT"
  echo "$RESULT_DATA" | jq -r '.details.hint' | grep -q "sidecar"

  run_pbm_task "backup" '{"namespace":"mongo-1"}'
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "NO_PBM_AGENT"
}
