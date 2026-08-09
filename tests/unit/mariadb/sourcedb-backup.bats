#!/usr/bin/env bats
#
# Contract tests for mariadb/migration/sourcedb-backup.sh.
#
# Run the script directly with mock `kubectl` — no cluster, no MinIO.
# Locked-down behaviours:
#   - all minio_* params are required task inputs
#   - source MariaDB must be Ready before a physical backup is attempted
#   - the temp credential Secret is created atomically (no dry-run|apply) and
#     always cleaned up on exit, including on failure paths
#   - wait_timeout="0" is rejected: the temp Secret is deleted on exit, so the
#     operator must be given time to read it first
#   - minio_secret_key never appears in the result JSON
#   - the PhysicalBackup manifest's S3 location matches the task inputs

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  BACKUP_SH="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/migration/sourcedb-backup.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"

  MOCK_DIR="$(mktemp -d)"
  CAPTURE="${MOCK_DIR}/applied.yaml"
  DELETES="${MOCK_DIR}/deletes.log"
  RESULT="${MOCK_DIR}/result.json"

  # --- kubectl mock -----------------------------------------------------------
  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
# Minimal kubectl mock for migration/sourcedb-backup unit tests:
#   get mariadb (jsonpath items[*])       → auto-detect (MOCK_CR_NAMES)
#   get mariadb <name> -o json            → Ready check (MOCK_SOURCE_READY / MOCK_SOURCE_NOT_FOUND)
#   get physicalbackup/<name> -o json     → status probe (MOCK_PB_STATUS / MOCK_PB_CONDITIONS)
#   create secret ...                     → success (or fail with MOCK_CREATE_SECRET_FAIL=1)
#   apply -f -                            → capture stdin (PhysicalBackup only)
#   delete secret                         → logged to DELETES, always succeeds
#   wait                                  → Complete wait (fails with MOCK_WAIT_FAIL=1)
args="$*"
verb=""
for a in "$@"; do
  case "$a" in get|apply|wait|create|delete) verb="$a"; break ;; esac
done
case "$verb" in
  get)
    case "$args" in
      *"physicalbackup"*)
        # The script extracts the CR's .status subresource via `jq '.status // {}'`
        # before reading .status/.conditions from it, so nest one level here.
        jq -n \
          --arg status "${MOCK_PB_STATUS:-}" \
          --argjson conditions "${MOCK_PB_CONDITIONS:-[]}" \
          '{status: {status: (if $status == "" then null else $status end), conditions: $conditions}}'
        exit 0 ;;
      *"items[*]"*)
        printf '%s' "${MOCK_CR_NAMES-mariadb}" | tr ' ' '\n' | sed '/^$/d'
        exit 0 ;;
      *"mariadb"*"-o json"*)
        if [[ "${MOCK_SOURCE_NOT_FOUND:-0}" == "1" ]]; then
          echo 'Error from server (NotFound): mariadbs.k8s.mariadb.com "x" not found' >&2
          exit 1
        fi
        jq -n --arg ready "${MOCK_SOURCE_READY:-True}" \
          '{status: {conditions: [{type: "Ready", status: $ready}]}}'
        exit 0 ;;
      *) echo "mock kubectl: unhandled get: $args" >&2; exit 1 ;;
    esac ;;
  create)
    [[ "${MOCK_CREATE_SECRET_FAIL:-0}" == "1" ]] && exit 1
    exit 0 ;;
  apply)
    _input=$(cat)
    if echo "$_input" | jq -e '.kind == "PhysicalBackup"' >/dev/null 2>&1; then
      echo "$_input" > "${MOCK_APPLY_CAPTURE}"
    fi
    exit 0 ;;
  delete)
    [[ -n "${MOCK_DELETE_LOG:-}" ]] && printf '%s\n' "$args" >> "${MOCK_DELETE_LOG}"
    exit 0 ;;
  wait)
    [[ "${MOCK_WAIT_FAIL:-0}" == "1" ]] && exit 1 || exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/kubectl"

  # Required env for every test.
  export MARIADB_NAME=mariadb
  export DB_NAMESPACE="mariadb-source"
  export MINIO_ENDPOINT="http://minio.example.test:9000"
  export MINIO_ACCESS_KEY="testkey"
  export MINIO_SECRET_KEY="testsecret"
  export MINIO_BUCKET="db-backups"
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

