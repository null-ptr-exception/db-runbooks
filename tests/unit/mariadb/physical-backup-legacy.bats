#!/usr/bin/env bats
#
# Contract tests for the LEGACY (hand-rolled) path of mariadb/physical-backup.sh
# — the branch taken when the operator has no `PhysicalBackup` CRD. It streams
# `mariabackup --backup --stream=xbstream` from the source pod straight to S3 via
# s5cmd, instead of creating an operator CR.
#
# Mock control env vars:
#   MOCK_PODS         space-separated pod names the StatefulSet lists (replica pick)
#   MOCK_ROOT_PW      root password stored in the secret ("" → no credential)
#   MOCK_EXEC_FAIL=1  mariabackup exec fails
#   MOCK_PIPE_FAIL=1  s5cmd pipe (upload) fails

setup() {
  unset MARIADB_OPERATOR_GROUP_DEFAULT _MDB_OPERATOR_GROUP
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  BACKUP_SH="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/physical-backup.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"

  MOCK_DIR="$(mktemp -d)"
  RESULT="${MOCK_DIR}/result.json"
  PIPE_CAPTURE="${MOCK_DIR}/streamed.xb"
  EXEC_CAPTURE="${MOCK_DIR}/exec.args"

  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
  args="$*"
  verb=""
  for a in "$@"; do case "$a" in api-resources|get|exec|apply|wait) verb="$a"; break ;; esac; done
case "$verb" in
  api-resources)
    printf 'mariadbs.mariadb.mmontes.io\n'; exit 0 ;;
  get)
    case "$args" in
      *"get mariadb"*"-o json"*) jq -n '{spec:{rootPasswordSecretKeyRef:{name:"mariadb",key:"password"}},status:{conditions:[{type:"Ready",status:"True"}],currentPrimary:"mariadb-0"}}'; exit 0 ;;
      *"get pods"*"-o json"*) jq -nc --arg pods "${MOCK_PODS:-mariadb-0}" '{items:($pods|split(" ")|map({metadata:{name:.},status:{conditions:[{type:"Ready",status:"True"}]}}))}'; exit 0 ;;
      *"get secret"*) printf '%s' "${MOCK_ROOT_PW-s3cret}" | base64;  exit 0 ;;
      *metadata.name*) printf '%s' "${MOCK_SOURCES:-}";            exit 0 ;;
      *) exit 0 ;;
    esac ;;
  exec)
    printf '%s' "$args" > "${MOCK_EXEC_CAPTURE:-/dev/null}"
    [[ "${MOCK_ROOT_PW-s3cret}" == "" ]] && exit 3
    [[ "${MOCK_EXEC_FAIL:-0}" == "1" ]] && exit 1 || { printf 'XBSTREAM_BYTES'; exit 0; } ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/kubectl"

  cat > "${MOCK_DIR}/s5cmd" <<'S5CMD'
#!/usr/bin/env bash
args=("$@"); cmd=""; i=0
while (( i < ${#args[@]} )); do
  case "${args[$i]}" in
    --endpoint-url) i=$((i+2)) ;;
    --*) i=$((i+1)) ;;
    *) cmd="${args[$i]}"; break ;;
  esac
done
case "$cmd" in
  ls)   [[ "${MOCK_BUCKET_EXISTS:-1}" == "1" ]] && { echo 'no object found' >&2; exit 1; } || exit 1 ;;
  mb)   exit 0 ;;
  pipe) cat > "${MOCK_PIPE_CAPTURE:-/dev/null}"; [[ "${MOCK_PIPE_FAIL:-0}" == "1" ]] && exit 1 || exit 0 ;;
  *)     exit 0 ;;
esac
S5CMD
  chmod +x "${MOCK_DIR}/s5cmd"

  export DB_NAMESPACE="mariadb-1"
}

teardown() { rm -rf "${MOCK_DIR}"; }

