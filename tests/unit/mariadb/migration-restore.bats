#!/usr/bin/env bats
#
# Contract tests for mariadb/migration/restore.sh.
#
# Run the script directly with mock `kubectl` and `mc` — no cluster, no MinIO.
# Locked-down behaviours:
#   - backup_file, minio_* params, image, and storage_size are task inputs
#   - backup existence is checked via mc BEFORE any K8s resource is created
#   - confirm=true is mandatory to apply (dry_run renders without it)
#   - an existing target is never overwritten in place
#   - minio_secret_key never appears in the result JSON
#   - wait_timeout="0" skips the Ready wait; a timeout still returns a partial result
#   - the result returns the connection endpoint + credential reference
#   - the bootstrapFrom.s3.prefix is exactly the backup_file input value

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  RESTORE_SH="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/migration/restore.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"

  MOCK_DIR="$(mktemp -d)"
  CAPTURE="${MOCK_DIR}/applied.yaml"
  RESULT="${MOCK_DIR}/result.json"

  # --- kubectl mock -----------------------------------------------------------
  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
# Minimal kubectl mock for migration/restore unit tests:
#   get mariadb (jsonpath metadata.name)  → source auto-detect (MOCK_SOURCES)
#   get mariadb (jsonpath spec.image)     → distinct-image scan (MOCK_SOURCE_IMAGES)
#   get mariadb <name> -o json            → source spec (MOCK_SOURCE_IMAGE/_STORAGE)
#   get mariadb <target>                  → target existence probe (MOCK_TARGET_EXISTS)
#   create secret --dry-run -o json       → pass-through (no-op)
#   apply -f -                            → capture stdin OR ignore (secret apply)
#   delete secret                         → no-op (cleanup)
#   wait                                  → Ready wait (fails with MOCK_WAIT_FAIL=1)
args="$*"
verb=""
for a in "$@"; do
  case "$a" in get|apply|wait|create|delete) verb="$a"; break ;; esac
done
case "$verb" in
  get)
    case "$args" in
      *"metadata.name"*)
        printf '%s' "${MOCK_SOURCES:-}"; exit 0 ;;
      *"items"*"spec.image"*)
        printf '%s' "${MOCK_SOURCE_IMAGES:-}"; exit 0 ;;
      *"-o json"*)
        jq -n \
          --arg img "${MOCK_SOURCE_IMAGE:-}" \
          --arg sz  "${MOCK_SOURCE_STORAGE:-}" \
          --argjson res "${MOCK_SOURCE_RESOURCES:-null}" \
          '{spec: {image: $img, storage: {size: $sz}}}
           | if $res == null then . else .spec.resources = $res end'
        exit 0 ;;
      *"get mariadb"*)
        [[ "${MOCK_TARGET_EXISTS:-0}" == "1" ]] && exit 0 || exit 1 ;;
      *) echo "mock kubectl: unhandled get: $args" >&2; exit 1 ;;
    esac ;;
  create)
    # secret create --dry-run=client -o json: just echo an empty object so
    # the pipe into `apply -f -` has valid JSON to consume.
    echo '{}'; exit 0 ;;
  apply)
    # Only capture the MariaDB CR apply; discard the secret dry-run apply.
    local _input
    _input=$(cat)
    if echo "$_input" | jq -e '.kind == "MariaDB"' >/dev/null 2>&1; then
      echo "$_input" > "${MOCK_APPLY_CAPTURE}"
    fi
    exit 0 ;;
  delete) exit 0 ;;
  wait)  [[ "${MOCK_WAIT_FAIL:-0}" == "1" ]] && exit 1 || exit 0 ;;
  *)     exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/kubectl"

  # --- mc mock ----------------------------------------------------------------
  cat > "${MOCK_DIR}/mc" <<'MOCK'
#!/usr/bin/env bash
# Minimal mc mock:
#   alias set ...  → success (or fail with MOCK_MC_AUTH_FAIL=1)
#   ls <path>      → one line if MOCK_BACKUP_EXISTS=1, empty if =0 (default: 1)
#   alias rm ...   → no-op
args="$*"
case "$args" in
  "alias set "*)
    [[ "${MOCK_MC_AUTH_FAIL:-0}" == "1" ]] && exit 1 || exit 0 ;;
  "ls "*)
    [[ "${MOCK_BACKUP_EXISTS:-1}" == "1" ]] && printf '[2026-07-12] backup-file\n' && exit 0
    exit 0 ;;  # empty output when backup not found
  "alias rm "*)
    exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/mc"

  # Required env for every test.
  export DB_NAMESPACE="mariadb-dest"
  export BACKUP_FILE="mariadb/source-ns/mariadb-migration-20260712143022"
  export MINIO_ENDPOINT="http://minio.example.test:9000"
  export MINIO_ACCESS_KEY="testkey"
  export MINIO_SECRET_KEY="testsecret"
  export MINIO_BUCKET="db-backups"
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