# run_sourcedb_backup [KEY=VALUE ...] — run with the mock kubectl on PATH.
run_sourcedb_backup() {
  run env "PATH=${MOCK_DIR}:${PATH}" \
    "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" \
    "MOCK_APPLY_CAPTURE=${CAPTURE}" \
    "MOCK_DELETE_LOG=${DELETES}" \
    "$@" \
    bash "${BACKUP_SH}"
}

result_field() { jq -r "$1" "${RESULT}"; }

# ---------------------------------------------------------------------------
# Confirm gate
# ---------------------------------------------------------------------------

@test "sourcedb-backup requires confirm=true to apply" {
  run_sourcedb_backup DRY_RUN=false CONFIRM=false
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"confirm=true is required"* ]]
}

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------

@test "sourcedb-backup dry_run renders manifest without confirm or apply" {
  run_sourcedb_backup DRY_RUN=true CONFIRM=false
  [ "$status" -eq 0 ]
  [ "$(result_field '.status')" = "success" ]
  [ "$(result_field '.data.dryRun')" = "true" ]
  [ "$(result_field '.data.created')" = "false" ]
  # No K8s resources touched: capture file must not exist.
  [ ! -f "${CAPTURE}" ]
  [ ! -f "${DELETES}" ]
  [ "$(result_field '.data.manifest | fromjson | .kind')" = "PhysicalBackup" ]
}

@test "sourcedb-backup dry_run manifest carries the MinIO location" {
  run_sourcedb_backup DRY_RUN=true
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.manifest | fromjson | .spec.storage.s3.bucket')" = "db-backups" ]
  [ "$(result_field '.data.manifest | fromjson | .spec.storage.s3.prefix')" = "mariadb/mariadb-source" ]
}

@test "sourcedb-backup dry_run auto-generates a migration-marked backup name" {
  run_sourcedb_backup DRY_RUN=true
  [ "$status" -eq 0 ]
  local name
  name="$(result_field '.data.backupName')"
  [[ "$name" =~ ^mariadb-migration-[0-9]+$ ]]
}

@test "sourcedb-backup dry_run skips the readiness-check kubectl call when 'mariadb' is given" {
  # Only proves kubectl is skipped for the readiness check when MARIADB_NAME
  # is already known — NOT a general "dry run never calls kubectl" guarantee:
  # the auto-detect tests below show dry_run DOES call kubectl to list CRs
  # when 'mariadb' is omitted.
  run_sourcedb_backup DRY_RUN=true MOCK_SOURCE_NOT_FOUND=1
  # If the readiness check touched kubectl, the forced NotFound mock would fail the run.
  [ "$status" -eq 0 ]
  [ "$(result_field '.status')" = "success" ]
}

# ---------------------------------------------------------------------------
# MinIO input validation
# ---------------------------------------------------------------------------

@test "sourcedb-backup fails when minio_endpoint is missing" {
  run_sourcedb_backup DRY_RUN=true MINIO_ENDPOINT=""
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"minio_endpoint"*"required"* ]]
}

@test "sourcedb-backup fails when minio_access_key is missing" {
  run_sourcedb_backup DRY_RUN=true MINIO_ACCESS_KEY=""
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"minio_access_key"*"required"* ]]
}

@test "sourcedb-backup fails when minio_secret_key is missing" {
  run_sourcedb_backup DRY_RUN=true MINIO_SECRET_KEY=""
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"minio_secret_key"*"required"* ]]
}

@test "sourcedb-backup fails when minio_bucket is missing" {
  run_sourcedb_backup DRY_RUN=true MINIO_BUCKET=""
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"minio_bucket"*"required"* ]]
}

@test "sourcedb-backup fails on a malformed minio_endpoint" {
  run_sourcedb_backup DRY_RUN=true MINIO_ENDPOINT="not a url"
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"minio_endpoint"* ]]
}

# ---------------------------------------------------------------------------
# MinIO — deploy-time MINIO_*_DEFAULT fallback
# ---------------------------------------------------------------------------

@test "sourcedb-backup falls back to MINIO_ENDPOINT_DEFAULT when minio_endpoint is omitted" {
  run_sourcedb_backup DRY_RUN=true \
    MINIO_ENDPOINT="" MINIO_ENDPOINT_DEFAULT="http://minio.example.test:9000"
  [ "$status" -eq 0 ]
  [ "$(result_field '.status')" = "success" ]
  [ "$(result_field '.data.manifest | fromjson | .spec.storage.s3.endpoint')" \
    = "minio.example.test:9000" ]
}

