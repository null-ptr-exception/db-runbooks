#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  export REPORT_LIB="$REPO_ROOT/aqsh-tasks/lib/job-report.sh"
  export JOB_REPORT_CONFIG_FILE="$BATS_TEST_TMPDIR/absent.env"
  export JOB_REPORT_DATABASE=operations JOB_REPORT_TABLE=job_history
  export REPORT_SQL_LOG="$BATS_TEST_TMPDIR/sql.log"
  export REPORT_DRIVER="$BATS_TEST_TMPDIR/driver.sh"
  cat > "$REPORT_DRIVER" <<'DRIVER'
set -euo pipefail
source "$REPORT_LIB"
mariadb_sql() {
  printf '%s\n' "$3" >> "$REPORT_SQL_LOG"
  case "$3" in
    *information_schema.COLUMNS*)
      [[ "${FAIL_STAGE:-}" != metadata ]] || return 1
      printf '%s\n' "${LENGTHS:-80 80 255 16}" ;;
    *INSERT\ INTO*)
      [[ "${FAIL_STAGE:-}" != insert ]] || return 1
      [[ "${FAIL_STAGE:-}" != collision ]] || return 0
      printf '%s\n' '2026-01-02 03:04:05' ;;
    *UPDATE*)
      [[ "${FAIL_STAGE:-}" != update ]] || return 1
      printf '%s\n' "${UPDATE_COUNT:-1}" ;;
    *) printf 'unexpected SQL\n' >&2; exit 97 ;;
  esac
}
trap 'rc=$?; job_report_exit "$rc"; printf "cleaned\n"; exit "$rc"' EXIT
case "${ACTION:-normal}" in
  disabled) job_report_start db-0 password; job_report_finish success done; exit ;;
  default_name) job_report_enable ;;
  normal | exit | twice) job_report_enable "${REPORT_NAME:-custom_job}" ;;
  *) printf 'unexpected driver action\n' >&2; exit 97 ;;
esac
job_report_start db-0 password
case "${ACTION:-normal}" in
  exit) exit "${EXIT_CODE:-7}" ;;
  twice) job_report_start db-0 password ;;
esac
job_report_finish "${OUTCOME:-success}" "${MESSAGE:-done}"
job_report_finish failure 'must not overwrite'
printf 'task-result\n'
DRIVER
}

@test "reporting requires both opt-in and deployment settings" {
  run env ACTION=disabled bash "$REPORT_DRIVER"
  [ "$status" -eq 0 ]
  [ ! -f "$REPORT_SQL_LOG" ]
  run env JOB_REPORT_DATABASE= JOB_REPORT_TABLE= bash "$REPORT_DRIVER"
  [ "$status" -eq 0 ]
  [ ! -f "$REPORT_SQL_LOG" ]
  [[ "$output" != *job-report:* ]]
}

@test "invalid or incomplete identifiers warn without SQL or task failure" {
  for database in '' 'bad.name' 'ops`; DROP TABLE x; --'; do
    run env JOB_REPORT_DATABASE="$database" bash "$REPORT_DRIVER"
    [ "$status" -eq 0 ]
    [[ "$output" == *job-report:*task-result*cleaned* ]]
    [ ! -f "$REPORT_SQL_LOG" ]
  done
}

@test "success inserts DB time and completes same unfinished identity only once" {
  run env ACTION=twice bash "$REPORT_DRIVER"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'INSERT INTO' "$REPORT_SQL_LOG")" -eq 1 ]
  [ "$(grep -c 'UPDATE' "$REPORT_SQL_LOG")" -eq 1 ]
  grep -q "@job_report_start=NOW()" "$REPORT_SQL_LOG"
  grep -q "NULL,'Start',2" "$REPORT_SQL_LOG"
  grep -q "status='Finish',flag=1" "$REPORT_SQL_LOG"
  grep -q "start_time='2026-01-02 03:04:05' AND flag=2 AND end_time IS NULL" "$REPORT_SQL_LOG"
  grep -q 'WHERE NOT EXISTS' "$REPORT_SQL_LOG"
  grep -q 'BINARY job_name=BINARY' "$REPORT_SQL_LOG"
  [[ "$output" == $'task-result\ncleaned' ]]
}

