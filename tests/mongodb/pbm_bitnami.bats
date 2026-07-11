#!/usr/bin/env bats
# =============================================================================
# E2E proof that the pbm/* tasks are deployment-convention independent: a
# Bitnami-convention fixture (MONGODB_ROOT_* secretKeyRefs with non-default
# key names, datadir volume at /bitnami/mongodb, dbpath
# /bitnami/mongodb/data/db, runAsUser 1001) with the same pbm-agent sidecar.
# Agent detection reads PBM_MONGODB_URI from the live pod template and the
# tasks never load mongo credentials at all, so nothing here depends on the
# official-image convention — this file proves it end to end (status ->
# backup -> artifact in MinIO -> list). Mirrors fcv_bitnami.bats scope.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load 'pbm_helpers'

  SNS="mongo-pbm-bitnami"
  export SNS

  _pbm_common_env
  _pbm_apply_fixture "$SNS" "bitnami"
}

teardown_file() {
  kubectl --context "kind-cluster-a" delete namespace "mongo-pbm-bitnami" \
    --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load 'pbm_helpers'
}

@test "pbm/status auto-detects the agent on the Bitnami-convention deployment" {
  run_pbm_task "status" "{\"namespace\":\"${SNS}\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.agent_container')" "pbm-agent"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '[.agents[].nodes[]] | length')" "2"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.storage.configured')" "false"
}

@test "pbm/backup -> MinIO artifact -> pbm/list round trip on the Bitnami-convention deployment" {
  _pbm_mongo_eval "$SNS" "
    var c = db.getSiblingDB('e2e').bitnami;
    c.drop();
    c.insertMany([{_id:1},{_id:2}]);
    print('seeded: ' + c.countDocuments({}));"

  run_pbm_task "backup" "{\"namespace\":\"${SNS}\"}" 600
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.status')" "done"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.storage.prefix')" "mongodb/${SNS}"

  local backup_name
  backup_name=$(echo "$RESULT_DATA" | jq -r '.backup_name')

  run _pbm_minio_ls "mongodb/${SNS}"
  assert_success

  run_pbm_task "list" "{\"namespace\":\"${SNS}\"}"
  assert_equal "$TASK_STATUS" "completed"
  echo "$RESULT_DATA" | jq -e --arg n "$backup_name" \
    '[.snapshots[] | select(.name == $n and .status == "done")] | length == 1'
}