@test "sourcedb-backup an explicit minio_endpoint overrides MINIO_ENDPOINT_DEFAULT" {
  run_sourcedb_backup DRY_RUN=true \
    MINIO_ENDPOINT="http://explicit.minio.test:9000" \
    MINIO_ENDPOINT_DEFAULT="http://default.minio.test:9000"
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.manifest | fromjson | .spec.storage.s3.endpoint')" \
    = "explicit.minio.test:9000" ]
}

@test "sourcedb-backup falls back to MINIO_ACCESS_KEY_DEFAULT/MINIO_SECRET_KEY_DEFAULT/MINIO_BUCKET_DEFAULT" {
  run_sourcedb_backup DRY_RUN=true \
    MINIO_ACCESS_KEY="" MINIO_SECRET_KEY="" MINIO_BUCKET="" \
    MINIO_ACCESS_KEY_DEFAULT=minioadmin MINIO_SECRET_KEY_DEFAULT=minioadmin123 \
    MINIO_BUCKET_DEFAULT=db-backups
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.manifest | fromjson | .spec.storage.s3.bucket')" = "db-backups" ]
}

@test "sourcedb-backup still fails clearly when neither minio_endpoint nor a default is set" {
  run_sourcedb_backup DRY_RUN=true MINIO_ENDPOINT=""
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"minio_endpoint"*"required"* ]]
}

# ---------------------------------------------------------------------------
# wait_timeout=0 rejection
# ---------------------------------------------------------------------------

@test "sourcedb-backup rejects wait_timeout=0" {
  run_sourcedb_backup DRY_RUN=false CONFIRM=true WAIT_TIMEOUT=0
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"wait_timeout=0"* ]]
  # Rejected before anything is applied.
  [ ! -f "${CAPTURE}" ]
}

# ---------------------------------------------------------------------------
# target / compression validation
# ---------------------------------------------------------------------------

@test "sourcedb-backup fails on an invalid target" {
  run_sourcedb_backup DRY_RUN=true BACKUP_TARGET=Everywhere
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"target"* ]]
}

@test "sourcedb-backup fails on an invalid compression" {
  run_sourcedb_backup DRY_RUN=true BACKUP_COMPRESSION=zstd
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"compression"* ]]
}

# ---------------------------------------------------------------------------
# Auto-detection
# ---------------------------------------------------------------------------

@test "sourcedb-backup auto-detects the MariaDB CR when 'mariadb' is omitted" {
  unset MARIADB_NAME
  export MOCK_CR_NAMES="mdb-source"
  run_sourcedb_backup DRY_RUN=true
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.mariadb')" = "mdb-source" ]
}

@test "sourcedb-backup fails when several MariaDB CRs exist and 'mariadb' is omitted" {
  unset MARIADB_NAME
  export MOCK_CR_NAMES="alpha beta"
  run_sourcedb_backup DRY_RUN=true
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"several MariaDB instances"* ]]
}

@test "sourcedb-backup fails when no MariaDB CR exists and 'mariadb' is omitted" {
  unset MARIADB_NAME
  export MOCK_CR_NAMES=""
  run_sourcedb_backup DRY_RUN=true
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"no MariaDB instance found"* ]]
}

# ---------------------------------------------------------------------------
# Real run: source readiness
# ---------------------------------------------------------------------------

@test "sourcedb-backup fails when the source MariaDB is not found" {
  export MOCK_SOURCE_NOT_FOUND=1
  run_sourcedb_backup DRY_RUN=false CONFIRM=true
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"not found"* ]]
  [ ! -f "${CAPTURE}" ]
}

@test "sourcedb-backup fails when the source MariaDB is not Ready" {
  export MOCK_SOURCE_READY=False
  run_sourcedb_backup DRY_RUN=false CONFIRM=true
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"must be Ready"* ]]
  [ ! -f "${CAPTURE}" ]
}

# ---------------------------------------------------------------------------
# Real run: temp Secret lifecycle
# ---------------------------------------------------------------------------

@test "sourcedb-backup fails clearly when temp secret creation fails" {
  export MOCK_CREATE_SECRET_FAIL=1
  run_sourcedb_backup DRY_RUN=false CONFIRM=true
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"failed to create temporary credential secret"* ]]
  [ ! -f "${CAPTURE}" ]
}

@test "sourcedb-backup temp secret name includes a random suffix, not just a timestamp" {
  run_sourcedb_backup DRY_RUN=false CONFIRM=true
  [ "$status" -eq 0 ]
  secret_ref="$(jq -r '.spec.storage.s3.accessKeyIdSecretKeyRef.name' "${CAPTURE}")"
  [[ "$secret_ref" =~ ^migration-backup-creds-[0-9]{14}-[0-9]+-[0-9]+$ ]]
}

