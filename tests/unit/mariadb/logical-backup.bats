#!/usr/bin/env bats
#
# Contract tests for mariadb/logical-backup.sh.
#
# Run the script directly against a mock `kubectl` — no cluster, no MinIO, no
# operator. They lock down the sanitized user-oriented surface and, separately,
# the internal operator `Backup` CR applied through kubectl:
#   - namespace is the only required input; the S3 location + credentials are
#     internal (resolved via mdbt_resolve_backup_location), not task inputs
#   - the instance to back up is auto-detected from the namespace
#   - logical backups land under a DISTINCT prefix (mariadb-logical/<ns>) so they
#     never collide with the physical ones under mariadb/<ns>
#   - confirm=true is mandatory to apply; dry_run (default) returns only a
#     high-level plan result and never exposes the rendered manifest
#   - the Backup CRD must exist (fail fast, not `no matches for kind`)
#   - the source must exist and be Ready before a backup is created
#   - wait_timeout doubles as the wait switch ("0" = don't wait); a Complete-wait
#     timeout still returns a partial result instead of losing it

setup() {
  unset MARIADB_OPERATOR_GROUP_DEFAULT _MDB_OPERATOR_GROUP
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  BACKUP_SH="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/logical-backup.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"

  MOCK_DIR="$(mktemp -d)"
  CAPTURE="${MOCK_DIR}/applied.json"
  RESULT="${MOCK_DIR}/result.json"

  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
# Minimal kubectl mock:
#   api-resources                   → operator discovery (MOCK_NO_CRD=1 omits Backup)
#   get ... {range .items...name}   → source auto-detect list (MOCK_SOURCES)
#   get <name> -o json              → source status (MOCK_READY, MOCK_FOUND)
#   apply                           → capture stdin
#   wait                            → Complete wait (fails with MOCK_WAIT_FAIL=1)
args="$*"
verb=""
for a in "$@"; do
  case "$a" in api-resources|get|apply|wait) verb="$a"; break ;; esac
done
case "$verb" in
  api-resources)
    [[ "${MOCK_API_FAIL:-0}" == "1" ]] && exit 1
    group="${MOCK_OPERATOR_GROUP:-k8s.mariadb.com}"
    printf 'mariadbs.%s\n' "$group"
    [[ "${MOCK_NO_CRD:-0}" == "1" ]] || printf 'backups.%s\n' "$group"
    exit 0 ;;
  get)
    case "$args" in
      *metadata.name*) printf '%s' "${MOCK_SOURCES:-}";                exit 0 ;;   # resolve-name list
      *"-o json"*)
        [[ "${MOCK_GET_ERR:-0}" == "1" ]] && { echo "Unable to connect to the server: dial tcp: timeout" >&2; exit 1; }
        [[ "${MOCK_FOUND:-1}" == "1" ]] || { echo "Error from server (NotFound): mariadbs.k8s.mariadb.com not found" >&2; exit 1; }
        jq -n --arg r "${MOCK_READY:-True}" \
          '{status: {conditions: [{type: "Ready", status: $r}]}}';    exit 0 ;;
      *) echo "mock kubectl: unhandled get: $args" >&2;               exit 1 ;;
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

run_backup() {
  run env "PATH=${MOCK_DIR}:${PATH}" \
    "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" \
    "MOCK_APPLY_CAPTURE=${CAPTURE}" \
    "$@" \
    bash "${BACKUP_SH}"
}

result_field() { jq -r "$1" "${RESULT}"; }

assert_public_backup_data() {
  jq -e '
    (.data | keys) ==
    ["backupName", "contentType", "created", "dryRun", "namespace", "state"]
  ' "${RESULT}" >/dev/null
}

assert_response_hides() {
  local combined marker
  combined="$(cat "${RESULT}")"$'\n'"${output:-}"
  for marker in "$@"; do
    [[ "$combined" != *"$marker"* ]]
  done
}

@test "logical-backup requires confirm=true to apply" {
  run_backup DRY_RUN=false CONFIRM=false MARIADB_NAME=mariadb
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [ "$(result_field '.reason')" = "INVALID_REQUEST" ]
  [[ "$(result_field '.message')" == *"confirm=true is required"* ]]
}

@test "logical-backup dry_run returns only the sanitized plan summary" {
  run_backup DRY_RUN=true CONFIRM=false MARIADB_NAME=mariadb \
    BACKUP_ENDPOINT=https://private-logical-storage.example.invalid \
    BACKUP_BUCKET=private-logical-bucket \
    BACKUP_PREFIX=private/logical-prefix \
    BACKUP_REGION=private-logical-region \
    BACKUP_ACCESS_SECRET=private-logical-access-secret \
    BACKUP_ACCESS_KEY=private-logical-access-key \
    BACKUP_SECRET_ACCESS_SECRET=private-logical-secret-secret \
    BACKUP_SECRET_KEY=private-logical-secret-key
  [ "$status" -eq 0 ]
  [ "$(result_field '.status')" = "success" ]
  [ "$(result_field '.data.dryRun')" = "true" ]
  [ "$(result_field '.data.created')" = "false" ]
  [ "$(result_field '.data.state')" = "PLANNED" ]
  [ "$(result_field '.data.contentType')" = "Logical" ]
  assert_public_backup_data
  [ ! -f "${CAPTURE}" ]
  assert_response_hides \
    private-logical-storage.example.invalid private-logical-bucket \
    private/logical-prefix private-logical-region private-logical-access-secret \
    private-logical-access-key private-logical-secret-secret \
    private-logical-secret-key manifest plan credentialsRef secretKeyRef \
    k8s.mariadb.com
}

