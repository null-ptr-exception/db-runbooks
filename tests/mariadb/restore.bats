#!/usr/bin/env bats
#
# Contract tests for mariadb/restore.sh.
#
# These run the script directly against a mock `kubectl` — no cluster, no
# MinIO, no operator. They lock down the user-oriented surface and the manifest
# the task renders:
#   - namespace is the only required input; credentials / S3 location are internal
#   - the source instance (for version/storage) is auto-detected, overridable
#     via `source`, and version is never silently guessed
#   - confirm=true is mandatory to apply; dry_run (default) only renders
#   - an existing target is never overwritten in place
#   - target_time is range-validated and, when given, injected as PITR
#   - the result returns the connection endpoint + credential reference
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
# Minimal kubectl mock:
#   get ... {range .items...}  → source auto-detect list (MOCK_SOURCES)
#   get <name> ... spec.image  → source image
#   get <name> ... storage.size → source storage
#   get <target>               → target existence probe
#   apply                      → capture stdin
args="$*"
verb=""
for a in "$@"; do
  case "$a" in get|apply|wait) verb="$a"; break ;; esac
done
case "$verb" in
  get)
    case "$args" in
      *items*)         printf '%s' "${MOCK_SOURCES:-}";        exit 0 ;;
      *spec.image*)    echo "${MOCK_SOURCE_IMAGE:-}";          exit 0 ;;
      *storage.size*)  echo "${MOCK_SOURCE_STORAGE:-}";        exit 0 ;;
      *) [[ "${MOCK_TARGET_EXISTS:-0}" == "1" ]] && exit 0 || exit 1 ;;
    esac ;;
  apply) cat > "${MOCK_APPLY_CAPTURE}"; exit 0 ;;
  wait)  exit 0 ;;
  *)     exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/kubectl"

  # namespace is the only required input; everything else is resolved/optional.
  export DB_NAMESPACE="mariadb-bg"
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

@test "restore requires confirm=true to apply" {
  run_restore DRY_RUN=false CONFIRM=false
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"confirm=true is required"* ]]
}

@test "restore refuses to overwrite an existing target" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:11.4 MOCK_TARGET_EXISTS=1
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"already exists"* ]]
}

@test "restore rejects a malformed target_time" {
  run_restore RESTORE_IMAGE=mariadb:11.4 TARGET_TIME="not-a-timestamp"
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"RFC3339"* ]]
}

@test "restore rejects an out-of-range target_time" {
  run_restore RESTORE_IMAGE=mariadb:11.4 TARGET_TIME="2026-99-99T25:61:61Z"
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"RFC3339"* ]]
}

@test "restore dry_run renders the manifest without confirm or apply" {
  run_restore DRY_RUN=true CONFIRM=false RESTORE_TARGET=mariadb-restored RESTORE_IMAGE=mariadb:11.4
  [ "$status" -eq 0 ]
  [ "$(result_field '.status')" = "success" ]
  [ "$(result_field '.data.dryRun')" = "true" ]
  [ "$(result_field '.data.restored')" = "false" ]
  [ ! -f "${CAPTURE}" ]
  [[ "$(result_field '.data.manifest')" == *"kind: MariaDB"* ]]
  [[ "$(result_field '.data.manifest')" == *"backupContentType: Physical"* ]]
}

@test "restore resolves internals and returns a connection endpoint" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    MOCK_SOURCES=mariadb-green MOCK_SOURCE_IMAGE=mariadb:10.11 MOCK_SOURCE_STORAGE=5Gi MOCK_TARGET_EXISTS=0
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.restored')" = "true" ]
  [ "$(result_field '.data.pointInTimeRecovery.enabled')" = "false" ]

  [ "$(result_field '.data.connection.host')" = "mariadb-restored-primary.mariadb-bg.svc.cluster.local" ]
  [ "$(result_field '.data.connection.port')" = "3306" ]
  [ "$(result_field '.data.credentialsRef.secretName')" = "mariadb" ]

  grep -q "backupContentType: Physical" "${CAPTURE}"
  grep -q "prefix: mariadb/mariadb-bg" "${CAPTURE}"
  ! grep -q "replication:" "${CAPTURE}"
  ! grep -q "multiCluster:" "${CAPTURE}"
  ! grep -q "targetRecoveryTime" "${CAPTURE}"
}

@test "restore with target_time injects point-in-time recovery" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:11.4 TARGET_TIME="2026-06-14T03:21:00Z" MOCK_TARGET_EXISTS=0
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.pointInTimeRecovery.enabled')" = "true" ]
  [ "$(result_field '.data.pointInTimeRecovery.targetRecoveryTime')" = "2026-06-14T03:21:00Z" ]
  grep -q 'targetRecoveryTime: "2026-06-14T03:21:00Z"' "${CAPTURE}"
}

@test "restore auto-generates a target name when omitted" {
  run_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4
  [ "$status" -eq 0 ]
  local target
  target="$(result_field '.data.target')"
  [[ "$target" =~ ^mariadb-bg-restore-[0-9]+$ ]]
  [ "$(result_field '.data.connection.host')" = "${target}-primary.mariadb-bg.svc.cluster.local" ]
}

@test "restore derives image and storage from the auto-detected source" {
  run_restore DRY_RUN=true RESTORE_TARGET=mariadb-restored \
    MOCK_SOURCES=mariadb-green MOCK_SOURCE_IMAGE=mariadb:10.11 MOCK_SOURCE_STORAGE=5Gi
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.source')" = "mariadb-green" ]
  [ "$(result_field '.data.image')" = "mariadb:10.11" ]
  [[ "$(result_field '.data.manifest')" == *"size: 5Gi"* ]]
}

@test "restore fails when the source is gone and no image is given" {
  run_restore DRY_RUN=true   # MOCK_SOURCES empty → no source found
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"image"* ]]
}

@test "restore fails on an ambiguous source without source/image" {
  run_restore DRY_RUN=true MOCK_SOURCES=$'mariadb-blue\nmariadb-green'
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"multiple MariaDB instances"* ]]
}

@test "restore uses an explicit source override" {
  run_restore DRY_RUN=true RESTORE_TARGET=mariadb-restored \
    RESTORE_SOURCE=mariadb-green MOCK_SOURCE_IMAGE=mariadb:10.11 MOCK_SOURCE_STORAGE=5Gi
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.source')" = "mariadb-green" ]
  [ "$(result_field '.data.image')" = "mariadb:10.11" ]
}