# run_migration_restore [KEY=VALUE ...] — run with the mocks on PATH.
run_migration_restore() {
  run env "PATH=${MOCK_DIR}:${PATH}" \
    "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" \
    "MOCK_APPLY_CAPTURE=${CAPTURE}" \
    "$@" \
    bash "${RESTORE_SH}"
}

result_field() { jq -r "$1" "${RESULT}"; }

# ---------------------------------------------------------------------------
# Confirm gate
# ---------------------------------------------------------------------------

@test "migration/restore requires confirm=true to apply" {
  run_migration_restore DRY_RUN=false CONFIRM=false \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"confirm=true is required"* ]]
}

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------

@test "migration/restore dry_run renders manifest without confirm or apply" {
  run_migration_restore DRY_RUN=true CONFIRM=false \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated
  [ "$status" -eq 0 ]
  [ "$(result_field '.status')" = "success" ]
  [ "$(result_field '.data.dryRun')" = "true" ]
  [ "$(result_field '.data.restored')" = "false" ]
  # No K8s resources touched: capture file must not exist.
  [ ! -f "${CAPTURE}" ]
  [ "$(result_field '.data.manifest | fromjson | .kind')" = "MariaDB" ]
  [ "$(result_field '.data.manifest | fromjson | .spec.bootstrapFrom.backupContentType')" = "Physical" ]
}

@test "migration/restore dry_run does not check MinIO (no mc call needed)" {
  # Even with mc_auth_fail set, dry run must succeed (mc is never called).
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    MOCK_MC_AUTH_FAIL=1
  [ "$status" -eq 0 ]
  [ "$(result_field '.status')" = "success" ]
}

@test "migration/restore dry_run backup_file appears as bootstrapFrom.s3.prefix" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    RESTORE_TARGET=mariadb-migrated
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.manifest | fromjson | .spec.bootstrapFrom.s3.prefix')" \
    = "mariadb/source-ns/mariadb-migration-20260712143022" ]
  [ "$(result_field '.data.manifest | fromjson | .spec.bootstrapFrom.s3.bucket')" \
    = "db-backups" ]
}

@test "migration/restore dry_run returns connection endpoint" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    RESTORE_TARGET=mariadb-migrated
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.connection.host')" \
    = "mariadb-migrated-primary.mariadb-dest.svc.cluster.local" ]
  [ "$(result_field '.data.connection.port')" = "3306" ]
}

@test "migration/restore auto-generates target name when omitted" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi
  [ "$status" -eq 0 ]
  local target
  target="$(result_field '.data.target')"
  [[ "$target" =~ ^mariadb-dest-restore-[0-9]+$ ]]
}

# ---------------------------------------------------------------------------
# backup_file validation
# ---------------------------------------------------------------------------

@test "migration/restore fails when backup_file is missing" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    BACKUP_FILE=""
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"backup_file"*"required"* ]]
}

@test "migration/restore fails when backup_file has invalid path characters" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    BACKUP_FILE="bad path with spaces"
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"backup_file"* ]]
}

# ---------------------------------------------------------------------------
# MinIO input validation
# ---------------------------------------------------------------------------

@test "migration/restore fails when minio_endpoint is missing" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    MINIO_ENDPOINT=""
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"minio_endpoint"*"required"* ]]
}

@test "migration/restore fails when minio_bucket is missing" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    MINIO_BUCKET=""
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"minio_bucket"*"required"* ]]
}

# ---------------------------------------------------------------------------
# minio_secret_key security — must never appear in result JSON
# ---------------------------------------------------------------------------

@test "migration/restore result does not expose minio_secret_key" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    MINIO_SECRET_KEY="supersecret-do-not-expose"
  [ "$status" -eq 0 ]
  # The raw value must not appear anywhere in the result file.
  run grep "supersecret-do-not-expose" "${RESULT}"
  [ "$status" -ne 0 ]
}

@test "migration/restore real run result does not expose minio_secret_key" {
  run_migration_restore DRY_RUN=false CONFIRM=true \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated \
    MOCK_BACKUP_EXISTS=1 MOCK_TARGET_EXISTS=0 \
    MINIO_SECRET_KEY="supersecret-do-not-expose"
  [ "$status" -eq 0 ]
  run grep "supersecret-do-not-expose" "${RESULT}"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Backup existence check
# ---------------------------------------------------------------------------

@test "migration/restore fails when backup not found in MinIO" {
  run_migration_restore DRY_RUN=false CONFIRM=true \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated \
    MOCK_BACKUP_EXISTS=0 MOCK_TARGET_EXISTS=0
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"backup not found"* ]]
  [[ "$(result_field '.message')" == *"${BACKUP_FILE}"* ]]
  # Must not have applied the MariaDB CR (no K8s resource created on failure).
  [ ! -f "${CAPTURE}" ]
}

@test "migration/restore fails when MinIO authentication fails" {
  run_migration_restore DRY_RUN=false CONFIRM=true \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated \
    MOCK_MC_AUTH_FAIL=1 MOCK_TARGET_EXISTS=0
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"authenticate"* ]]
  [ ! -f "${CAPTURE}" ]
}

