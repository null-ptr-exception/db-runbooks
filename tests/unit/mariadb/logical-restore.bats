#!/usr/bin/env bats
#
# Contract tests for mariadb/logical-restore.sh.
#
# Run the script directly against a mock `kubectl` — no cluster, no operator.
# They lock down the user-oriented surface and the private manifest used to
# apply the restore:
#   - namespace is the only required input; version/storage/name/source Backup
#     are resolved internally (RESTORE_* / STORAGE_SIZE are advanced overrides)
#   - AWS-style: provisions a NEW instance via bootstrapFrom.backupRef, never
#     overwrites in place
#   - the source Backup is chosen by name, else the most recent Backup CR
#   - the Backup CRD must exist (fail fast, not `no matches for kind`)
#   - confirm=true is mandatory to apply; dry_run (default) returns a sanitized
#     plan and never returns the rendered manifest
#   - wait_timeout doubles as the wait switch ("0" = don't wait); a Ready-wait
#     timeout still returns a partial result

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  RESTORE_SH="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/logical-restore.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"

  MOCK_DIR="$(mktemp -d)"
  CAPTURE="${MOCK_DIR}/applied.json"
  WAIT_CAPTURE="${MOCK_DIR}/waits.txt"
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
  apply)
    if [[ "${MOCK_APPLY_FAIL:-0}" == "1" ]]; then
      printf '%s\n' "${MOCK_APPLY_ERROR:-private-apply-diagnostic}" >&2
      exit 1
    fi
    cat > "${MOCK_APPLY_CAPTURE}"
    exit 0 ;;
  wait)
    printf '%s\n' "$args" >> "${MOCK_WAIT_CAPTURE}"
    if [[ "$args" == *BackupRestored* && -n "${MOCK_FIRST_WAIT_DELAY:-}" ]]; then
      sleep "${MOCK_FIRST_WAIT_DELAY}"
    fi
    [[ "${MOCK_WAIT_FAIL:-0}" == "1" ]] && exit 1 || exit 0 ;;
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
    "MOCK_WAIT_CAPTURE=${WAIT_CAPTURE}" \
    "$@" \
    bash "${RESTORE_SH}"
}

result_field() { jq -r "$1" "${RESULT}"; }

assert_public_result_contract() {
  [ "$(jq -c '.data | keys | sort' "${RESULT}")" = \
    '["contentType","dryRun","namespace","provisioned","restored","state"]' ]
  [ "$(result_field '.data.namespace')" = "mariadb-1" ]
  [ "$(result_field '.data.contentType')" = "Logical" ]
}

assert_result_hides_internals() {
  [ "$(jq -r '.data | has("manifest") or has("target") or has("source") or has("image") or has("backup") or has("connection") or has("credentialsRef")' "${RESULT}")" = "false" ]
}

assert_error_reason() {
  [ "$(result_field '.status')" = "error" ]
  [ "$(result_field '.reason')" = "$1" ]
}

@test "logical-restore requires confirm=true to apply" {
  run_restore DRY_RUN=false CONFIRM=false RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi
  [ "$status" -ne 0 ]
  assert_error_reason INVALID_REQUEST
}

@test "logical-restore dry_run returns only a sanitized plan" {
  run_restore DRY_RUN=true BACKUP_NAME=logical-choice RESTORE_TARGET=private-target \
    RESTORE_IMAGE=private.registry.invalid/mariadb:11.4 STORAGE_SIZE=1Gi
  [ "$status" -eq 0 ]
  assert_public_result_contract
  assert_result_hides_internals
  [ "$(result_field '.data.state')" = "PLANNED" ]
  [ "$(result_field '.data.dryRun')" = "true" ]
  [ "$(result_field '.data.provisioned')" = "false" ]
  [ "$(result_field '.data.restored')" = "false" ]
  ! grep -Fq 'private-target' "${RESULT}"
  ! grep -Fq 'private.registry.invalid' "${RESULT}"
  [ ! -f "${CAPTURE}" ]
}

@test "logical-restore picks the most recent Backup when none is named" {
  export MOCK_BACKUPS=$'2026-07-01T00:00:00Z\tmariadb-logical-old\n2026-07-08T00:00:00Z\tmariadb-logical-new'
  run_restore DRY_RUN=false CONFIRM=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi
  [ "$status" -eq 0 ]
  assert_public_result_contract
  assert_result_hides_internals
  [ "$(result_field '.data.state')" = "COMPLETED" ]
  [ "$(result_field '.data.provisioned')" = "true" ]
  [ "$(result_field '.data.restored')" = "true" ]
  [ "$(jq -r '.spec.bootstrapFrom.backupRef.name' "${CAPTURE}")" = "mariadb-logical-new" ]
}

@test "logical-restore uses an explicitly named Backup" {
  run_restore DRY_RUN=false CONFIRM=true BACKUP_NAME=mariadb-logical-pick \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi MOCK_BACKUP_EXISTS=1
  [ "$status" -eq 0 ]
  assert_public_result_contract
  assert_result_hides_internals
  [ "$(jq -r '.spec.bootstrapFrom.backupRef.name' "${CAPTURE}")" = "mariadb-logical-pick" ]
  ! grep -Fq 'mariadb-logical-pick' "${RESULT}"
}

@test "logical-restore fails when no Backup exists to restore from" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi
  [ "$status" -ne 0 ]
  assert_error_reason BACKUP_NOT_FOUND
  assert_result_hides_internals
}

@test "logical-restore fails when the named Backup is not found" {
  run_restore DRY_RUN=false CONFIRM=true BACKUP_NAME=ghost \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi MOCK_BACKUP_EXISTS=0
  [ "$status" -ne 0 ]
  assert_error_reason BACKUP_NOT_FOUND
  assert_result_hides_internals
  ! grep -Fq 'ghost' "${RESULT}"
}

