#!/usr/bin/env bats
#
# Contract tests for backup/list-backups-mariadb.sh — run against a mock `mc`,
# no MinIO. Lock down: namespace is the only input; the location is resolved
# internally; `mc ls --json` output is normalised into a {name,size,lastModified}
# array; an empty prefix returns an empty list, not an error.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/aqsh-tasks/scripts/backup/list-backups-mariadb.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"
  MOCK_DIR="$(mktemp -d)"
  RESULT="${MOCK_DIR}/result.json"

  cat > "${MOCK_DIR}/mc" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  alias) exit 0 ;;
  ls)    printf '%s' "${MOCK_MC_LS:-}"; exit 0 ;;
  *)     exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/mc"
  export DB_NAMESPACE="mariadb-1"
  export MDBT_CONFIG_FILE="${MOCK_DIR}/nonexistent.env"
}

teardown() { rm -rf "${MOCK_DIR}"; }

run_list() {
  run env "PATH=${MOCK_DIR}:${PATH}" "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" "$@" bash "${SCRIPT}"
}
field() { jq -r "$1" "${RESULT}"; }

@test "list-backups returns a normalised backup list" {
  local l1='{"key":"mariadb-1-20260101.sql.gz","size":123,"lastModified":"2026-01-01T00:00:00Z"}'
  local l2='{"key":"physicalbackup-blue/","size":0,"lastModified":"2026-01-02T00:00:00Z"}'
  run_list MOCK_MC_LS="$(printf '%s\n%s' "$l1" "$l2")"
  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "success" ]
  [ "$(field '.data.count')" = "2" ]
  [ "$(field '.data.backups[0].name')" = "mariadb-1-20260101.sql.gz" ]
  # trailing slash on a "directory" entry is trimmed
  [ "$(field '.data.backups[1].name')" = "physicalbackup-blue" ]
  [ "$(field '.data.location.bucket')" = "db-backups" ]
  [ "$(field '.data.location.prefix')" = "mariadb/mariadb-1" ]
}

@test "list-backups returns an empty list (not an error) when there are no backups" {
  run_list MOCK_MC_LS=""
  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "success" ]
  [ "$(field '.data.count')" = "0" ]
  [ "$(field '.data.backups')" = "[]" ]
}

@test "list-backups rejects a malformed namespace" {
  run_list DB_NAMESPACE="Bad_NS!"
  [ "$status" -ne 0 ]
  [ "$(field '.status')" = "error" ]
  [[ "$(field '.message')" == *"namespace"* ]]
}

@test "list-backups resolves the bucket/endpoint from deploy config" {
  cat > "${MOCK_DIR}/mariadb.env" <<EOF
MINIO_BUCKET=other-bucket
MINIO_ENDPOINT=http://minio.kind-b.test:30080
EOF
  run_list MOCK_MC_LS="" MDBT_CONFIG_FILE="${MOCK_DIR}/mariadb.env"
  [ "$status" -eq 0 ]
  [ "$(field '.data.location.bucket')" = "other-bucket" ]
  [ "$(field '.data.location.endpoint')" = "http://minio.kind-b.test:30080" ]
}