# ---------------------------------------------------------------------------
# Target existence guard
# ---------------------------------------------------------------------------

@test "migration/restore refuses to overwrite an existing target" {
  run_migration_restore DRY_RUN=false CONFIRM=true \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated \
    MOCK_BACKUP_EXISTS=1 MOCK_TARGET_EXISTS=1
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"already exists"* ]]
}

# ---------------------------------------------------------------------------
# image / storage_size resolution
# ---------------------------------------------------------------------------

@test "migration/restore fails when image cannot be derived and is not provided" {
  run_migration_restore DRY_RUN=true STORAGE_SIZE=1Gi
  # MOCK_SOURCES empty → no source instance → no image
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"image"* ]]
}

@test "migration/restore fails when storage_size cannot be derived and is not provided" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4
  # MOCK_SOURCES empty → no source instance → no storage_size
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"storage size"* ]]
}

@test "migration/restore derives image and storage from the auto-detected source" {
  run_migration_restore DRY_RUN=true RESTORE_TARGET=mariadb-migrated \
    MOCK_SOURCES=mariadb-prod MOCK_SOURCE_IMAGE=mariadb:11.4 MOCK_SOURCE_STORAGE=10Gi
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.source')" = "mariadb-prod" ]
  [ "$(result_field '.data.image')" = "mariadb:11.4" ]
  [ "$(result_field '.data.manifest | fromjson | .spec.storage.size')" = "10Gi" ]
}

@test "migration/restore accepts explicit image and storage_size (fresh namespace)" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=20Gi \
    RESTORE_TARGET=mariadb-migrated
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.image')" = "mariadb:11.4" ]
  [ "$(result_field '.data.manifest | fromjson | .spec.storage.size')" = "20Gi" ]
  [ "$(result_field '.data.source')" = "null" ]
}

@test "migration/restore inherits source resources when available" {
  run_migration_restore DRY_RUN=true RESTORE_TARGET=mariadb-migrated \
    MOCK_SOURCES=mariadb-prod MOCK_SOURCE_IMAGE=mariadb:11.4 MOCK_SOURCE_STORAGE=10Gi \
    MOCK_SOURCE_RESOURCES='{"requests":{"cpu":"200m","memory":"512Mi"}}'
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.manifest | fromjson | .spec.resources.requests.cpu')" = "200m" ]
}

# ---------------------------------------------------------------------------
# Full real-run path
# ---------------------------------------------------------------------------

@test "migration/restore applies MariaDB CR with correct bootstrapFrom prefix" {
  run_migration_restore DRY_RUN=false CONFIRM=true \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated \
    MOCK_BACKUP_EXISTS=1 MOCK_TARGET_EXISTS=0
  [ "$status" -eq 0 ]
  [ "$(result_field '.status')" = "success" ]
  [ "$(result_field '.data.restored')" = "true" ]
  [ -f "${CAPTURE}" ]
  [ "$(jq -r '.spec.bootstrapFrom.s3.prefix' "${CAPTURE}")" \
    = "mariadb/source-ns/mariadb-migration-20260712143022" ]
  [ "$(jq -r '.spec.bootstrapFrom.backupContentType' "${CAPTURE}")" = "Physical" ]
  [ "$(jq -r '.spec.bootstrapFrom.s3.bucket' "${CAPTURE}")" = "db-backups" ]
}

@test "migration/restore result includes backup.backupFile field" {
  run_migration_restore DRY_RUN=false CONFIRM=true \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated \
    MOCK_BACKUP_EXISTS=1 MOCK_TARGET_EXISTS=0
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.backup.backupFile')" \
    = "mariadb/source-ns/mariadb-migration-20260712143022" ]
}

@test "migration/restore returns a partial result when Ready wait times out" {
  run_migration_restore DRY_RUN=false CONFIRM=true \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated \
    MOCK_BACKUP_EXISTS=1 MOCK_TARGET_EXISTS=0 MOCK_WAIT_FAIL=1
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"did not become Ready"* ]]
  # The instance was applied, so the connection endpoint is still returned.
  [ -f "${CAPTURE}" ]
  [ "$(result_field '.data.restored')" = "true" ]
  [ "$(result_field '.data.connection.host')" \
    = "mariadb-migrated-primary.mariadb-dest.svc.cluster.local" ]
}

@test "migration/restore with wait_timeout=0 applies without waiting for Ready" {
  run_migration_restore DRY_RUN=false CONFIRM=true \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated \
    WAIT_TIMEOUT=0 MOCK_BACKUP_EXISTS=1 MOCK_TARGET_EXISTS=0 MOCK_WAIT_FAIL=1
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.restored')" = "true" ]
  [ -f "${CAPTURE}" ]
}

@test "migration/restore accepts a well-formed context" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    K8S_CONTEXT=kind-cluster-dbs
  [ "$status" -eq 0 ]
}

@test "migration/restore rejects a malformed context" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    K8S_CONTEXT="bad context!"
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"context"* ]]
}
