#!/usr/bin/env bats
#
# Contract tests for mariadb/migration/restore.sh.
#
# Run the script directly with mock `kubectl` and `s5cmd` — no cluster, no MinIO.
# Locked-down behaviours:
#   - backup_file, minio_* params, image, and storage_size are task inputs
#   - backup existence is checked via s5cmd BEFORE any K8s resource is created
#   - confirm=true is mandatory to apply (dry_run renders without it)
#   - an existing target is never overwritten in place (atomic `create`, not
#     check-then-`apply`)
#   - minio_secret_key never appears in the result JSON
#   - wait_timeout="0" is rejected up front; on a real (non-zero) timeout the
#     temp credential Secret is deliberately left in place rather than
#     deleted, since the operator may still be reading it
#   - a Ready-wait timeout still returns a partial result
#   - the result returns the connection endpoint + credentialsRef
#   - the bootstrapFrom.s3.prefix is exactly the backup_file input value

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  RESTORE_SH="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/migration/restore.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"

  MOCK_DIR="$(mktemp -d)"
  CAPTURE="${MOCK_DIR}/applied.yaml"
  RESULT="${MOCK_DIR}/result.json"
  DELETES="${MOCK_DIR}/deletes.log"
  KUBECTL_LOG="${MOCK_DIR}/kubectl.log"

  # --- kubectl mock -----------------------------------------------------------
  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
# Minimal kubectl mock for migration/restore unit tests:
#   get mariadb (jsonpath metadata.name)  → source auto-detect (MOCK_SOURCES)
#   get mariadb (jsonpath spec.image)     → distinct-image scan (MOCK_SOURCE_IMAGES)
#   get mariadb <name> -o json            → source spec (MOCK_SOURCE_IMAGE/_STORAGE)
#   get secret <root secret>              → root-secret pre-check (MOCK_ROOT_SECRET_MISSING)
#   create -f - (kind: Secret)            → temp credential secret (always succeeds)
#   create -f - (kind: MariaDB)           → CR creation: AlreadyExists (MOCK_TARGET_EXISTS) or capture+succeed
#   delete secret                         → logged to MOCK_DELETE_LOG, always succeeds
#   wait                                  → Ready wait (fails with MOCK_WAIT_FAIL=1)
args="$*"
[[ -n "${KUBECTL_LOG:-}" ]] && printf '%s\n' "$args" >> "${KUBECTL_LOG}"
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
      *"get secret"*)
        [[ "${MOCK_ROOT_SECRET_MISSING:-0}" == "1" ]] && exit 1 || exit 0 ;;
      *) echo "mock kubectl: unhandled get: $args" >&2; exit 1 ;;
    esac ;;
  create)
    # Both the temp credential Secret and the MariaDB CR now go through
    # `create -f -`; distinguish by the piped manifest's kind.
    _input=$(cat)
    _kind=$(printf '%s' "$_input" | jq -r '.kind // empty' 2>/dev/null)
    if [[ "$_kind" == "Secret" ]]; then
      exit 0
    fi
    if [[ "${MOCK_TARGET_EXISTS:-0}" == "1" ]]; then
      echo 'Error from server (AlreadyExists): error when creating "STDIN": mariadbs.k8s.mariadb.com "target" already exists' >&2
      exit 1
    fi
    if [[ "$_kind" == "MariaDB" ]]; then
      printf '%s' "$_input" > "${MOCK_APPLY_CAPTURE}"
    fi
    exit 0 ;;
  delete)
    [[ -n "${MOCK_DELETE_LOG:-}" ]] && printf '%s\n' "$args" >> "${MOCK_DELETE_LOG}"
    exit 0 ;;
  wait)  [[ "${MOCK_WAIT_FAIL:-0}" == "1" ]] && exit 1 || exit 0 ;;
  *)     exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/kubectl"

  # --- s5cmd mock ---------------------------------------------------------------
  cat > "${MOCK_DIR}/s5cmd" <<'MOCK'
#!/usr/bin/env bash
# Minimal s5cmd mock for the `ls s3://bucket/backup_file/` existence check:
#   MOCK_BACKUP_EXISTS=1 (default) → one listing line, exit 0
#   MOCK_BACKUP_EXISTS=0           → "no object found" on stderr, exit 1
#   MOCK_S5_AUTH_FAIL=1            → a non-"no object found" error, exit 1
for a in "$@"; do
  if [[ "$a" == "ls" ]]; then
    if [[ "${MOCK_S5_AUTH_FAIL:-0}" == "1" ]]; then
      echo 'ERROR "ls s3://...": AccessDenied' >&2
      exit 1
    fi
    if [[ "${MOCK_BACKUP_EXISTS:-1}" == "1" ]]; then
      printf '2026/07/12 00:00:00               1234  backup-file\n'
      exit 0
    fi
    echo 'ERROR "ls s3://...": no object found' >&2
    exit 1
  fi
