#!/usr/bin/env bats
#
# Contract tests for mariadb/restore.sh.
#
# These run the script directly against a mock `kubectl` — no cluster, no
# MinIO, no operator. They lock down the guardrails and the manifest the task
# renders, which is where the AWS-style restore semantics live:
#   - confirm=true is mandatory (mutating task)
#   - an existing target is never overwritten in place
#   - target_time is validated and, when given, injected as PITR
#   - the rendered MariaDB has bootstrapFrom Physical and no replication wiring
#
# A live restore (real backup round-trip) belongs in the dual-cluster e2e suite.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  RESTORE_SH="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/restore.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"

  MOCK_DIR="$(mktemp -d)"
  CAPTURE="${MOCK_DIR}/applied.yaml"
  RESULT="${MOCK_DIR}/result.json"

  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
# Minimal kubectl mock: find the verb past any --context/--namespace flags.
verb=""
for a in "$@"; do
  case "$a" in
    get|apply|wait) verb="$a"; break ;;
  esac
done
case "$verb" in
  get)   [[ "${MOCK_TARGET_EXISTS:-0}" == "1" ]] && exit 0 || exit 1 ;;
  apply) cat > "${MOCK_APPLY_CAPTURE}"; exit 0 ;;
  wait)  exit 0 ;;
  *)     exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/kubectl"

  # Valid baseline inputs; individual tests override as needed.
  export DB_NAMESPACE="mariadb-bg"
  export RESTORE_TARGET="mariadb-restored"
  export RESTORE_IMAGE="mariadb:10.11"
  export BACKUP_BUCKET="multi-cluster"
  export BACKUP_PREFIX="blue-bats"
  export BACKUP_ENDPOINT="10.0.0.1:30092"
  export CONFIRM="true"
  unset TARGET_TIME
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

# run_restore [KEY=VALUE ...] — run restore.sh with the mock on PATH.
run_restore() {
  run env "PATH=${MOCK_DIR}:${PATH}" \
    "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" \
    "MOCK_APPLY_CAPTURE=${CAPTURE}" \
    "$@" \
    bash "${RESTORE_SH}"
}

result_field() { jq -r "$1" "${RESULT}"; }

@test "restore requires confirm=true" {
  run_restore CONFIRM=false
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"confirm=true is required"* ]]
}

@test "restore refuses to overwrite an existing target" {
  run_restore MOCK_TARGET_EXISTS=1
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"already exists"* ]]
}

@test "restore rejects a malformed target_time" {
  run_restore TARGET_TIME="not-a-timestamp"
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"RFC3339"* ]]
}

@test "restore of latest backup renders Physical bootstrapFrom and no PITR" {
  run_restore MOCK_TARGET_EXISTS=0
  [ "$status" -eq 0 ]
  [ "$(result_field '.status')" = "success" ]
  [ "$(result_field '.data.restored')" = "true" ]
  [ "$(result_field '.data.pointInTimeRecovery.enabled')" = "false" ]

  grep -q "kind: MariaDB" "${CAPTURE}"
  grep -q "backupContentType: Physical" "${CAPTURE}"
  grep -q "bootstrapFrom:" "${CAPTURE}"
  # Restore provisions a standalone instance — no replica/multi-cluster wiring.
  ! grep -q "replication:" "${CAPTURE}"
  ! grep -q "multiCluster:" "${CAPTURE}"
  # No PITR target requested → no targetRecoveryTime in the manifest.
  ! grep -q "targetRecoveryTime" "${CAPTURE}"
}

@test "restore with target_time injects point-in-time recovery" {
  run_restore TARGET_TIME="2026-06-14T03:21:00Z"
  [ "$status" -eq 0 ]
  [ "$(result_field '.status')" = "success" ]
  [ "$(result_field '.data.pointInTimeRecovery.enabled')" = "true" ]
  [ "$(result_field '.data.pointInTimeRecovery.targetRecoveryTime')" = "2026-06-14T03:21:00Z" ]

  grep -q 'targetRecoveryTime: "2026-06-14T03:21:00Z"' "${CAPTURE}"
}