run_backup() {
  run env "PATH=${MOCK_DIR}:${PATH}" \
    "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" \
    "MOCK_PIPE_CAPTURE=${PIPE_CAPTURE}" \
    "MOCK_EXEC_CAPTURE=${EXEC_CAPTURE}" \
    BACKUP_COMPRESSION=none \
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

@test "legacy dry_run returns the same sanitized public summary" {
  run_backup DRY_RUN=true MARIADB_NAME=mariadb \
    BACKUP_ENDPOINT=https://private-legacy-storage.example.invalid \
    BACKUP_BUCKET=private-legacy-bucket \
    BACKUP_PREFIX=private/legacy-prefix \
    BACKUP_REGION=private-legacy-region
  [ "$status" -eq 0 ]
  assert_public_backup_data
  [ "$(result_field '.data.contentType')" = "Physical" ]
  [ "$(result_field '.data.state')" = "PLANNED" ]
  [ "$(result_field '.data.created')" = "false" ]
  [ "$(result_field '.data.dryRun')" = "true" ]
  [ ! -f "${PIPE_CAPTURE}" ]
  [ ! -f "${EXEC_CAPTURE}" ]
  assert_response_hides private-legacy-storage.example.invalid \
    private-legacy-bucket private/legacy-prefix private-legacy-region \
    hand-rolled sourcePod mariabackup manifest plan object Secret operator
}

@test "legacy apply streams the backup to S3 and reports created" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb \
    MOCK_ROOT_PW=private-root-password-marker
  [ "$status" -eq 0 ]
  assert_public_backup_data
  [ "$(result_field '.data.created')" = "true" ]
  [ "$(result_field '.data.contentType')" = "Physical" ]
  [ "$(result_field '.data.state')" = "COMPLETED" ]
  [ "$(cat "${PIPE_CAPTURE}")" = "XBSTREAM_BYTES" ]   # the stream reached s5cmd pipe
  assert_response_hides private-root-password-marker sourcePod mode object \
    bucket endpoint Secret
}

@test "legacy bounds the remote mariabackup stream with a configurable timeout" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb MDBT_PB_STREAM_TIMEOUT=17
  [ "$status" -eq 0 ]
  assert_public_backup_data
  [[ "$(cat "${EXEC_CAPTURE}")" == *"MDBT_PB_STREAM_TIMEOUT=17"* ]]
  [[ "$(cat "${EXEC_CAPTURE}")" == *'timeout "$MDBT_PB_STREAM_TIMEOUT" mariabackup'* ]]
}

@test "legacy apply prefers a replica pod when several exist" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb \
    MOCK_PODS="mariadb-0 mariadb-1 mariadb-2"
  [ "$status" -eq 0 ]
  assert_public_backup_data
  [[ "$(cat "${EXEC_CAPTURE}")" == *"mariadb-2"* ]]
  assert_response_hides mariadb-0 mariadb-2 sourcePod
}

@test "legacy Primary target backs up from ordinal 0" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb BACKUP_TARGET=Primary \
    MOCK_PODS="mariadb-0 mariadb-1 mariadb-2"
  [ "$status" -eq 0 ]
  assert_public_backup_data
  [[ "$(cat "${EXEC_CAPTURE}")" == *"mariadb-0"* ]]
  assert_response_hides mariadb-0 mariadb-2 sourcePod
}

@test "legacy fails closed when the container has no root credential" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb MOCK_ROOT_PW=""
  [ "$status" -ne 0 ]
  [ "$(result_field '.reason')" = "BACKUP_FAILED" ]
  assert_public_backup_data
  assert_response_hides "root credential" Secret sourcePod object
}

@test "legacy fails when the mariadb container cannot run mariabackup" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb MOCK_EXEC_FAIL=1
  [ "$status" -ne 0 ]
  [ "$(result_field '.reason')" = "BACKUP_FAILED" ]
  assert_public_backup_data
  assert_response_hides hand-rolled mariabackup sourcePod object
}

@test "legacy fails when the S3 upload fails" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb MOCK_PIPE_FAIL=1
  [ "$status" -ne 0 ]
  [ "$(result_field '.reason')" = "BACKUP_FAILED" ]
  assert_public_backup_data
  assert_response_hides hand-rolled s5cmd bucket endpoint sourcePod object
}