@test "sourcedb-backup deletes the temp secret on success" {
  run_sourcedb_backup DRY_RUN=false CONFIRM=true
  [ "$status" -eq 0 ]
  [ -f "${DELETES}" ]
  secret_ref="$(jq -r '.spec.storage.s3.accessKeyIdSecretKeyRef.name' "${CAPTURE}")"
  grep -q "secret ${secret_ref}" "${DELETES}"
}

@test "sourcedb-backup leaves the temp secret in place when the Complete wait times out" {
  export MOCK_WAIT_FAIL=1
  run_sourcedb_backup DRY_RUN=false CONFIRM=true
  [ "$status" -ne 0 ]
  # The PhysicalBackup job may still be running and still need the S3
  # credentials — deleting now would guarantee a failure on what might
  # otherwise be a slow-but-recoverable backup.
  [ ! -f "${DELETES}" ]
  [[ "$(result_field '.message')" == *"left in place"* ]]
}

@test "sourcedb-backup does not attempt secret cleanup when the source is not Ready" {
  export MOCK_SOURCE_READY=False
  run_sourcedb_backup DRY_RUN=false CONFIRM=true
  # Fails before a secret is ever created, so nothing to clean up.
  [ "$status" -ne 0 ]
  [ ! -f "${DELETES}" ]
}

# ---------------------------------------------------------------------------
# Real run: PhysicalBackup manifest content
# ---------------------------------------------------------------------------

@test "sourcedb-backup applies a PhysicalBackup CR with the correct S3 location" {
  run_sourcedb_backup DRY_RUN=false CONFIRM=true
  [ "$status" -eq 0 ]
  [ -f "${CAPTURE}" ]
  [ "$(jq -r '.spec.storage.s3.bucket' "${CAPTURE}")" = "db-backups" ]
  [ "$(jq -r '.spec.storage.s3.prefix' "${CAPTURE}")" = "mariadb/mariadb-source" ]
  [ "$(jq -r '.spec.mariaDbRef.name' "${CAPTURE}")" = "mariadb" ]
}

@test "sourcedb-backup honors an explicit target and compression" {
  run_sourcedb_backup DRY_RUN=false CONFIRM=true BACKUP_TARGET=Primary BACKUP_COMPRESSION=none
  [ "$status" -eq 0 ]
  [ "$(jq -r '.spec.target' "${CAPTURE}")" = "Primary" ]
  [ "$(jq -r '.spec.compression' "${CAPTURE}")" = "none" ]
}

# ---------------------------------------------------------------------------
# Real run: completion outcomes
# ---------------------------------------------------------------------------

@test "sourcedb-backup returns a partial result when the Complete wait times out" {
  export MOCK_WAIT_FAIL=1
  run_sourcedb_backup DRY_RUN=false CONFIRM=true
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"did not Complete within"* ]]
  [ "$(result_field '.data.created')" = "true" ]
}

@test "sourcedb-backup reports failure when the PhysicalBackup status is Failed" {
  export MOCK_PB_STATUS="Failed"
  run_sourcedb_backup DRY_RUN=false CONFIRM=true
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"failed"* ]]
}

@test "sourcedb-backup succeeds when the PhysicalBackup completes cleanly" {
  run_sourcedb_backup DRY_RUN=false CONFIRM=true
  [ "$status" -eq 0 ]
  [ "$(result_field '.status')" = "success" ]
  [ "$(result_field '.data.created')" = "true" ]
  [ "$(result_field '.data.dryRun')" = "false" ]
}

# ---------------------------------------------------------------------------
# Credential safety
# ---------------------------------------------------------------------------

@test "sourcedb-backup dry_run result does not expose minio_secret_key" {
  run_sourcedb_backup DRY_RUN=true MINIO_SECRET_KEY="supersecret-do-not-expose"
  [ "$status" -eq 0 ]
  [[ "$output" != *"supersecret-do-not-expose"* ]]
  run grep "supersecret-do-not-expose" "${RESULT}"
  [ "$status" -ne 0 ]
}

@test "sourcedb-backup real run result does not expose minio_secret_key" {
  run_sourcedb_backup DRY_RUN=false CONFIRM=true MINIO_SECRET_KEY="supersecret-do-not-expose"
  [ "$status" -eq 0 ]
  [[ "$output" != *"supersecret-do-not-expose"* ]]
  run grep "supersecret-do-not-expose" "${RESULT}"
  [ "$status" -ne 0 ]
  run grep "supersecret-do-not-expose" "${CAPTURE}"
  [ "$status" -ne 0 ]
}
