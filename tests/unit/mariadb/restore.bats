#!/usr/bin/env bats
#
# Contract tests for mariadb/restore.sh.
#
# These run the script directly against a mock `kubectl` — no cluster, no
# MinIO, no operator. They lock down the user-oriented surface and the manifest
# the task renders:
#   - namespace is the only required input (the database identity); version,
#     storage, restored name, source, credentials, and S3 location are all
#     internal — NOT task inputs. RESTORE_SOURCE / RESTORE_TARGET / RESTORE_IMAGE
#     / STORAGE_SIZE remain env-readable as advanced operator overrides and are
#     used here to drive the resolution paths.
#   - the source instance (for version/storage) is auto-detected from the
#     namespace, and neither version nor storage is ever silently guessed
#   - confirm=true is mandatory to apply; dry_run (default) only renders
#   - an existing target is never overwritten in place
#   - target_time is range-validated and, when given, injected as PITR
#   - wait_timeout doubles as the wait switch ("0" = don't wait); a Ready-wait
#     timeout still returns a partial result instead of losing it
#   - the result returns the connection endpoint + credential reference
#
# A live restore (real backup round-trip) belongs in the dual-cluster e2e suite
# (tracked as a follow-up — bootstrapFrom / S3 wiring / Ready reconciliation are
# not exercised here).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  RESTORE_SH="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/restore.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"

  MOCK_DIR="$(mktemp -d)"
  CAPTURE="${MOCK_DIR}/applied.yaml"
  RESULT="${MOCK_DIR}/result.json"

  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
# Minimal kubectl mock:
#   get ... {range .items...metadata.name}  → source auto-detect list (MOCK_SOURCES)
#   get ... {range .items...spec.image}      → distinct-image scan (MOCK_SOURCE_IMAGES)
#   get <name> -o json                       → source spec (MOCK_SOURCE_IMAGE/_STORAGE)
#   get mariadb <target>                     → target existence probe (MOCK_TARGET_EXISTS)
#   wait                                     → Ready wait (fails with MOCK_WAIT_FAIL=1)
#   apply                                    → capture stdin
args="$*"
verb=""
for a in "$@"; do
  case "$a" in get|apply|wait) verb="$a"; break ;; esac
done
case "$verb" in
  get)
    case "$args" in
      *metadata.name*) printf '%s' "${MOCK_SOURCES:-}";        exit 0 ;;   # resolve-name list (jsonpath)
      *items*spec.image*) printf '%s' "${MOCK_SOURCE_IMAGES:-}"; exit 0 ;; # distinct-image scan (jsonpath)
      *"-o json"*)  # single-source spec fetch (image + storage in one call)
        jq -n --arg img "${MOCK_SOURCE_IMAGE:-}" --arg sz "${MOCK_SOURCE_STORAGE:-}" \
          '{spec: {image: $img, storage: {size: $sz}}}';      exit 0 ;;
      *"get mariadb"*) [[ "${MOCK_TARGET_EXISTS:-0}" == "1" ]] && exit 0 || exit 1 ;;  # target existence probe
      *) echo "mock kubectl: unhandled get: $args" >&2;       exit 1 ;;   # fail loudly on a new get
    esac ;;
  apply) cat > "${MOCK_APPLY_CAPTURE}"; exit 0 ;;
  wait)  [[ "${MOCK_WAIT_FAIL:-0}" == "1" ]] && exit 1 || exit 0 ;;
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
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi MOCK_TARGET_EXISTS=1
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"already exists"* ]]
}

@test "restore rejects a malformed target_time" {
  run_restore RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi TARGET_TIME="not-a-timestamp"
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"RFC3339"* ]]
}

@test "restore rejects an out-of-range target_time" {
  run_restore RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi TARGET_TIME="2026-99-99T25:61:61Z"
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"RFC3339"* ]]
}

@test "restore rejects a malformed context" {
  run_restore RESTORE_IMAGE=mariadb:11.4 K8S_CONTEXT="bad context!"
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"context"* ]]
}

@test "restore accepts a well-formed context" {
  run_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi K8S_CONTEXT=kind-cluster-dbs
  [ "$status" -eq 0 ]
  [ "$(result_field '.status')" = "success" ]
}

