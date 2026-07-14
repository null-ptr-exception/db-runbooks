#!/usr/bin/env bats
# =============================================================================
# E2E proof that PBM physical support is deployment-convention independent:
# a Bitnami-convention PSMDB fixture — datadir volume at /bitnami/mongodb
# with dbpath /bitnami/mongodb/data/db (dbPath != mount root is exactly
# where path bugs hide in physical file handling), runAsUser 1001,
# MONGODB_ROOT_* secretKeyRefs with non-default key names — with real
# authentication (--auth + keyFile) like pbm_physical.bats.
# Scope mirrors pbm_bitnami.bats: readiness + backup + a compact takeover
# restore round trip; the full matrix lives in pbm_physical.bats.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load 'pbm_helpers'

  SNS="mongo-pbm-phys-bitnami"
  MONGO_USER="bitnamiadmin"
  MONGO_PASS="testpass321"
  export SNS MONGO_USER MONGO_PASS

  _pbm_common_env
  _pbm_apply_fixture "$SNS" "bitnami" "psmdb"
}

teardown_file() {
  kubectl --context "kind-cluster-a" delete namespace "mongo-pbm-phys-bitnami" \
    --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load 'pbm_helpers'
}

_eval() { _pbm_mongo_eval_auth "$SNS" "$MONGO_USER" "$MONGO_PASS" "$1"; }

@test "pbm/status reports physical readiness on the Bitnami-convention PSMDB fixture" {
  run_pbm_task "status" "{\"namespace\":\"${SNS}\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.physical_ready.psmdb')" "true"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.physical_ready.agent_data_volume')" "true"
}

@test "physical backup works with dbPath below the mount root" {
  _eval "
    var c = db.getSiblingDB('e2e').bitnami;
    c.drop();
    c.insertMany([{_id:1},{_id:2}]);
    print('seeded: ' + c.countDocuments({}));"

  run_pbm_task "backup" "{\"namespace\":\"${SNS}\",\"type\":\"physical\"}" 900
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.status')" "done"
  echo "$RESULT_DATA" | jq -r '.backup_name' > "${BATS_FILE_TMPDIR}/phys_backup"

  run _pbm_minio_ls "mongodb/${SNS}"
  assert_success
}

@test "compact physical restore round trip on the Bitnami layout" {
  local name
  name=$(cat "${BATS_FILE_TMPDIR}/phys_backup")

  _eval "db.getSiblingDB('e2e').bitnami.drop(); print('dropped');"

  run_pbm_task "restore" \
    "{\"namespace\":\"${SNS}\",\"backup_name\":\"${name}\",\"dry_run\":\"false\",\"confirm\":\"true\",\"wait_timeout\":\"1200\"}" 1800
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.restore_flavor')" "physical"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.takeover_reverted')" "true"

  local count sts
  count=$(_eval "print(db.getSiblingDB('e2e').bitnami.countDocuments({}))" | tail -1 | tr -d '\r')
  assert_equal "$count" "2"
  sts=$(kubectl --context "$CTX_A" -n "$SNS" get sts mongodb -o json)
  assert_equal "$(jq -r '.metadata.annotations["pbm-restore/auto-patched"] // "absent"' <<< "$sts")" "absent"
}
