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
  unset MARIADB_OPERATOR_GROUP_DEFAULT _MDB_OPERATOR_GROUP
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
for a in "$@"; do case "$a" in api-resources|get|create|apply|wait|exec) verb="$a"; break ;; esac; done
case "$verb" in
  api-resources) printf 'mariadbs.mariadb.mmontes.io backups.mariadb.mmontes.io restores.mariadb.mmontes.io\n'; exit 0 ;;
  get)
    case "$args" in
      *"get pvc"*|*"get job"*) exit 1 ;;
      *"get mariadb"*"-o json"*) jq -n '{spec:{image:"mariadb:10.6",rootPasswordSecretKeyRef:{name:"mariadb",key:"password"},volumeClaimTemplate:{resources:{requests:{storage:"1Gi"}}}},status:{conditions:[{type:"Ready",status:"True"}]}}'; exit 0 ;;
      *persistentVolumeClaim*|*"get pod "*)                                    # verify: which PVC is the pod bound to
        pod="$(printf '%s' "$args" | sed -n 's/.*get pod \([^ ]*\).*/\1/p')"
        [[ "${MOCK_NOT_ADOPTED:-0}" == "1" ]] && { printf 'some-other-pvc'; exit 0; }
        printf 'storage-%s' "$pod"; exit 0 ;;
      *"get secret"*"-o json"*)
        jq -n '{data:{
          "legacy-access-key": ("mock-access" | @base64),
          "legacy-secret-key": ("mock-secret" | @base64)
        }}'; exit 0 ;;
      *"get secret"*) printf '%s' "${MOCK_ROOT_PW-s3cret}" | base64;  exit 0 ;;
      *"get mariadb"*) [[ "${MOCK_TARGET_EXISTS:-0}" == "1" ]] && exit 0 || exit 1 ;;
      *metadata.name*) printf '%s' "${MOCK_SOURCES:-}";            exit 0 ;;
      *) exit 0 ;;
    esac ;;
  create|apply)
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

  cat > "${MOCK_DIR}/s5cmd" <<'S5CMD'
#!/usr/bin/env bash
args=("$@"); cmd=""; target=""; i=0
while (( i < ${#args[@]} )); do
  case "${args[$i]}" in
    --endpoint-url) i=$((i+2)) ;;
    --*) i=$((i+1)) ;;
    *) cmd="${args[$i]}"; target="${args[$((i+1))]:-}"; break ;;
  esac
done
case "$cmd" in
  ls)
    [[ -n "${MOCK_XB_LIST-mariadb-20260708120000.xb}" ]] || { echo 'no object found' >&2; exit 1; }
    for n in ${MOCK_XB_LIST-mariadb-20260708120000.xb}; do
      jq -nc --arg key "${target}${n}" '{key:$key,type:"file",size:123}'
    done
    exit 0 ;;
  *)     exit 0 ;;
esac
S5CMD
  chmod +x "${MOCK_DIR}/s5cmd"

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

assert_restore_contract() {
  jq -e '
    .data
    | keys == [
        "contentType", "dryRun", "namespace", "pointInTimeRecovery",
        "provisioned", "restored", "state"
      ]
  ' "${RESULT}" >/dev/null
  jq -e '.data.pointInTimeRecovery | keys == ["enabled", "targetRecoveryTime"]' \
    "${RESULT}" >/dev/null
}

assert_error_reason() {
  [ "$(result_field '.status')" = "error" ]
  [ "$(result_field '.reason')" = "$1" ]
}

@test "legacy dry_run returns a sanitized physical restore plan" {
  run_restore DRY_RUN=true RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.contentType')" = "Physical" ]
  [ "$(result_field '.data.dryRun')" = "true" ]
  [ "$(result_field '.data.provisioned')" = "false" ]
  [ "$(result_field '.data.restored')" = "false" ]
  [ "$(result_field '.data.state')" = "PLANNED" ]
  assert_restore_contract
  [ ! -f "${CAP_DIR}/PersistentVolumeClaim.json" ]
}