done
exit 0
MOCK
  chmod +x "${MOCK_DIR}/s5cmd"

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
    "MOCK_DELETE_LOG=${DELETES}" \
    "KUBECTL_LOG=${KUBECTL_LOG}" \
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

@test "migration/restore dry_run does not check MinIO (no s5cmd call needed)" {
  # Even with the auth-fail mock armed, dry run must succeed (s5cmd never runs).
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    MOCK_S5_AUTH_FAIL=1
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
  # No <name>-primary Service exists for a single-replica standalone instance
  # (this task is always standalone) — the plain Service is the real one.
  [ "$(result_field '.data.connection.host')" \
    = "mariadb-migrated.mariadb-dest.svc.cluster.local" ]
  [ "$(result_field '.data.connection.port')" = "3306" ]
}

@test "migration/restore dry_run returns credentialsRef alongside the connection endpoint" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    RESTORE_TARGET=mariadb-migrated
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.credentialsRef.secretName')" = "mariadb" ]
  [ "$(result_field '.data.credentialsRef.secretKey')" = "password" ]
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
# MinIO — deploy-time MINIO_*_DEFAULT fallback
# ---------------------------------------------------------------------------

@test "migration/restore falls back to MINIO_ENDPOINT_DEFAULT when minio_endpoint is omitted" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    RESTORE_TARGET=mariadb-migrated \
    MINIO_ENDPOINT="" MINIO_ENDPOINT_DEFAULT="http://minio.example.test:9000"
  [ "$status" -eq 0 ]
  [ "$(result_field '.status')" = "success" ]
  [ "$(result_field '.data.manifest | fromjson | .spec.bootstrapFrom.s3.endpoint')" \
    = "minio.example.test:9000" ]
}

@test "migration/restore an explicit minio_endpoint overrides MINIO_ENDPOINT_DEFAULT" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    RESTORE_TARGET=mariadb-migrated \
    MINIO_ENDPOINT="http://explicit.minio.test:9000" \
    MINIO_ENDPOINT_DEFAULT="http://default.minio.test:9000"
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.manifest | fromjson | .spec.bootstrapFrom.s3.endpoint')" \
    = "explicit.minio.test:9000" ]
}

@test "migration/restore falls back to MINIO_ACCESS_KEY_DEFAULT/MINIO_SECRET_KEY_DEFAULT/MINIO_BUCKET_DEFAULT" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    RESTORE_TARGET=mariadb-migrated \
    MINIO_ACCESS_KEY="" MINIO_SECRET_KEY="" MINIO_BUCKET="" \
    MINIO_ACCESS_KEY_DEFAULT=minioadmin MINIO_SECRET_KEY_DEFAULT=minioadmin123 \
    MINIO_BUCKET_DEFAULT=db-backups
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.manifest | fromjson | .spec.bootstrapFrom.s3.bucket')" = "db-backups" ]
}

@test "migration/restore still fails clearly when neither minio_endpoint nor a default is set" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    MINIO_ENDPOINT=""
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"minio_endpoint"*"required"* ]]
}

# ---------------------------------------------------------------------------
# Root credential secret pre-check
# ---------------------------------------------------------------------------

@test "migration/restore fails fast when the root credential secret does not exist" {
  run_migration_restore DRY_RUN=false CONFIRM=true \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated \
    MOCK_BACKUP_EXISTS=1 MOCK_TARGET_EXISTS=0 MOCK_ROOT_SECRET_MISSING=1
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"root credential secret"*"not found"* ]]
  # Fails before creating anything.
  [ ! -f "${CAPTURE}" ]
}

@test "migration/restore does not check the root secret in dry_run" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    MOCK_ROOT_SECRET_MISSING=1
  [ "$status" -eq 0 ]
  [ "$(result_field '.status')" = "success" ]
}

# ---------------------------------------------------------------------------
# root_secret_name / root_secret_key — migration-relayed credential override
# ---------------------------------------------------------------------------

