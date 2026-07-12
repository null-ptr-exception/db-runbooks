#!/usr/bin/env bats
# =============================================================================
# E2E for PBM physical/incremental backups and the full-downtime physical
# restore takeover (docs/mongodb/pbm.md#physical-restore), in its own
# namespace (mongo-pbm-phys). Fixture: official-convention 2-member replica
# set on Percona Server for MongoDB with REAL authentication (--auth +
# keyFile — the agent's PBM_MONGODB_URI credentials are actually verified)
# and the agent sidecar sharing the data volume.
#
# Covers: physical readiness in status; physical backup with the artifact
# in MinIO; the incremental chain (auto --base) and its delete protection;
# the takeover restore round trip incl. the surgical StatefulSet revert;
# restore from the incremental chain tip; PITR on a physical base with a
# point-in-time takeover restore; and a post-restore backup that proves the
# metadata resync.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load 'pbm_helpers'

  SNS="mongo-pbm-phys"
  MONGO_USER="mongoadmin"
  MONGO_PASS="testpass123"
  export SNS MONGO_USER MONGO_PASS

  _pbm_common_env
  _pbm_apply_fixture "$SNS" "official" "psmdb"
}

teardown_file() {
  kubectl --context "kind-cluster-a" delete namespace "mongo-pbm-phys" \
    --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load 'pbm_helpers'
}

_eval() { _pbm_mongo_eval_auth "$SNS" "$MONGO_USER" "$MONGO_PASS" "$1"; }

_count() {
  local coll="$1" filter="${2:-}"
  [[ -z "$filter" ]] && filter='{}'
  _eval "print(db.getSiblingDB('e2e').${coll}.countDocuments(${filter}))" | tail -1 | tr -d '\r'
}

_sts_json() {
  kubectl --context "$CTX_A" -n "$SNS" get sts mongodb -o json
}

_assert_sts_reverted() {
  local sts
  sts=$(_sts_json)
  assert_equal "$(jq -r '.metadata.annotations["pbm-restore/auto-patched"] // "absent"' <<< "$sts")" "absent"
  assert_equal "$(jq -r '.spec.template.spec.containers[] | select(.name=="mongodb") | (.readinessProbe != null)' <<< "$sts")" "true"
  # the parked sidecar must be back on its real command
  local agent_cmd
  agent_cmd=$(jq -r '.spec.template.spec.containers[] | select(.name=="pbm-agent") | (.command // []) | join(" ")' <<< "$sts")
  [[ "$agent_cmd" == *"pbm-agent"* ]]
  [[ "$agent_cmd" != *"sleep infinity"* ]]
  assert_equal "$(jq -r '[.spec.template.spec.initContainers[]? | select(.name=="pbm-binaries")] | length' <<< "$sts")" "0"
}

@test "pbm/status reports physical readiness on the PSMDB fixture" {
  run_pbm_task "status" "{\"namespace\":\"${SNS}\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.physical_ready.psmdb')" "true"
  echo "$RESULT_DATA" | jq -r '.physical_ready.engine' | grep -q '^psmdb:'
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.physical_ready.agent_data_volume')" "true"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.physical_restore_in_progress')" "false"
}

@test "physical backup completes and the artifact lands in MinIO" {
  _eval "
    var c = db.getSiblingDB('e2e').orders;
    c.drop();
    c.insertMany([{_id:1,v:'a'},{_id:2,v:'b'},{_id:3,v:'c'}]);
    print('seeded: ' + c.countDocuments({}));"

  run_pbm_task "backup" "{\"namespace\":\"${SNS}\",\"type\":\"physical\"}" 900
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.status')" "done"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.type')" "physical"
  echo "$RESULT_DATA" | jq -r '.restore_note' | grep -qi "offline"

  echo "$RESULT_DATA" | jq -r '.backup_name' > "${BATS_FILE_TMPDIR}/phys_base"

  run _pbm_minio_ls "mongodb/${SNS}"
  assert_success
}

@test "incremental chain: first backup auto-becomes the base, second extends it" {
  _eval "db.getSiblingDB('e2e').incr.insertOne({step:1}); print('incr step 1');"

  run_pbm_task "backup" "{\"namespace\":\"${SNS}\",\"type\":\"incremental\"}" 900
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.status')" "done"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.incremental_base')" "true"
  echo "$RESULT_DATA" | jq -r '.backup_name' > "${BATS_FILE_TMPDIR}/incr_base"

  _eval "db.getSiblingDB('e2e').incr.insertOne({step:2}); print('incr step 2');"

  run_pbm_task "backup" "{\"namespace\":\"${SNS}\",\"type\":\"incremental\"}" 900
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.status')" "done"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.incremental_base')" "false"
  echo "$RESULT_DATA" | jq -r '.backup_name' > "${BATS_FILE_TMPDIR}/incr_tip"

  run_pbm_task "list" "{\"namespace\":\"${SNS}\"}"
  assert_equal "$TASK_STATUS" "completed"
  echo "$RESULT_DATA" | jq -e \
    '[.snapshots[] | select(.type == "incremental" and .status == "done")] | length >= 2'
}

