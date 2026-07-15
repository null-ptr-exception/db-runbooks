#!/usr/bin/env bats
#
# Contract tests for backup/list-backups-mariadb.sh — run against a mock `s5cmd`,
# no MinIO. Lock down: namespace is the only input; the location is resolved
# internally; `s5cmd --json ls` output (full s3:// keys, snake_case
# last_modified) is normalised into a {name,size,lastModified} array; and the
# s5cmd empty-prefix semantic (exit 1 + 'no object found') maps to an EMPTY
# LIST, while any other failure (auth/bucket) stays an error.
#
# The mock reproduces s5cmd v2.3.0 behavior as verified against a live MinIO.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/aqsh-tasks/scripts/backup/list-backups-mariadb.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"
  MOCK_DIR="$(mktemp -d)"
  RESULT="${MOCK_DIR}/result.json"

  cat > "${MOCK_DIR}/s5cmd" <<'MOCK'
#!/usr/bin/env bash
# skip global flags (--json, --endpoint-url URL) to find the subcommand
args=("$@"); cmd=""; target=""
i=0
while (( i < ${#args[@]} )); do
  a="${args[$i]}"
  case "$a" in
    --endpoint-url) i=$((i+2)); continue ;;
    --*) i=$((i+1)); continue ;;
    *) cmd="$a"; target="${args[$((i+1))]:-}"; break ;;
  esac
done
case "$cmd" in
  ls)
    if [[ "${MOCK_S5_AUTH_FAIL:-0}" == "1" ]]; then
      echo 'ERROR session: credential-marker-must-not-escape: Forbidden status code: 403' >&2; exit 1
    fi
    if [[ -z "${MOCK_S5_LS:-}" ]]; then
      echo "ERROR \"ls ${target}\": no object found" >&2; exit 1
    fi
    printf '%s\n' "${MOCK_S5_LS}"; exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/s5cmd"
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
  # real s5cmd --json ls shapes: file has size + last_modified; directory has neither
  local l1='{"key":"s3://db-backups/mariadb/mariadb-1/mariadb-1-20260101.sql.gz","last_modified":"2026-01-01T00:00:00.000Z","type":"file","size":123}'
  local l2='{"key":"s3://db-backups/mariadb/mariadb-1/physicalbackup-blue/","type":"directory"}'
  run_list MOCK_S5_LS="$(printf '%s\n%s' "$l1" "$l2")"
  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "success" ]
  [ "$(field '.data.count')" = "2" ]
  # full s3:// prefix is stripped down to the entry name
  [ "$(field '.data.backups[0].name')" = "mariadb-1-20260101.sql.gz" ]
  [ "$(field '.data.backups[0].lastModified')" = "2026-01-01T00:00:00.000Z" ]
  # trailing slash on a "directory" entry is trimmed
  [ "$(field '.data.backups[1].name')" = "physicalbackup-blue" ]
  [ "$(field '.data.backups[1].size')" = "0" ]
  [ "$(field '.data.location.bucket')" = "db-backups" ]
  [ "$(field '.data.location.prefix')" = "mariadb/mariadb-1" ]
}

@test "list-backups maps s5cmd 'no object found' (empty prefix) to an empty list, not an error" {
  run_list   # mock emits exit 1 + 'no object found' when MOCK_S5_LS is empty
  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "success" ]
  [ "$(field '.data.count')" = "0" ]
  [ "$(field '.data.backups')" = "[]" ]
}

@test "list-backups surfaces a real s5cmd failure (auth) instead of reporting zero backups" {
  run_list MOCK_S5_AUTH_FAIL=1
  [ "$status" -ne 0 ]
  [ "$(field '.status')" = "error" ]
  [[ "$(field '.message')" == *"failed to list backups"* ]]
  [[ "$(cat "${RESULT}")" != *"credential-marker-must-not-escape"* ]]
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
  run_list MDBT_CONFIG_FILE="${MOCK_DIR}/mariadb.env"
  [ "$status" -eq 0 ]
  [ "$(field '.data.location.bucket')" = "other-bucket" ]
  [ "$(field '.data.location.endpoint')" = "http://minio.kind-b.test:30080" ]
}