@test "semantic failure is Failed even when process succeeds" {
  run env OUTCOME=failure bash "$REPORT_DRIVER"
  [ "$status" -eq 0 ]
  grep -q "status='Failed',flag=4" "$REPORT_SQL_LOG"
}

@test "unexpected exits preserve exit status and existing cleanup" {
  for code in 0 7; do
    run env ACTION=exit EXIT_CODE="$code" bash "$REPORT_DRIVER"
    [ "$status" -eq "$code" ]
    [[ "$output" == cleaned ]]
    grep -q "status='Failed',flag=4" "$REPORT_SQL_LOG"
  done
}

@test "metadata insert and update failures are best effort and do not leak SQL or passwords" {
  for stage in metadata insert update collision; do
    rm -f "$REPORT_SQL_LOG"
    run env FAIL_STAGE="$stage" bash "$REPORT_DRIVER"
    [ "$status" -eq 0 ]
    [[ "$output" == *job-report:*task-result*cleaned* ]]
    [[ "$output" != *password* && "$output" != *SELECT* ]]
    if [[ "$stage" != update ]]; then
      if grep -q 'UPDATE' "$REPORT_SQL_LOG"; then return 1; fi
    fi
  done
}

@test "missing schema and oversized identities skip insert instead of truncating identity" {
  for lengths in 'NULL NULL NULL NULL' '80 80 255 5' '2 80 255 16' '80 2 255 16'; do
    rm -f "$REPORT_SQL_LOG"
    run env LENGTHS="$lengths" bash "$REPORT_DRIVER"
    [ "$status" -eq 0 ]
    [[ "$output" == *job-report:* ]]
    if grep -q 'INSERT INTO' "$REPORT_SQL_LOG"; then return 1; fi
  done
}

@test "message is truncated and SQL metacharacters are hex encoded" {
  run env LENGTHS='80 80 4 16' REPORT_NAME="O'Reilly\\job" MESSAGE="a'b;cdef" bash "$REPORT_DRIVER"
  [ "$status" -eq 0 ]
  grep -q "message=LEFT(CONVERT(X'6127623b63646566' USING utf8mb4),4)" "$REPORT_SQL_LOG"
  if grep -q "O'Reilly" "$REPORT_SQL_LOG"; then return 1; fi
  grep -q "CONVERT(X'4f275265696c6c795c6a6f62' USING utf8mb4)" "$REPORT_SQL_LOG"
}

@test "update mismatch warns and is not retried" {
  run env UPDATE_COUNT=0 bash "$REPORT_DRIVER"
  [ "$status" -eq 0 ]
  [[ "$output" == *job-report:* ]]
  [ "$(grep -c 'UPDATE' "$REPORT_SQL_LOG")" -eq 1 ]
}

@test "deployment config file supplies the only two required values" {
  printf 'JOB_REPORT_DATABASE=operations\nJOB_REPORT_TABLE=job_history\n' > "$BATS_TEST_TMPDIR/report.env"
  run env JOB_REPORT_DATABASE= JOB_REPORT_TABLE= JOB_REPORT_CONFIG_FILE="$BATS_TEST_TMPDIR/report.env" bash "$REPORT_DRIVER"
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2016 # SQL identifiers are literal backticks.
  grep -q 'INSERT INTO `operations`.`job_history`' "$REPORT_SQL_LOG"
}

@test "omitting the custom job name defaults to the caller script filename" {
  run env ACTION=default_name bash "$REPORT_DRIVER"
  [ "$status" -eq 0 ]
  grep -q "CONVERT(X'6472697665722e7368' USING utf8mb4)" "$REPORT_SQL_LOG"
}