@test "logical-restore refuses to overwrite an existing target" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-clone BACKUP_NAME=mariadb-logical-x \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi MOCK_BACKUP_EXISTS=1 MOCK_TARGET_EXISTS=1
  [ "$status" -ne 0 ]
  assert_error_reason RESTORE_FAILED
  assert_result_hides_internals
  ! grep -Fq 'mariadb-clone' "${RESULT}"
}

@test "logical-restore fails fast when the Backup CRD is absent" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi MOCK_NO_CRD=1
  [ "$status" -ne 0 ]
  assert_error_reason RESTORE_CAPABILITY_UNAVAILABLE
  ! grep -Eqi 'crd|k8s\.mariadb|mmontes|api.?group' "${RESULT}"
}

@test "logical-restore fails on mixed versions without a source/image override" {
  export MOCK_SOURCE_IMAGES=$'mariadb:10.6\nmariadb:11.4'
  run_restore DRY_RUN=false CONFIRM=true STORAGE_SIZE=1Gi MOCK_BACKUP_EXISTS=1
  [ "$status" -ne 0 ]
  assert_error_reason DATABASE_CONFIGURATION_AMBIGUOUS
  ! grep -Fq 'mariadb:10.6' "${RESULT}"
  ! grep -Fq 'mariadb:11.4' "${RESULT}"
}

@test "logical-restore hides an invalid internal context" {
  run_restore DRY_RUN=true K8S_CONTEXT='private/context-marker' \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi
  [ "$status" -ne 0 ]
  assert_error_reason INTERNAL_ERROR
  [ "$(result_field '.message')" = "database service is unavailable" ]
  ! grep -Fq 'private/context-marker' "${RESULT}"
}

@test "logical-restore validates the optional public backup name" {
  run_restore DRY_RUN=true BACKUP_NAME='not/a-dns-label' \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi
  [ "$status" -ne 0 ]
  assert_error_reason INVALID_REQUEST
}

@test "logical-restore rejects an invalid wait timeout" {
  run_restore DRY_RUN=true WAIT_TIMEOUT='private-timeout-marker' \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi
  [ "$status" -ne 0 ]
  assert_error_reason INVALID_REQUEST
  ! grep -Fq 'private-timeout-marker' "${RESULT}"

  run_restore DRY_RUN=true WAIT_TIMEOUT=0s \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi
  [ "$status" -ne 0 ]
  assert_error_reason INVALID_REQUEST
}

@test "logical-restore accepts a fractional Kubernetes-style wait timeout" {
  run_restore DRY_RUN=true WAIT_TIMEOUT=1500ms \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi
  [ "$status" -eq 0 ]
  assert_public_result_contract
  [ "$(result_field '.data.state')" = "PLANNED" ]
}

@test "logical-restore hides raw apply diagnostics" {
  run_restore DRY_RUN=false CONFIRM=true BACKUP_NAME=mariadb-logical-x \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi MOCK_BACKUP_EXISTS=1 \
    MOCK_APPLY_FAIL=1 MOCK_APPLY_ERROR='private-backend-diagnostic'
  [ "$status" -ne 0 ]
  assert_error_reason RESTORE_FAILED
  assert_result_hides_internals
  ! grep -Fq 'private-backend-diagnostic' "${RESULT}"
}

@test "logical-restore returns a partial result (not lost) when the Ready wait times out" {
  run_restore DRY_RUN=false CONFIRM=true BACKUP_NAME=mariadb-logical-x RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    MOCK_BACKUP_EXISTS=1 MOCK_WAIT_FAIL=1
  [ "$status" -ne 0 ]
  assert_error_reason RESTORE_TIMEOUT
  assert_public_result_contract
  assert_result_hides_internals
  [ "$(result_field '.data.state')" = "PENDING" ]
  [ "$(result_field '.data.provisioned')" = "true" ]
  [ "$(result_field '.data.restored')" = "false" ]
}

@test "logical-restore with wait_timeout=0 applies without waiting" {
  run_restore DRY_RUN=false CONFIRM=true BACKUP_NAME=mariadb-logical-x RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi \
    MOCK_BACKUP_EXISTS=1 WAIT_TIMEOUT=0 MOCK_WAIT_FAIL=1
  [ "$status" -eq 0 ]
  assert_public_result_contract
  assert_result_hides_internals
  [ "$(result_field '.data.state')" = "REQUESTED" ]
  [ "$(result_field '.data.provisioned')" = "true" ]
  [ "$(result_field '.data.restored')" = "false" ]
}

@test "logical-restore shares one timeout budget across both wait conditions" {
  local first_timeout second_timeout
  run_restore DRY_RUN=false CONFIRM=true BACKUP_NAME=mariadb-logical-x \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi MOCK_BACKUP_EXISTS=1 \
    WAIT_TIMEOUT=5s MOCK_FIRST_WAIT_DELAY=2
  [ "$status" -eq 0 ]
  [ "$(wc -l < "${WAIT_CAPTURE}" | tr -d ' ')" = "2" ]
  first_timeout="$(sed -n '1s/.*--timeout=\([0-9][0-9]*\)s.*/\1/p' "${WAIT_CAPTURE}")"
  second_timeout="$(sed -n '2s/.*--timeout=\([0-9][0-9]*\)s.*/\1/p' "${WAIT_CAPTURE}")"
  [ -n "$first_timeout" ]
  [ -n "$second_timeout" ]
  [ "$second_timeout" -lt "$first_timeout" ]
}
