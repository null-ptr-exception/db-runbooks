#!/usr/bin/env bats
#
# Contract tests for backup/delete-backup-mariadb.sh — run against a mock `mc`,
# no MinIO. Lock down: confirm gating, dry-run plan, path-traversal guard on the
# backup name, not-found handling, and the scoped delete path.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/aqsh-tasks/scripts/backup/delete-backup-mariadb.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"
  MOCK_DIR="$(mktemp -d)"
  RESULT="${MOCK_DIR}/result.json"
  RM_CAPTURE="${MOCK_DIR}/rm.args"

  cat > "${MOCK_DIR}/mc" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  alias) exit 0 ;;
  stat)  [[ "${MOCK_MC_STAT:-1}" == "1" ]] && exit 0 || exit 1 ;;   # exists?
  rm)    printf '%s' "$*" > "${MOCK_RM_CAPTURE}"
         [[ "${MOCK_MC_RM_FAIL:-0}" == "1" ]] && exit 1 || exit 0 ;;
  *)     exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/mc"
  export DB_NAMESPACE="mariadb-1"
  export MDBT_CONFIG_FILE="${MOCK_DIR}/nonexistent.env"
}

teardown() { rm -rf "${MOCK_DIR}"; }

run_del() {
  run env "PATH=${MOCK_DIR}:${PATH}" "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" "MOCK_RM_CAPTURE=${RM_CAPTURE}" "$@" bash "${SCRIPT}"
}
field() { jq -r "$1" "${RESULT}"; }

@test "delete-backup requires confirm=true to apply" {
  run_del DRY_RUN=false CONFIRM=false BACKUP_NAME=snap-1
  [ "$status" -ne 0 ]
  [ "$(field '.status')" = "error" ]
  [[ "$(field '.message')" == *"confirm=true is required"* ]]
  [ ! -f "${RM_CAPTURE}" ]
}

@test "delete-backup dry_run renders the plan without deleting" {
  run_del DRY_RUN=true BACKUP_NAME=snap-1
  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "success" ]
  [ "$(field '.data.dryRun')" = "true" ]
  [ "$(field '.data.deleted')" = "false" ]
  [ "$(field '.data.location.path')" = "mariadb/mariadb-1/snap-1" ]
  [ ! -f "${RM_CAPTURE}" ]
}

@test "delete-backup rejects a backup name containing a path" {
  run_del DRY_RUN=false CONFIRM=true BACKUP_NAME="../other-ns/secret"
  [ "$status" -ne 0 ]
  [ "$(field '.status')" = "error" ]
  [[ "$(field '.message')" == *"single name segment"* ]]
  [ ! -f "${RM_CAPTURE}" ]
}

@test "delete-backup requires the backup input" {
  run_del DRY_RUN=false CONFIRM=true
  [ "$status" -ne 0 ]
  [ "$(field '.status')" = "error" ]
  [[ "$(field '.message')" == *"backup is required"* ]]
}

@test "delete-backup fails when the backup does not exist" {
  run_del DRY_RUN=false CONFIRM=true BACKUP_NAME=missing MOCK_MC_STAT=0
  [ "$status" -ne 0 ]
  [ "$(field '.status')" = "error" ]
  [[ "$(field '.message')" == *"not found"* ]]
  [ ! -f "${RM_CAPTURE}" ]
}

@test "delete-backup deletes the scoped target on confirm" {
  run_del DRY_RUN=false CONFIRM=true BACKUP_NAME=snap-1 MOCK_MC_STAT=1
  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "success" ]
  [ "$(field '.data.deleted')" = "true" ]
  # the rm target is confined to the namespace prefix
  grep -q "minio/db-backups/mariadb/mariadb-1/snap-1" "${RM_CAPTURE}"
}