@test "physical restore round trip: takeover, full-cluster restore, surgical revert" {
  local base
  base=$(cat "${BATS_FILE_TMPDIR}/phys_base")

  # Wreck the data: drop the backed-up collection AND note that e2e.incr
  # (created AFTER the physical base) must vanish when we roll back to it.
  _eval "db.getSiblingDB('e2e').orders.drop(); print('orders dropped');"
  assert_equal "$(_count orders)" "0"

  run_pbm_task "restore" "{\"namespace\":\"${SNS}\",\"backup_name\":\"${base}\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.dry_run')" "true"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.restore_flavor')" "physical"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.downtime')" "true"
  echo "$RESULT_DATA" | jq -e '.plan | length >= 5'
  # dry-run must not have touched anything
  assert_equal "$(_count orders)" "0"
  _assert_sts_reverted

  run_pbm_task "restore" \
    "{\"namespace\":\"${SNS}\",\"backup_name\":\"${base}\",\"dry_run\":\"false\",\"confirm\":\"true\",\"wait_timeout\":\"1200\"}" 1800
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.status')" "done"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.restore_flavor')" "physical"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.takeover_reverted')" "true"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.metadata_resynced')" "true"
  echo "$RESULT_DATA" | jq -r '.post_restore_required' | grep -q "pbm/backup"

  # data is back exactly as of the base backup: orders restored, the
  # later-created incr collection gone
  assert_equal "$(_count orders)" "3"
  assert_equal "$(_count incr)" "0"
  _assert_sts_reverted
}

@test "restore from the incremental chain tip reconstructs base + increments" {
  local tip
  tip=$(cat "${BATS_FILE_TMPDIR}/incr_tip")

  run_pbm_task "restore" \
    "{\"namespace\":\"${SNS}\",\"backup_name\":\"${tip}\",\"dry_run\":\"false\",\"confirm\":\"true\",\"wait_timeout\":\"1200\"}" 1800
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.restore_flavor')" "physical"

  # tip state = orders(3) + incr steps 1 and 2
  assert_equal "$(_count orders)" "3"
  assert_equal "$(_count incr)" "2"
  _assert_sts_reverted
}

@test "deleting the incremental base cascades to the whole chain (documented PBM semantics)" {
  local base tip
  base=$(cat "${BATS_FILE_TMPDIR}/incr_base")
  tip=$(cat "${BATS_FILE_TMPDIR}/incr_tip")

  run_pbm_task "delete" "{\"namespace\":\"${SNS}\",\"backup_name\":\"${base}\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.dry_run')" "true"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.would_delete[0].name')" "$base"

  run_pbm_task "delete" \
    "{\"namespace\":\"${SNS}\",\"backup_name\":\"${base}\",\"dry_run\":\"false\",\"confirm\":\"true\"}" 600
  assert_equal "$TASK_STATUS" "completed"

  # PBM removes the base AND every increment built on it — the chain is
  # only ever deleted as a whole.
  run_pbm_task "list" "{\"namespace\":\"${SNS}\"}"
  assert_equal "$TASK_STATUS" "completed"
  echo "$RESULT_DATA" | jq -e --arg b "$base" --arg t "$tip" \
    '[.snapshots[]? | select(.name == $b or .name == $t)] | length == 0'
}

@test "PITR on a physical base: point-in-time takeover restore keeps A, drops B" {
  # Fresh physical base to anchor the chunks (and to be the picked base).
  run_pbm_task "backup" "{\"namespace\":\"${SNS}\",\"type\":\"physical\"}" 900
  assert_equal "$TASK_STATUS" "completed"

  run_pbm_task "pitr" \
    "{\"namespace\":\"${SNS}\",\"enabled\":\"true\",\"oplog_span_min\":\"1\",\"dry_run\":\"false\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "completed"

  _eval "db.getSiblingDB('e2e').pitr.insertOne({m:'A'}); print('A written');"
  sleep 3
  local t1_line t1_epoch t1_iso
  t1_line=$(_eval "print('T1|' + Math.floor(Date.now()/1000) + '|' + new Date().toISOString().slice(0,19));" \
    | grep '^T1|' | tail -1 | tr -d '\r')
  t1_epoch=$(echo "$t1_line" | cut -d'|' -f2)
  t1_iso=$(echo "$t1_line" | cut -d'|' -f3)
  [[ -n "$t1_epoch" && -n "$t1_iso" ]]
  sleep 3
  _eval "db.getSiblingDB('e2e').pitr.insertOne({m:'B'}); print('B written');"

  # First chunk can take ~2 minutes to flush (span=1m + slicer startup).
  local elapsed=0
  while (( elapsed < 300 )); do
    if _pbm_agent_exec "$SNS" status -o json 2>/dev/null \
        | jq -e --argjson t "$t1_epoch" \
          '[.backups.pitrChunks.pitrChunks[]? | select(.range.start <= $t and .range.end >= $t)] | length > 0' \
          >/dev/null 2>&1; then
      break
    fi
    sleep 10; elapsed=$((elapsed + 10))
  done
  (( elapsed < 300 )) || { echo "no PITR chunk covering T1 after 300s" >&2; return 1; }

  run_pbm_task "restore" \
    "{\"namespace\":\"${SNS}\",\"time\":\"${t1_iso}\",\"dry_run\":\"false\",\"confirm\":\"true\",\"wait_timeout\":\"1200\"}" 1800
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.restore_flavor')" "physical"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.restored.mode')" "pitr"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.restored.base_type')" "physical"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.pitr_was_enabled')" "true"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.pitr_enabled_now')" "false"

  assert_equal "$(_count pitr '{m:"A"}')" "1"
  assert_equal "$(_count pitr '{m:"B"}')" "0"
  _assert_sts_reverted
}

@test "a fresh backup succeeds after the physical restores (metadata resync proof)" {
  run_pbm_task "backup" "{\"namespace\":\"${SNS}\",\"type\":\"physical\"}" 900
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.status')" "done"
}
