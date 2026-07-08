#!/usr/bin/env bats
#
# Contract tests for mariadb/physical-backup.sh.
#
# Run the script directly against a mock `kubectl` — no cluster, no MinIO, no
# operator. They lock down the user-oriented surface and the PhysicalBackup CR
# the task renders:
#   - namespace is the only required input; the S3 location + credentials are
#     internal (resolved via mdbt_resolve_backup_location), not task inputs
#   - the instance to back up is auto-detected from the namespace (or given)
#   - confirm=true is mandatory to apply; dry_run (default) only renders
#   - the source must exist and be Ready before a backup is created
#   - wait_timeout doubles as the wait switch ("0" = don't wait); a Complete-wait
#     timeout still returns a partial result instead of losing it
#   - the backup is written to the same convention restore reads (mariadb/<ns>)
#
# A live backup -> restore round-trip belongs in the e2e suite (#48).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  BACKUP_SH="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/physical-backup.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"

  MOCK_DIR="$(mktemp -d)"
  CAPTURE="${MOCK_DIR}/applied.json"
  RESULT="${MOCK_DIR}/result.json"

  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
# Minimal kubectl mock:
#   get ... {range .items...metadata.name}  → source auto-detect list (MOCK_SOURCES)
#   get <name> -o json                       → source status (MOCK_READY, MOCK_FOUND)
#   apply                                    → capture stdin
#   wait                                     → Complete wait (fails with MOCK_WAIT_FAIL=1)
args="$*"
verb=""
for a in "$@"; do
  case "$a" in get|apply|wait) verb="$a"; break ;; esac
done
case "$verb" in
  get)
    case "$args" in
      *crd*jsonpath*|*jsonpath*crd*) printf 'k8s.mariadb.com\n';  exit 0 ;;   # operator-group detect
      *"get crd "*|*" crd "*) exit 0 ;;                                       # physicalbackups CRD present (operator path)
      *metadata.name*) printf '%s' "${MOCK_SOURCES:-}";        exit 0 ;;   # resolve-name list
      *"-o json"*)
        # MOCK_GET_ERR=1 → simulate a real kubectl failure (perms/connectivity);
        # MOCK_FOUND=0 → simulate a genuine NotFound.
        [[ "${MOCK_GET_ERR:-0}" == "1" ]] && { echo "Unable to connect to the server: dial tcp: timeout" >&2; exit 1; }
        [[ "${MOCK_FOUND:-1}" == "1" ]] || { echo "Error from server (NotFound): mariadbs.k8s.mariadb.com not found" >&2; exit 1; }
        jq -n --arg r "${MOCK_READY:-True}" \
          '{status: {conditions: [{type: "Ready", status: $r}]}}';   exit 0 ;;
      *) echo "mock kubectl: unhandled get: $args" >&2;       exit 1 ;;
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

@test "physical-backup requires confirm=true to apply" {
  run_backup DRY_RUN=false CONFIRM=false MARIADB_NAME=mariadb
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"confirm=true is required"* ]]
}

@test "physical-backup dry_run renders the manifest without confirm or apply" {
  run_backup DRY_RUN=true CONFIRM=false MARIADB_NAME=mariadb
  [ "$status" -eq 0 ]
  [ "$(result_field '.status')" = "success" ]
  [ "$(result_field '.data.dryRun')" = "true" ]
  [ "$(result_field '.data.created')" = "false" ]
  [ ! -f "${CAPTURE}" ]
  [ "$(result_field '.data.manifest | fromjson | .kind')" = "PhysicalBackup" ]
}

@test "physical-backup resolves internals and writes to the shared convention" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.created')" = "true" ]
  [ "$(result_field '.data.backup.contentType')" = "Physical" ]
  [ "$(result_field '.data.restorableBy.task')" = "restore" ]
  [ "$(jq -r '.kind' "${CAPTURE}")" = "PhysicalBackup" ]
  [ "$(jq -r '.spec.mariaDbRef.name' "${CAPTURE}")" = "mariadb" ]
  [ "$(jq -r '.spec.storage.s3.prefix' "${CAPTURE}")" = "mariadb/mariadb-1" ]
  [ "$(jq -r '.spec.storage.s3.bucket' "${CAPTURE}")" = "db-backups" ]
  [ "$(jq -r '.spec.storage.s3.tls.enabled' "${CAPTURE}")" = "false" ]
}

@test "physical-backup auto-detects the single instance when omitted" {
  run_backup DRY_RUN=false CONFIRM=true MOCK_SOURCES=mariadb
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.mariadb')" = "mariadb" ]
  [ "$(jq -r '.metadata.name' "${CAPTURE}")" != "null" ]
}

@test "physical-backup fails when no instance can be auto-detected" {
  run_backup DRY_RUN=false CONFIRM=true MOCK_SOURCES=""
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"no MariaDB instance found"* ]]
}

@test "physical-backup fails (not guesses) when several instances exist and 'mariadb' is omitted" {
  run_backup DRY_RUN=false CONFIRM=true MOCK_SOURCES=$'mariadb-a\nmariadb-b'
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"several MariaDB instances"* ]]
}

@test "physical-backup fails when the source is not Ready" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb MOCK_READY=False
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"must be Ready"* ]]
}

@test "physical-backup fails when the source does not exist" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb MOCK_FOUND=0
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"not found"* ]]
}

@test "physical-backup surfaces a real kubectl error instead of reporting not-found" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb MOCK_GET_ERR=1
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"failed to query source MariaDB"* ]]
  [[ "$(result_field '.message')" != *"not found"* ]]
}

@test "physical-backup rejects an invalid target" {
  run_backup DRY_RUN=true MARIADB_NAME=mariadb BACKUP_TARGET=Bogus
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"target"* ]]
}

@test "physical-backup returns a partial result (not lost) when the Complete wait times out" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb MOCK_WAIT_FAIL=1
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"did not Complete"* ]]
  [ "$(result_field '.data.backup.contentType')" = "Physical" ]
}

@test "physical-backup with wait_timeout=0 applies without waiting" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb WAIT_TIMEOUT=0 MOCK_WAIT_FAIL=1
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.created')" = "true" ]
}

@test "physical-backup resolves the S3 endpoint from deploy-time config" {
  cat > "${MOCK_DIR}/mariadb.env" <<EOF
MINIO_ENDPOINT=http://minio.kind-b.test:30080
EOF
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb \
    MDBT_CONFIG_FILE="${MOCK_DIR}/mariadb.env"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.spec.storage.s3.endpoint' "${CAPTURE}")" = "minio.kind-b.test:30080" ]
}