@test "restore dry_run renders the manifest without confirm or apply" {
  run_restore DRY_RUN=true CONFIRM=false RESTORE_TARGET=mariadb-restored RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi
  [ "$status" -eq 0 ]
  [ "$(result_field '.status')" = "success" ]
  [ "$(result_field '.data.dryRun')" = "true" ]
  [ "$(result_field '.data.restored')" = "false" ]
  [ ! -f "${CAPTURE}" ]
  [ "$(result_field '.data.manifest | fromjson | .kind')" = "MariaDB" ]
  [ "$(result_field '.data.manifest | fromjson | .spec.bootstrapFrom.backupContentType')" = "Physical" ]
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

  [ "$(jq -r '.spec.bootstrapFrom.backupContentType' "${CAPTURE}")" = "Physical" ]
  [ "$(jq -r '.spec.bootstrapFrom.s3.prefix' "${CAPTURE}")" = "mariadb/mariadb-bg" ]
  [ "$(jq -r '.spec | has("replication")' "${CAPTURE}")" = "false" ]
  [ "$(jq -r '.spec | has("multiCluster")' "${CAPTURE}")" = "false" ]
  [ "$(jq -r '.spec.bootstrapFrom | has("targetRecoveryTime")' "${CAPTURE}")" = "false" ]
}

@test "restore with target_time injects point-in-time recovery" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi TARGET_TIME="2026-06-14T03:21:00Z" MOCK_TARGET_EXISTS=0
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.pointInTimeRecovery.enabled')" = "true" ]
  [ "$(result_field '.data.pointInTimeRecovery.targetRecoveryTime')" = "2026-06-14T03:21:00Z" ]
  [ "$(jq -r '.spec.bootstrapFrom.targetRecoveryTime' "${CAPTURE}")" = "2026-06-14T03:21:00Z" ]
}

@test "restore auto-generates a target name when omitted" {
  run_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi
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
  [ "$(result_field '.data.manifest | fromjson | .spec.storage.size')" = "5Gi" ]
}

@test "restore fails when the source is gone and no version can be derived" {
  run_restore DRY_RUN=true   # MOCK_SOURCES empty → no source found
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"version"* ]]
}

@test "restore resolves the version when several instances share it (no source needed)" {
  # Several instances share a version, so `image` derives from the scan — but no
  # single source means storage can't be derived, so it is passed explicitly.
  run_restore DRY_RUN=true RESTORE_TARGET=mariadb-restored STORAGE_SIZE=1Gi \
    MOCK_SOURCES=$'mariadb-green\nmariadb-bg-restore-1' MOCK_SOURCE_IMAGES="mariadb:10.11"
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.image')" = "mariadb:10.11" ]
  [ "$(result_field '.data.source')" = "null" ]
}

@test "restore fails on mixed versions without source/image" {
  run_restore DRY_RUN=true \
    MOCK_SOURCES=$'mariadb-blue\nmariadb-green' MOCK_SOURCE_IMAGES=$'mariadb:10.11\nmariadb:10.6'
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"multiple MariaDB versions"* ]]
}

@test "restore uses an explicit source override" {
  run_restore DRY_RUN=true RESTORE_TARGET=mariadb-restored \
    RESTORE_SOURCE=mariadb-green MOCK_SOURCE_IMAGE=mariadb:10.11 MOCK_SOURCE_STORAGE=5Gi
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.source')" = "mariadb-green" ]
  [ "$(result_field '.data.image')" = "mariadb:10.11" ]
}

@test "restore never silently defaults storage when the source is gone" {
  # image is given but no source exists to derive storage from — restore must
  # fail rather than under-provision the PVC and truncate the restored data.
  run_restore DRY_RUN=true RESTORE_IMAGE=mariadb:11.4   # MOCK_SOURCES empty
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"storage size"* ]]
}

@test "restore returns a partial result (not lost) when Ready wait times out" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi MOCK_TARGET_EXISTS=0 MOCK_WAIT_FAIL=1
  [ "$status" -ne 0 ]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"did not become Ready"* ]]
  # The instance was applied, so the result still carries how to reach it.
  [ -f "${CAPTURE}" ]
  [ "$(result_field '.data.restored')" = "true" ]
  [ "$(result_field '.data.connection.host')" = "mariadb-restored-primary.mariadb-bg.svc.cluster.local" ]
  [ "$(result_field '.data.credentialsRef.secretName')" = "mariadb" ]
}

@test "restore with wait_timeout=0 applies without waiting for Ready" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:11.4 STORAGE_SIZE=1Gi WAIT_TIMEOUT=0 \
    MOCK_TARGET_EXISTS=0 MOCK_WAIT_FAIL=1   # wait would fail, but it must not run
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.restored')" = "true" ]
  [ -f "${CAPTURE}" ]
}