@test "legacy apply runs the full flow and reports restored" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.provisioned')" = "true" ]
  [ "$(result_field '.data.restored')" = "true" ]
  [ "$(result_field '.data.state')" = "COMPLETED" ]
  assert_restore_contract
  # The original Secret references are reused directly; no credential values
  # are copied into a short-lived Secret. The MariaDB carries NO bootstrapFrom.
  [ "$(jq -r '.kind' "${CAP_DIR}/PersistentVolumeClaim.json")" = "PersistentVolumeClaim" ]
  [ "$(jq -r '.kind' "${CAP_DIR}/Job.json")" = "Job" ]
  [ "$(jq -r '.spec.template.spec.initContainers[0].image' "${CAP_DIR}/Job.json")" = "peakcom/s5cmd:v2.3.0" ]
  [ "$(jq -r '.spec.template.spec.initContainers[0].command[0]' "${CAP_DIR}/Job.json")" = "/s5cmd" ]
  [ "$(jq -r '.spec.template.spec.initContainers[0].args[3]' "${CAP_DIR}/Job.json")" = "s3://db-backups/mariadb/mariadb-1/mariadb-20260708120000.xb" ]
  [ "$(jq -r '.spec.template.spec.initContainers[0].env[0].valueFrom.secretKeyRef.name' "${CAP_DIR}/Job.json")" = "minio" ]
  [ "$(jq -r '.spec.template.spec.initContainers[0].env[0].valueFrom.secretKeyRef.key' "${CAP_DIR}/Job.json")" = "access-key-id" ]
  [ "$(jq -r '.spec.template.spec.initContainers[0].env[1].valueFrom.secretKeyRef.name' "${CAP_DIR}/Job.json")" = "minio" ]
  [ "$(jq -r '.spec.template.spec.initContainers[0].env[1].valueFrom.secretKeyRef.key' "${CAP_DIR}/Job.json")" = "secret-access-key" ]
  [ ! -f "${CAP_DIR}/Secret.json" ]
  [ "$(jq -r '.spec | has("bootstrapFrom")' "${CAP_DIR}/MariaDB.json")" = "false" ]
}

@test "legacy fails when no .xb backup is found" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi MOCK_XB_LIST=""
  [ "$status" -ne 0 ]
  assert_error_reason BACKUP_NOT_FOUND
  [ "$(result_field '.message')" = "no backup is available to restore" ]
}

@test "legacy refuses to overwrite an existing target" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi MOCK_TARGET_EXISTS=1
  [ "$status" -ne 0 ]
  assert_error_reason RESTORE_FAILED
  [ "$(result_field '.message')" = "restore target is unavailable" ]
  [[ "$(cat "${RESULT}")" != *"mariadb-restored"* ]]
}

@test "legacy fails when the prepare Job does not complete" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi MOCK_JOB_FAIL=1
  [ "$status" -ne 0 ]
  assert_error_reason RESTORE_FAILED
  [ "$(result_field '.message')" = "database restore failed" ]
  assert_restore_contract
}

@test "legacy fails when the restored instance never becomes Ready" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi MOCK_READY_FAIL=1
  [ "$status" -ne 0 ]
  assert_error_reason RESTORE_FAILED
  [ "$(result_field '.message')" = "database restore failed" ]
  assert_restore_contract
}

@test "fail-closed: legacy fails when the PVC was not adopted (would be empty)" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi MOCK_NOT_ADOPTED=1
  [ "$status" -ne 0 ]
  assert_error_reason RESTORE_FAILED
  [ "$(result_field '.message')" = "database restore failed" ]
  [ "$(result_field '.data.restored')" = "false" ]
  assert_restore_contract
}

@test "fail-closed: legacy fails when the restored datadir has no user tables" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi MOCK_TABLE_COUNT=0
  [ "$status" -ne 0 ]
  assert_error_reason RESTORE_FAILED
  [ "$(result_field '.message')" = "database restore failed" ]
  assert_restore_contract
}

@test "legacy rejects point-in-time recovery (not supported hand-rolled)" {
  run_restore DRY_RUN=false CONFIRM=true RESTORE_TARGET=mariadb-restored \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi TARGET_TIME="2026-07-08T00:00:00Z"
  [ "$status" -ne 0 ]
  assert_error_reason RESTORE_CAPABILITY_UNAVAILABLE
  [ "$(result_field '.message')" = "point-in-time recovery is unavailable for this database" ]
}

@test "legacy restore does not expose its mode, object, Secret, or resource plan" {
  run_restore DRY_RUN=true RESTORE_TARGET=internal-legacy-target \
    RESTORE_IMAGE=mariadb:10.6 STORAGE_SIZE=1Gi \
    BACKUP_ENDPOINT="https://legacy-storage.internal.invalid:9443" \
    BACKUP_BUCKET="private-legacy-bucket" BACKUP_PREFIX="private/legacy/prefix" \
    BACKUP_ACCESS_SECRET="legacy-access-secret" BACKUP_ACCESS_KEY="legacy-access-key" \
    BACKUP_SECRET_ACCESS_SECRET="legacy-secret-access" BACKUP_SECRET_KEY="legacy-secret-key"
  [ "$status" -eq 0 ]
  assert_restore_contract
  local public_output="$(cat "${RESULT}")${output}"
  local marker
  for marker in \
    internal-legacy-target legacy-storage.internal.invalid private-legacy-bucket \
    private/legacy/prefix legacy-access-secret legacy-access-key \
    legacy-secret-access legacy-secret-key hand-rolled s3:// \
    PersistentVolumeClaim Job secretKeyRef plan manifest; do
    [[ "$public_output" != *"$marker"* ]]
  done
}
