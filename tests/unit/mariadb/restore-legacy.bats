#!/usr/bin/env bats
#
# Contract tests for the LEGACY (hand-rolled) path of mariadb/restore.sh — taken
# when the operator has no PhysicalBackup CRD (hence no physical bootstrapFrom).
# It pre-creates the datadir PVC, runs a prepare Job, creates a MariaDB that
# adopts the PVC, and FAIL-CLOSED verifies (PVC adoption + user tables) before
# reporting success.
#
# Mock control env vars:
#   MOCK_XB_LIST       space-separated .xb object names under the prefix
#   MOCK_TARGET_EXISTS=1  target MariaDB already exists
#   MOCK_JOB_FAIL=1    prepare Job never completes
#   MOCK_READY_FAIL=1  restored MariaDB never becomes Ready
#   MOCK_NOT_ADOPTED=1 the pod is bound to a different PVC (adoption failed)
#   MOCK_TABLE_COUNT   user-table count the verify query returns (default 5)

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  RESTORE_SH="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/restore.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"

  MOCK_DIR="$(mktemp -d)"
  RESULT="${MOCK_DIR}/result.json"
  CAP_DIR="${MOCK_DIR}/applied"; mkdir -p "$CAP_DIR"

  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
args="$*"
verb=""
for a in "$@"; do case "$a" in get|apply|wait|exec) verb="$a"; break ;; esac; done
case "$verb" in
  get)
    case "$args" in
      *crd*jsonpath*|*jsonpath*crd*) printf 'k8s.mariadb.com\n';   exit 0 ;;   # group detect
      *physicalbackups*) exit 1 ;;                                             # PhysicalBackup CRD ABSENT (legacy)
      *"get crd "*|*" crd "*) exit 0 ;;                                        # other CRDs present
      *persistentVolumeClaim*|*"get pod "*)                                    # verify: which PVC is the pod bound to
        pod="$(printf '%s' "$args" | sed -n 's/.*get pod \([^ ]*\).*/\1/p')"
        [[ "${MOCK_NOT_ADOPTED:-0}" == "1" ]] && { printf 'some-other-pvc'; exit 0; }
        printf 'storage-%s' "$pod"; exit 0 ;;
      *"get secret"*) printf '%s' "${MOCK_ROOT_PW-s3cret}" | base64;  exit 0 ;;
      *"get mariadb"*) [[ "${MOCK_TARGET_EXISTS:-0}" == "1" ]] && exit 0 || exit 1 ;;
      *metadata.name*) printf '%s' "${MOCK_SOURCES:-}";            exit 0 ;;
      *) exit 0 ;;
    esac ;;
  apply)
    body="$(cat)"; kind="$(printf '%s' "$body" | jq -r '.kind // "unknown"')"
    printf '%s' "$body" > "${MOCK_CAP_DIR}/${kind}.json"; exit 0 ;;
  wait)
    case "$args" in
      *job/*)     [[ "${MOCK_JOB_FAIL:-0}" == "1" ]]   && exit 1 || exit 0 ;;
      *mariadb/*) [[ "${MOCK_READY_FAIL:-0}" == "1" ]] && exit 1 || exit 0 ;;
      *) exit 0 ;;
    esac ;;
  exec) printf '%s' "${MOCK_TABLE_COUNT-5}"; exit 0 ;;   # verify: user-table count
  *) exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/kubectl"

  cat > "${MOCK_DIR}/mc" <<'MC'
#!/usr/bin/env bash
case "$1" in
  alias) exit 0 ;;
  ls)    for n in ${MOCK_XB_LIST-mariadb-20260708120000.xb}; do printf '%s\n' "$n"; done; exit 0 ;;
  cp)    exit 0 ;;
  *)     exit 0 ;;
esac
MC
  chmod +x "${MOCK_DIR}/mc"

  export DB_NAMESPACE="mariadb-1"
}

teardown() { rm -rf "${MOCK_DIR}"; }

run_restore() {
  run env "PATH=${MOCK_DIR}:${PATH}" \
    "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" \
    "MOCK_CAP_DIR=${CAP_DIR}" \
    "$@" \
    bash "${RESTORE_SH}"
}

result_field() { jq -r "$1" "${RESULT}"; }

@test "legacy dry_run plans a hand-rolled physical restore (no operator CR)" {
  run_restore DRY_RUN=true RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.backup.mode')" = "hand-rolled" ]
  [ "$(result_field '.data.backup.contentType')" = "Physical" ]
  [[ "$(result_field '.data.plan.pvc')" == storage-*-0 ]]
  [[ "$(result_field '.data.plan.source')" == s3://* ]]
  [ ! -f "${CAP_DIR}/PersistentVolumeClaim.json" ]
}

@test "legacy apply runs the full flow and reports restored" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.restored')" = "true" ]
  [ "$(result_field '.data.backup.mode')" = "hand-rolled" ]
  # all three objects were applied, and the MariaDB carries NO bootstrapFrom
  [ "$(jq -r '.kind' "${CAP_DIR}/PersistentVolumeClaim.json")" = "PersistentVolumeClaim" ]
  [ "$(jq -r '.kind' "${CAP_DIR}/Job.json")" = "Job" ]
  [ "$(jq -r '.spec | has("bootstrapFrom")' "${CAP_DIR}/MariaDB.json")" = "false" ]
}

@test "legacy fails when no .xb backup is found" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi MOCK_XB_LIST=""
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"no physical backup"* ]]
}

@test "legacy refuses to overwrite an existing target" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi MOCK_TARGET_EXISTS=1
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"already exists"* ]]
}

@test "legacy fails when the prepare Job does not complete" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi MOCK_JOB_FAIL=1
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"exit 11"* ]]
}

@test "legacy fails when the restored instance never becomes Ready" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi MOCK_READY_FAIL=1
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"exit 13"* ]]
}

@test "fail-closed: legacy fails when the PVC was not adopted (would be empty)" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi MOCK_NOT_ADOPTED=1
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"exit 14"* ]]
  [ "$(result_field '.data.restored')" = "false" ]
}

@test "fail-closed: legacy fails when the restored datadir has no user tables" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi MOCK_TABLE_COUNT=0
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"exit 14"* ]]
}

@test "legacy rejects point-in-time recovery (not supported hand-rolled)" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi TARGET_TIME="2026-07-08T00:00:00Z"
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"point-in-time"* ]]
}