@test "logical-backup writes to the distinct logical prefix and marks contentType Logical" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb
  [ "$status" -eq 0 ]
  assert_public_backup_data
  [ "$(result_field '.data.created')" = "true" ]
  [ "$(result_field '.data.contentType')" = "Logical" ]
  [ "$(result_field '.data.state')" = "COMPLETED" ]
  [ "$(jq -r '.kind' "${CAPTURE}")" = "Backup" ]
  [ "$(jq -r '.spec.mariaDbRef.name' "${CAPTURE}")" = "mariadb" ]
  [ "$(jq -r '.spec.storage.s3.prefix' "${CAPTURE}")" = "mariadb-logical/mariadb-1" ]
  [ "$(jq -r '.spec.storage.s3.bucket' "${CAPTURE}")" = "db-backups" ]
}

@test "legacy logical-backup omits the unsupported S3 prefix" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb \
    MOCK_OPERATOR_GROUP=mariadb.mmontes.io
  [ "$status" -eq 0 ]
  assert_public_backup_data
  [ "$(jq -r '.apiVersion' "${CAPTURE}")" = "mariadb.mmontes.io/v1alpha1" ]
  [ "$(jq -r '.spec.storage.s3 | has("prefix")' "${CAPTURE}")" = "false" ]
  assert_response_hides mariadb.mmontes.io prefixSupported storageLayout bucket-root
}

@test "logical-backup fails closed when operator discovery is unavailable" {
  run_backup DRY_RUN=true MARIADB_NAME=mariadb MOCK_API_FAIL=1
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [ "$(result_field '.reason')" = "BACKUP_CAPABILITY_UNAVAILABLE" ]
  assert_response_hides operator apiVersion CRD discovery k8s.mariadb.com mariadb.mmontes.io
}

@test "logical-backup hides invalid platform storage settings" {
  run_backup DRY_RUN=true MARIADB_NAME=mariadb \
    BACKUP_ENDPOINT=https://private-logical-storage.example.invalid \
    BACKUP_ACCESS_SECRET=Invalid_Logical_Secret
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [ "$(result_field '.reason')" = "BACKUP_CONFIGURATION_UNAVAILABLE" ]
  assert_response_hides private-logical-storage.example.invalid \
    Invalid_Logical_Secret backup_access_secret secretKeyRef Secret
}

@test "logical-backup manifest omits physical-only fields (compression/target) for legacy compat" {
  run_backup DRY_RUN=false CONFIRM=true WAIT_TIMEOUT=0 MARIADB_NAME=mariadb
  [ "$status" -eq 0 ]
  [ "$(jq -r '.spec | has("compression")' "${CAPTURE}")" = "false" ]
  [ "$(jq -r '.spec | has("target")' "${CAPTURE}")" = "false" ]
  assert_public_backup_data
}

@test "logical-backup auto-detects the single instance when omitted" {
  run_backup DRY_RUN=false CONFIRM=true MOCK_SOURCES=mariadb
  [ "$status" -eq 0 ]
  assert_public_backup_data
  [ "$(jq -r '.spec.mariaDbRef.name' "${CAPTURE}")" = "mariadb" ]
}

@test "logical-backup fails without exposing candidates when several instances exist" {
  run_backup DRY_RUN=false CONFIRM=true MOCK_SOURCES=$'mariadb-a\nmariadb-b'
  [ "$status" -ne 0 ]
  [ "$(result_field '.reason')" = "DATABASE_CONFIGURATION_AMBIGUOUS" ]
  assert_response_hides mariadb-a mariadb-b
}

@test "logical-backup fails fast when the Backup CRD is absent" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb MOCK_NO_CRD=1
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [ "$(result_field '.reason')" = "BACKUP_CAPABILITY_UNAVAILABLE" ]
  assert_response_hides CRD apiVersion operator k8s.mariadb.com
}

@test "logical-backup fails when the source is not Ready" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb MOCK_READY=False
  [ "$status" -ne 0 ]
  [ "$(result_field '.reason')" = "DATABASE_NOT_READY" ]
}

@test "logical-backup fails when the source does not exist" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb MOCK_FOUND=0
  [ "$status" -ne 0 ]
  [ "$(result_field '.reason')" = "DATABASE_NOT_FOUND" ]
  assert_response_hides mariadbs.k8s.mariadb.com
}

@test "logical-backup returns a partial result (not lost) when the Complete wait times out" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb MOCK_WAIT_FAIL=1
  [ "$status" -ne 0 ]
  [ "$(result_field '.reason')" = "BACKUP_TIMEOUT" ]
  assert_public_backup_data
  [ "$(result_field '.data.contentType')" = "Logical" ]
  [ "$(result_field '.data.state')" = "PENDING" ]
}

@test "logical-backup with wait_timeout=0 applies without waiting" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb WAIT_TIMEOUT=0 MOCK_WAIT_FAIL=1
  [ "$status" -eq 0 ]
  assert_public_backup_data
  [ "$(result_field '.data.created')" = "true" ]
  [ "$(result_field '.data.state')" = "REQUESTED" ]
}
