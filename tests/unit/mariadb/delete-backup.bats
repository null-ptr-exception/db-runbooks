#!/usr/bin/env bats
#
# Contract tests for backup/delete-backup-mariadb.sh — run against a mock
# `s5cmd`, no MinIO. Lock down: confirm gating, sanitised dry-run result, path-traversal
# guard on the backup name, not-found handling, the type-aware delete (exact key
# for a flat object, "name/*" wildcard for a physical-backup directory — never a
# bare prefix rm, which s5cmd silently no-ops), and the verify-after check that
# catches exactly that silent no-op.
#
# The mock reproduces s5cmd v2.3.0 behavior as verified against a live MinIO.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/aqsh-tasks/scripts/backup/delete-backup-mariadb.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"
  MOCK_DIR="$(mktemp -d)"
  RESULT="${MOCK_DIR}/result.json"
  RM_CAPTURE="${MOCK_DIR}/rm.args"
  DELETED_FLAG="${MOCK_DIR}/deleted"

  cat > "${MOCK_DIR}/s5cmd" <<'MOCK'
#!/usr/bin/env bash
# stateful mock: ls reports the target until rm really deletes it
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
      echo 'ERROR credential-marker-must-not-escape: Forbidden status code: 403' >&2
      exit 1
    fi
    # s5cmd ls matches by PREFIX: with MOCK_S5_SIBLING=1 a sibling whose name
    # extends the target's (e.g. snap-1 -> snap-10) is always in the listing.
    out=""
    if [[ "${MOCK_S5_SIBLING:-0}" == "1" ]]; then
      out+="$(printf '{"key":"%s0","last_modified":"2026-01-01T00:00:00.000Z","type":"file","size":9}' "$target")"$'\n'
    fi
    if [[ ! -f "${MOCK_DELETED_FLAG}" && "${MOCK_S5_TYPE:-file}" != "none" ]]; then
      if [[ "${MOCK_S5_TYPE:-file}" == "directory" ]]; then
        out+="$(printf '{"key":"%s/","type":"directory"}' "$target")"$'\n'
      else
        out+="$(printf '{"key":"%s","last_modified":"2026-01-01T00:00:00.000Z","type":"file","size":123}' "$target")"$'\n'
      fi
    fi
    if [[ -z "$out" ]]; then
      echo "ERROR \"ls ${target}\": no object found" >&2; exit 1
    fi
    printf '%s' "$out"; exit 0 ;;
  rm)
    printf '%s' "$target" > "${MOCK_RM_CAPTURE}"
    # silent-no-op mode: exit 0 but delete nothing (real s5cmd does this for a
    # bare directory-name rm)
    [[ "${MOCK_S5_RM_NOOP:-0}" == "1" ]] && exit 0
    touch "${MOCK_DELETED_FLAG}"; exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/s5cmd"
  export DB_NAMESPACE="mariadb-1"
  export MDBT_CONFIG_FILE="${MOCK_DIR}/nonexistent.env"
}

teardown() { rm -rf "${MOCK_DIR}"; }

run_del() {
  run env "PATH=${MOCK_DIR}:${PATH}" "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" "MOCK_RM_CAPTURE=${RM_CAPTURE}" \
    "MOCK_DELETED_FLAG=${DELETED_FLAG}" "$@" bash "${SCRIPT}"
}
field() { jq -r "$1" "${RESULT}"; }

assert_public_delete_result() {
  [ "$(field '.data | keys | sort | join(",")')" = "backup,deleted,dryRun,namespace,state" ]
  [ "$(field '.data | has("location") or has("bucket") or has("endpoint") or has("path") or has("plan")')" = "false" ]
}

@test "delete-backup requires confirm=true to apply" {
  run_del DRY_RUN=false CONFIRM=false BACKUP_NAME=snap-1
  [ "$status" -ne 0 ]
  [ "$(field '.status')" = "error" ]
  [ "$(field '.reason')" = "INVALID_REQUEST" ]
  [[ "$(field '.message')" == *"confirm=true is required"* ]]
  [ ! -f "${RM_CAPTURE}" ]
}

@test "delete-backup dry_run renders the plan without deleting" {
  run_del DRY_RUN=true BACKUP_NAME=snap-1
  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "success" ]
  [ "$(field '.data.dryRun')" = "true" ]
  [ "$(field '.data.deleted')" = "false" ]
  [ "$(field '.data.state')" = "PLANNED" ]
  [ "$(field '.data.backup')" = "snap-1" ]
  assert_public_delete_result
  [ ! -f "${RM_CAPTURE}" ]
}

@test "delete-backup rejects a backup name containing a path" {
  run_del DRY_RUN=false CONFIRM=true BACKUP_NAME="../other-ns/secret"
  [ "$status" -ne 0 ]
  [ "$(field '.status')" = "error" ]
  [ "$(field '.reason')" = "INVALID_REQUEST" ]
  [[ "$(field '.message')" == *"single name segment"* ]]
  [ ! -f "${RM_CAPTURE}" ]
}

