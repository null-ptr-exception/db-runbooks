#!/usr/bin/env bats
# =============================================================================
# E2E for the PBM PITR lifecycle (docs/mongodb/pbm.md) in its own namespace
# (mongo-pbm-pitr) — timing-sensitive, so it never shares state with
# pbm.bats: NO_BASE_BACKUP guard, enable with a 1-minute oplog span,
# point-in-time restore that keeps marker A (written before T1) and drops
# marker B (written after), the PITR-disabled-after-restore contract, and
# re-arming coverage with a fresh base backup.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load 'pbm_helpers'

  SNS="mongo-pbm-pitr"
  export SNS

  _pbm_common_env
  _pbm_apply_fixture "$SNS" "official"
}

teardown_file() {
  kubectl --context "kind-cluster-a" delete namespace "mongo-pbm-pitr" \
    --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load 'pbm_helpers'
}

# Poll pbm status (direct sidecar exec — test-side verification) until a
# PITR chunk covers the given epoch.
_wait_pitr_covers() {
  local epoch="$1" max_wait="${2:-300}"
  local elapsed=0
  while (( elapsed < max_wait )); do
    if _pbm_agent_exec "$SNS" status -o json 2>/dev/null \
        | jq -e --argjson t "$epoch" \
          '[.backups.pitrChunks.pitrChunks[]? | select(.range.start <= $t and .range.end >= $t)] | length > 0' \
          >/dev/null 2>&1; then
      return 0
    fi
    sleep 10; elapsed=$((elapsed + 10))
  done
  echo "no PITR chunk covering epoch ${epoch} after ${max_wait}s" >&2
  return 1
}

@test "pbm/pitr enable without a base backup: dry-run predicts NO_BASE_BACKUP, confirm fails with it" {
  run_pbm_task "pitr" "{\"namespace\":\"${SNS}\",\"enabled\":\"true\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.would_fail')" "NO_BASE_BACKUP"

  run_pbm_task "pitr" "{\"namespace\":\"${SNS}\",\"enabled\":\"true\",\"dry_run\":\"false\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "NO_BASE_BACKUP"
}

@test "base backup then pbm/pitr enable with a 1-minute oplog span" {
  _pbm_mongo_eval "$SNS" "
    var c = db.getSiblingDB('e2e').pitr;
    c.drop();
    print('collection reset');"

  run_pbm_task "backup" "{\"namespace\":\"${SNS}\"}" 600
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.status')" "done"
  echo "$RESULT_DATA" | jq -r '.backup_name' > "${BATS_FILE_TMPDIR}/base_backup"

  run_pbm_task "pitr" "{\"namespace\":\"${SNS}\",\"enabled\":\"true\",\"oplog_span_min\":\"1\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.would_fail')" "null"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.would_change')" "true"

  run_pbm_task "pitr" \
    "{\"namespace\":\"${SNS}\",\"enabled\":\"true\",\"oplog_span_min\":\"1\",\"dry_run\":\"false\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.pitr.enabled')" "true"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.pitr.oplog_span_min')" "1"
}

@test "point-in-time restore keeps marker A (before T1) and drops marker B (after T1)" {
  _pbm_mongo_eval "$SNS" "db.getSiblingDB('e2e').pitr.insertOne({m:'A'}); print('A written');"
  sleep 3

  # T1 from the server's own clock: epoch for coverage checks, ISO (UTC,
  # second precision, no Z — pbm restore --time format) for the API call.
  local t1_line t1_epoch t1_iso
  t1_line=$(_pbm_mongo_eval "$SNS" \
    "print('T1|' + Math.floor(Date.now()/1000) + '|' + new Date().toISOString().slice(0,19));" \
    | grep '^T1|' | tail -1 | tr -d '\r')
  t1_epoch=$(echo "$t1_line" | cut -d'|' -f2)
  t1_iso=$(echo "$t1_line" | cut -d'|' -f3)
  [[ -n "$t1_epoch" && -n "$t1_iso" ]]
  echo "restore point T1: epoch=${t1_epoch} iso=${t1_iso}"

  sleep 3
  _pbm_mongo_eval "$SNS" "db.getSiblingDB('e2e').pitr.insertOne({m:'B'}); print('B written');"

  # Wait until slicing has flushed a chunk covering T1 (span is 1 minute).
  _wait_pitr_covers "$t1_epoch" 300

  run_pbm_task "restore" \
    "{\"namespace\":\"${SNS}\",\"time\":\"${t1_iso}\",\"dry_run\":\"false\",\"confirm\":\"true\"}" 900
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.status')" "done"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.restored.mode')" "pitr"
  # the PITR-disabled-after-restore contract
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.pitr_was_enabled')" "true"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.pitr_enabled_now')" "false"
  echo "$RESULT_DATA" | jq -r '.post_restore_required' | grep -q "pbm/backup"

  local count_a count_b
  count_a=$(_pbm_mongo_eval "$SNS" "print(db.getSiblingDB('e2e').pitr.countDocuments({m:'A'}))" | tail -1 | tr -d '\r')
  count_b=$(_pbm_mongo_eval "$SNS" "print(db.getSiblingDB('e2e').pitr.countDocuments({m:'B'}))" | tail -1 | tr -d '\r')
  assert_equal "$count_a" "1"
  assert_equal "$count_b" "0"
}

@test "pbm/status confirms PITR is off after the restore" {
  run_pbm_task "status" "{\"namespace\":\"${SNS}\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.pitr.enabled')" "false"
}

@test "fresh base backup re-arms PITR" {
  run_pbm_task "backup" "{\"namespace\":\"${SNS}\"}" 600
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.status')" "done"

  run_pbm_task "pitr" \
    "{\"namespace\":\"${SNS}\",\"enabled\":\"true\",\"dry_run\":\"false\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.pitr.enabled')" "true"
}
