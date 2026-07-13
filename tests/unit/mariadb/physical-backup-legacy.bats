#!/usr/bin/env bats
#
# Contract tests for the LEGACY (hand-rolled) path of mariadb/physical-backup.sh
# — the branch taken when the operator has no `PhysicalBackup` CRD. It streams
# `mariabackup --backup --stream=xbstream` from the source pod straight to S3 via
# mc, instead of creating an operator CR.
#
# Mock control env vars:
#   MOCK_PODS         space-separated pod names the StatefulSet lists (replica pick)
#   MOCK_ROOT_PW      root password stored in the secret ("" → no credential)
#   MOCK_EXEC_FAIL=1  mariabackup exec fails
#   MOCK_PIPE_FAIL=1  mc pipe (upload) fails

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  BACKUP_SH="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/physical-backup.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"

  MOCK_DIR="$(mktemp -d)"
  RESULT="${MOCK_DIR}/result.json"
  PIPE_CAPTURE="${MOCK_DIR}/streamed.xb"

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
  exec) [[ "${MOCK_EXEC_FAIL:-0}" == "1" ]] && exit 1 || { printf 'XBSTREAM_BYTES'; exit 0; } ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/kubectl"

  cat > "${MOCK_DIR}/mc" <<'MC'
#!/usr/bin/env bash
case "$1" in
  alias) exit 0 ;;
  ls)    [[ "${MOCK_BUCKET_EXISTS:-1}" == "1" ]] && exit 0 || exit 1 ;;
  mb)    exit 0 ;;
  pipe)  cat > "${MOCK_PIPE_CAPTURE:-/dev/null}"; [[ "${MOCK_PIPE_FAIL:-0}" == "1" ]] && exit 1 || exit 0 ;;
  *)     exit 0 ;;
esac
MC
  chmod +x "${MOCK_DIR}/mc"

  export DB_NAMESPACE="mariadb-1"
}

teardown() { rm -rf "${MOCK_DIR}"; }

run_backup() {
  run env "PATH=${MOCK_DIR}:${PATH}" \
    "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" \
    "MOCK_PIPE_CAPTURE=${PIPE_CAPTURE}" \
    BACKUP_COMPRESSION=none \
    "$@" \
    bash "${BACKUP_SH}"
}

result_field() { jq -r "$1" "${RESULT}"; }

@test "legacy dry_run plans a hand-rolled mariabackup (no operator CR)" {
  run_backup DRY_RUN=true MARIADB_NAME=mariadb
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.backup.mode')" = "hand-rolled" ]
  [ "$(result_field '.data.backup.contentType')" = "Physical" ]
  [[ "$(result_field '.data.backup.object')" == *.xb ]]
  [ "$(result_field '.data.plan.command')" = "mariabackup --backup --stream=xbstream" ]
  [[ "$(result_field '.message')" == *"legacy operator"* ]]
}

@test "legacy apply streams the backup to S3 and reports created" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.created')" = "true" ]
  [ "$(result_field '.data.backup.mode')" = "hand-rolled" ]
  [ "$(cat "${PIPE_CAPTURE}")" = "XBSTREAM_BYTES" ]   # the stream reached mc pipe
}

@test "legacy apply prefers a replica pod when several exist" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb \
    MOCK_PODS="mariadb-0 mariadb-1 mariadb-2"
  [ "$status" -eq 0 ]
  [ "$(result_field '.data.sourcePod')" = "mariadb-2" ]
}

@test "legacy Primary target backs up from ordinal 0" {
  run_backup DRY_RUN=true MARIADB_NAME=mariadb BACKUP_TARGET=Primary \
    MOCK_PODS="mariadb-0 mariadb-1 mariadb-2"
  [ "$(result_field '.data.sourcePod')" = "mariadb-0" ]
}

@test "legacy fails when the mariadb container cannot run mariabackup" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb MOCK_EXEC_FAIL=1
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"hand-rolled physical backup failed"* ]]
}

@test "legacy fails when the S3 upload fails" {
  run_backup DRY_RUN=false CONFIRM=true MARIADB_NAME=mariadb MOCK_PIPE_FAIL=1
  [ "$status" -ne 0 ]
  [[ "$(result_field '.message')" == *"hand-rolled physical backup failed"* ]]
}