@test "migration/restore defaults root_secret_name/root_secret_key to mariadb/password" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    RESTORE_TARGET=mariadb-migrated
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.credentialsRef.secretName')" = "mariadb" ]
  [ "$(result_field '.data.credentialsRef.secretKey')" = "password" ]
  [ "$(result_field '.data.manifest | fromjson | .spec.rootPasswordSecretKeyRef.name')" = "mariadb" ]
  [ "$(result_field '.data.manifest | fromjson | .spec.rootPasswordSecretKeyRef.key')" = "password" ]
}

@test "migration/restore an explicit root_secret_name/root_secret_key overrides the default" {
  run_migration_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    RESTORE_TARGET=mariadb-migrated \
    ROOT_SECRET_NAME=migration-job-1-source-creds ROOT_SECRET_KEY=root_password
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.credentialsRef.secretName')" = "migration-job-1-source-creds" ]
  [ "$(result_field '.data.credentialsRef.secretKey')" = "root_password" ]
  [ "$(result_field '.data.manifest | fromjson | .spec.rootPasswordSecretKeyRef.name')" = "migration-job-1-source-creds" ]
  [ "$(result_field '.data.manifest | fromjson | .spec.rootPasswordSecretKeyRef.key')" = "root_password" ]
}

@test "migration/restore root-secret pre-check queries the overridden root_secret_name, not the default" {
  run_migration_restore DRY_RUN=false CONFIRM=true \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated \
    MOCK_BACKUP_EXISTS=1 MOCK_TARGET_EXISTS=0 \
    ROOT_SECRET_NAME=migration-job-1-source-creds
  [ "$status" -eq 0 ]
  [ -f "${KUBECTL_LOG}" ]
  grep -q "get secret migration-job-1-source-creds" "${KUBECTL_LOG}"
  ! grep -q "get secret mariadb$" "${KUBECTL_LOG}"
}

@test "migration/restore fails fast when the overridden root_secret_name does not exist" {
  run_migration_restore DRY_RUN=false CONFIRM=true \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated \
    MOCK_BACKUP_EXISTS=1 MOCK_TARGET_EXISTS=0 \
    ROOT_SECRET_NAME=migration-job-1-source-creds MOCK_ROOT_SECRET_MISSING=1
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"migration-job-1-source-creds"*"not found"* ]]
  [ ! -f "${CAPTURE}" ]
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

@test "migration/restore never puts minio_secret_key in a kubectl argv element" {
  run_migration_restore DRY_RUN=false CONFIRM=true \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated \
    MOCK_BACKUP_EXISTS=1 MOCK_TARGET_EXISTS=0 \
    MINIO_SECRET_KEY="supersecret-do-not-expose"
  [ "$status" -eq 0 ]
  [ -f "${KUBECTL_LOG}" ]
  run grep -F "supersecret-do-not-expose" "${KUBECTL_LOG}"
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

@test "migration/restore fails when the backup existence check errors (not just not-found)" {
  run_migration_restore DRY_RUN=false CONFIRM=true \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated \
    MOCK_S5_AUTH_FAIL=1 MOCK_TARGET_EXISTS=0
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"failed to verify backup"* ]]
  [[ "$(result_field '.message')" == *"minio_access_key"* ]]
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
    = "mariadb-migrated.mariadb-dest.svc.cluster.local" ]
}

@test "migration/restore leaves the temp credential secret in place when the Ready wait times out" {
  run_migration_restore DRY_RUN=false CONFIRM=true \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated \
    MOCK_BACKUP_EXISTS=1 MOCK_TARGET_EXISTS=0 MOCK_WAIT_FAIL=1
  [ "$status" -ne 0 ]
  # The operator may still be reading it — deleting now would guarantee a
  # failure on what might otherwise be a slow-but-recoverable restore.
  [ ! -f "${DELETES}" ]
  [[ "$(result_field '.message')" == *"left in place"* ]]
}

@test "migration/restore deletes the temp credential secret once Ready is confirmed" {
  run_migration_restore DRY_RUN=false CONFIRM=true \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated \
    MOCK_BACKUP_EXISTS=1 MOCK_TARGET_EXISTS=0
  [ "$status" -eq 0 ]
  [ -f "${DELETES}" ]
  grep -q "delete secret" "${DELETES}"
}

@test "migration/restore rejects wait_timeout=0" {
  run_migration_restore DRY_RUN=false CONFIRM=true \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi RESTORE_TARGET=mariadb-migrated \
    WAIT_TIMEOUT=0 MOCK_BACKUP_EXISTS=1 MOCK_TARGET_EXISTS=0 MOCK_WAIT_FAIL=1
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"wait_timeout=0"* ]]
  # Rejected before anything is applied.
  [ ! -f "${CAPTURE}" ]
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
