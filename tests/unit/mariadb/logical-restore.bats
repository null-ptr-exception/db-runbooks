#!/usr/bin/env bats
#
# Contract tests for mariadb/logical-restore.sh.
#
# Run the script directly against a mock `kubectl` — no cluster, no operator.
# They lock down the user-oriented surface and the manifest the task renders:
#   - namespace is the only required input; version/storage/name/source Backup
#     are resolved internally (RESTORE_* / STORAGE_SIZE are advanced overrides)
#   - AWS-style: provisions a NEW instance via bootstrapFrom.backupRef, never
#     overwrites in place
#   - the source Backup is chosen by name, else the most recent Backup CR
#   - the Backup CRD must exist (fail fast, not `no matches for kind`)
#   - confirm=true is mandatory to apply; dry_run (default) only renders
#   - wait_timeout doubles as the wait switch ("0" = don't wait); a Ready-wait
#     timeout still returns a partial result

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  RESTORE_SH="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/logical-restore.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"

  MOCK_DIR="$(mktemp -d)"
  CAPTURE="${MOCK_DIR}/applied.json"
  RESULT="${MOCK_DIR}/result.json"

  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
# Minimal kubectl mock. NOTE: "-o json" is a substring of "-o jsonpath", so every
# jsonpath-specific branch MUST precede the "-o json" branch.
#   api-resources                    → operator discovery (MOCK_NO_CRD=1 omits Backup)
#   get backup -o jsonpath...        → latest-backup list (MOCK_BACKUPS: "ts\tname" lines)
#   get backup <name>                → Backup existence probe
#   get ... {items...metadata.name}  → source auto-detect list (MOCK_SOURCES)
#   get ... {items...spec.image}     → distinct-image scan (MOCK_SOURCE_IMAGES)
#   get <name> -o json               → source spec (MOCK_SOURCE_IMAGE/_STORAGE)
#   get mariadb <target>             → target existence probe (MOCK_TARGET_EXISTS)
#   apply / wait
args="$*"
verb=""
for a in "$@"; do
  case "$a" in api-resources|get|apply|wait) verb="$a"; break ;; esac
done
case "$verb" in
  api-resources)
    printf 'mariadbs.k8s.mariadb.com\n'
    [[ "${MOCK_NO_CRD:-0}" == "1" ]] || printf 'backups.k8s.mariadb.com\n'
    exit 0 ;;
  get)
    case "$args" in
      *"get backup"*jsonpath*|*backup*creationTimestamp*) printf '%s' "${MOCK_BACKUPS:-}"; exit 0 ;;
      *"get backup"*) [[ -n "${MOCK_BACKUPS:-}" || "${MOCK_BACKUP_EXISTS:-0}" == "1" ]] && exit 0 || exit 1 ;;
      *metadata.name*) printf '%s' "${MOCK_SOURCES:-}";                   exit 0 ;;
      *items*spec.image*) printf '%s' "${MOCK_SOURCE_IMAGES:-}";          exit 0 ;;
      *"-o json"*)
        jq -n --arg img "${MOCK_SOURCE_IMAGE:-}" --arg sz "${MOCK_SOURCE_STORAGE:-}" \
          '{spec: {image: $img, storage: {size: $sz}}}';                  exit 0 ;;
      *"get mariadb"*) [[ "${MOCK_TARGET_EXISTS:-0}" == "1" ]] && exit 0 || exit 1 ;;
      *) echo "mock kubectl: unhandled get: $args" >&2;                   exit 1 ;;
    esac ;;
  apply) cat > "${MOCK_APPLY_CAPTURE}"; exit 0 ;;
  wait)  [[ "${MOCK_WAIT_FAIL:-0}" == "1" ]] && exit 1 || exit 0 ;;
  *)     exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/kubectl"

  export DB_NAMESPACE="mariadb-1"
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

run_restore() {
  run env "PATH=${MOCK_DIR}:${PATH}" \
    "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" \
    "MOCK_APPLY_CAPTURE=${CAPTURE}" \
    "$@" \
    bash "${RESTORE_SH}"
}

result_field() { jq -r "$1" "${RESULT}"; }

@test "logical-restore requires confirm=true to apply" {
  run_restore DRY_RUN=false CONFIRM=false RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"confirm=true is required"* ]]
}

@test "logical-restore dry_run renders a MariaDB manifest with bootstrapFrom.backupRef" {
  run_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.dryRun')" = "true" ]
  [ "$(result_field '.data.backup.contentType')" = "Logical" ]
  [ "$(result_field '.data.manifest | fromjson | .kind')" = "MariaDB" ]
  [ "$(result_field '.data.manifest | fromjson | .spec.bootstrapFrom | has("backupRef")')" = "true" ]
  [ ! -f "${CAPTURE}" ]
}

@test "logical-restore picks the most recent Backup when none is named" {
  export MOCK_BACKUPS=$'2026-07-01T00:00:00Z\tmariadb-logical-old\n2026-07-08T00:00:00Z\tmariadb-logical-new'
  run_restore DRY_RUN=false CONFIRM=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.restored')" = "true" ]
  [ "$(jq -r '.spec.bootstrapFrom.backupRef.name' "${CAPTURE}")" = "mariadb-logical-new" ]
}

@test "logical-restore uses an explicitly named Backup" {
  run_restore DRY_RUN=false CONFIRM=true BACKUP_NAME=mariadb-logical-pick \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi MOCK_BACKUP_EXISTS=1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.spec.bootstrapFrom.backupRef.name' "${CAPTURE}")" = "mariadb-logical-pick" ]
}

@test "logical-restore fails when no Backup exists to restore from" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"no Backup found"* ]]
}

@test "logical-restore fails when the named Backup is not found" {
  run_restore DRY_RUN=false CONFIRM=true BACKUP_NAME=ghost \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi MOCK_BACKUP_EXISTS=0
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"not found"* ]]
}

@test "logical-restore refuses to overwrite an existing target" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-clone BACKUP_NAME=mariadb-logical-x \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi MOCK_BACKUP_EXISTS=1 MOCK_TARGET_EXISTS=1
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"already exists"* ]]
}

@test "logical-restore fails fast when the Backup CRD is absent" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi MOCK_NO_CRD=1
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"no 'backups' CRD"* ]]
}

@test "logical-restore fails on mixed versions without a source/image override" {
  export MOCK_SOURCE_IMAGES=$'mariadb:10.6\nmariadb:11.4'
  run_restore DRY_RUN=false CONFIRM=true STORAGE_SIZE=1Gi MOCK_BACKUP_EXISTS=1
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"multiple MariaDB versions"* ]]
}

@test "logical-restore returns a partial result (not lost) when the Ready wait times out" {
  run_restore DRY_RUN=false CONFIRM=true BACKUP_NAME=mariadb-logical-x RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    MOCK_BACKUP_EXISTS=1 MOCK_WAIT_FAIL=1
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"did not become Ready"* ]]
  [ "$(result_field '.data.restored')" = "true" ]
}

@test "logical-restore with wait_timeout=0 applies without waiting" {
  run_restore DRY_RUN=false CONFIRM=true BACKUP_NAME=mariadb-logical-x RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    MOCK_BACKUP_EXISTS=1 WAIT_TIMEOUT=0 MOCK_WAIT_FAIL=1
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.restored')" = "true" ]
}