@test "delete-backup requires the backup input" {
  run_del DRY_RUN=false CONFIRM=true
  [ "$status" -ne 0 ]
  [ "$(field '.status')" = "error" ]
  [ "$(field '.reason')" = "INVALID_REQUEST" ]
  [[ "$(field '.message')" == *"backup is required"* ]]
}

@test "delete-backup fails when the backup does not exist" {
  run_del DRY_RUN=false CONFIRM=true BACKUP_NAME=missing MOCK_S5_TYPE=none
  [ "$status" -ne 0 ]
  [ "$(field '.status')" = "error" ]
  [ "$(field '.reason')" = "BACKUP_NOT_FOUND" ]
  [[ "$(field '.message')" == *"not found"* ]]
  [ ! -f "${RM_CAPTURE}" ]
}

@test "delete-backup deletes a flat (logical) backup by exact key" {
  run_del DRY_RUN=false CONFIRM=true BACKUP_NAME=snap-1 MOCK_S5_TYPE=file
  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "success" ]
  [ "$(field '.data.deleted')" = "true" ]
  [ "$(field '.data.state')" = "DELETED" ]
  assert_public_delete_result
  # exact key, scoped to the namespace prefix, no wildcard
  [ "$(cat "${RM_CAPTURE}")" = "s3://db-backups/mariadb/mariadb-1/snap-1" ]
}

@test "delete-backup deletes a physical (directory) backup with the name/* wildcard" {
  run_del DRY_RUN=false CONFIRM=true BACKUP_NAME=phys-1 MOCK_S5_TYPE=directory
  [ "$status" -eq 0 ]
  [ "$(field '.data.deleted')" = "true" ]
  assert_public_delete_result
  # MUST be the wildcard form — a bare prefix rm is a silent no-op in s5cmd,
  # and "name/*" (unlike "name*") cannot over-match a sibling like "phys-10"
  [ "$(cat "${RM_CAPTURE}")" = "s3://db-backups/mariadb/mariadb-1/phys-1/*" ]
}

@test "delete-backup detects a silent no-op delete via verify-after" {
  run_del DRY_RUN=false CONFIRM=true BACKUP_NAME=snap-1 MOCK_S5_RM_NOOP=1
  [ "$status" -ne 0 ]
  [ "$(field '.status')" = "error" ]
  [ "$(field '.reason')" = "BACKUP_FAILED" ]
  [[ "$(field '.message')" == *"still present"* ]]
}

@test "delete-backup reports not-found when only a prefix-sibling exists" {
  # snap-1 is absent; snap-10 matches the prefix listing but not the exact key
  run_del DRY_RUN=false CONFIRM=true BACKUP_NAME=snap-1 MOCK_S5_TYPE=none MOCK_S5_SIBLING=1
  [ "$status" -ne 0 ]
  [ "$(field '.status')" = "error" ]
  [ "$(field '.reason')" = "BACKUP_NOT_FOUND" ]
  [[ "$(field '.message')" == *"not found"* ]]
  [ ! -f "${RM_CAPTURE}" ]
}

@test "delete-backup succeeds although a prefix-sibling survives the delete" {
  # snap-10 remains in the prefix listing after snap-1 is deleted — the
  # verify-after must not misread it as "still present"
  run_del DRY_RUN=false CONFIRM=true BACKUP_NAME=snap-1 MOCK_S5_TYPE=file MOCK_S5_SIBLING=1
  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "success" ]
  [ "$(field '.data.deleted')" = "true" ]
  assert_public_delete_result
  [ "$(cat "${RM_CAPTURE}")" = "s3://db-backups/mariadb/mariadb-1/snap-1" ]
}

@test "delete-backup maps storage failures to a stable reason without returning client details" {
  run_del DRY_RUN=false CONFIRM=true BACKUP_NAME=snap-1 MOCK_S5_AUTH_FAIL=1
  [ "$status" -ne 0 ]
  [ "$(field '.status')" = "error" ]
  [ "$(field '.reason')" = "BACKUP_SERVICE_UNAVAILABLE" ]
  [[ "$(cat "${RESULT}")" != *"credential-marker-must-not-escape"* ]]
  [[ "$output" != *"credential-marker-must-not-escape"* ]]
  [ ! -f "${RM_CAPTURE}" ]
}

@test "delete-backup dry run does not reveal resolved storage details" {
  cat > "${MOCK_DIR}/mariadb.env" <<EOF
MINIO_BUCKET=internal-bucket-marker
MINIO_ENDPOINT=http://internal-endpoint-marker.invalid
EOF
  run_del MDBT_CONFIG_FILE="${MOCK_DIR}/mariadb.env" DRY_RUN=true BACKUP_NAME=snap-1
  [ "$status" -eq 0 ]
  assert_public_delete_result
  [[ "$(cat "${RESULT}")" != *"internal-bucket-marker"* ]]
  [[ "$(cat "${RESULT}")" != *"internal-endpoint-marker"* ]]
  [[ "$output" != *"internal-bucket-marker"* ]]
  [[ "$output" != *"internal-endpoint-marker"* ]]
  [ ! -f "${RM_CAPTURE}" ]
}
