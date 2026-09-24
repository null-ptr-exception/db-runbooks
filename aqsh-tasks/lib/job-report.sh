#!/usr/bin/env bash
# Optional MariaDB job reporting. Caller owns traps and supplies resolved target.
# No public task inputs or credentials are introduced here.
[[ -n "${_JOB_REPORT_LOADED:-}" ]] && return 0
_JOB_REPORT_LOADED=1
JOB_REPORT_ENABLED=false
JOB_REPORT_ACTIVE=false

JOB_REPORT_CONFIG_FILE="${JOB_REPORT_CONFIG_FILE:-/etc/aqsh/config/mariadb.env}"
# shellcheck disable=SC1090
if [[ -f "$JOB_REPORT_CONFIG_FILE" ]]; then source "$JOB_REPORT_CONFIG_FILE"; fi

_job_report_warn() { printf '%s\n' 'job-report: unable to persist execution record; task result is unchanged' >&2; }
# Hex literals are independent of NO_BACKSLASH_ESCAPES and cannot inject SQL.
_job_report_literal() {
  local hex
  hex="$(printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n')"
  if [[ -n "$hex" ]]; then printf "CONVERT(X'%s' USING utf8mb4)" "$hex"; else printf "''"; fi
}

# Print every descendant of $1 (recursive pgrep -P). Does not include $1.
# Snapshot while the root is alive; later KILL must use this list, not a live parent.
_job_report_descendant_pids() {
  local root="$1" cur child
  local -a queue=("$root")
  while ((${#queue[@]} > 0)); do
    cur="${queue[0]}"
    queue=("${queue[@]:1}")
    if ! command -v pgrep >/dev/null 2>&1; then
      return 0
    fi
    while IFS= read -r child; do
      [[ -n "$child" ]] || continue
      printf '%s\n' "$child"
      queue+=("$child")
    done < <(pgrep -P "$cur" 2>/dev/null || true)
  done
}

# Run mariadb_sql in the current shell with a wall-clock bound.
# Session SQL timeouts do not cover kubectl/transport hangs; this does.
# A timeout (exit 124) is not proof the statement did not commit.
_job_report_sql() {
  local pod="$1" password="$2" sql="$3"
  local timeout="${JOB_REPORT_SQL_TIMEOUT:-8}"
  local out_file pid deadline now child desc rc=0
  local -a tree=() more=()

  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || timeout=8
  out_file="$(mktemp "${TMPDIR:-/tmp}/job-report-sql.XXXXXX")" || return 1
  # Background in this shell so bats mocks of mariadb_sql remain visible.
  mariadb_sql "$pod" "$password" "$sql" >"$out_file" &
  pid=$!
  deadline=$(( $(date +%s) + timeout ))
  while kill -0 "$pid" 2>/dev/null; do
    now="$(date +%s)"
    if (( now >= deadline )); then
      # Capture the full descendant tree before any signal. TERM-ignoring
      # children can reparent to PPID=1 once $pid exits; a later pgrep -P
      # "$pid" would miss them.
      tree=()
      more=()
      if command -v pgrep >/dev/null 2>&1; then
        mapfile -t tree < <(_job_report_descendant_pids "$pid")
      fi
      for child in "${tree[@]}"; do
        kill -TERM "$child" 2>/dev/null || true
      done
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.2 2>/dev/null || sleep 1
      # Optional re-walk of survivors by saved PID (not by living parent).
      if command -v pgrep >/dev/null 2>&1; then
        for child in "$pid" "${tree[@]}"; do
          if kill -0 "$child" 2>/dev/null; then
            while IFS= read -r desc; do
              [[ -n "$desc" ]] || continue
              more+=("$desc")
            done < <(_job_report_descendant_pids "$child")
          fi
        done
      fi
      for child in "${tree[@]}" "${more[@]}"; do
        kill -KILL "$child" 2>/dev/null || true
      done
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$out_file"
      return 124
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
  wait "$pid" || rc=$?
  cat "$out_file"
  rm -f "$out_file"
  return "$rc"
}

job_report_enable() {
  JOB_REPORT_NAME="${1:-${0##*/}}"
  JOB_REPORT_ENABLED=true
}

job_report_start() {
  [[ "${JOB_REPORT_ENABLED:-false}" == true ]] || return 0
  [[ "${JOB_REPORT_ACTIVE:-false}" != true ]] || return 0
  [[ -n "${JOB_REPORT_DATABASE:-}${JOB_REPORT_TABLE:-}" ]] || return 0
  local pod="$1" password="$2" lengths job_len host_len message_len status_len stamp
  if [[ ! "${JOB_REPORT_DATABASE:-}" =~ ^[a-zA-Z0-9_]+$ || ! "${JOB_REPORT_TABLE:-}" =~ ^[a-zA-Z0-9_]+$ || -z "$pod" ]]; then
    _job_report_warn; return 0
  fi
  JOB_REPORT_TARGET="\`${JOB_REPORT_DATABASE}\`.\`${JOB_REPORT_TABLE}\`"
  JOB_REPORT_POD="$pod"
  lengths="$(_job_report_sql "$pod" "$password" "SELECT MAX(CASE WHEN COLUMN_NAME='job_name' THEN CHARACTER_MAXIMUM_LENGTH END), MAX(CASE WHEN COLUMN_NAME='host' THEN CHARACTER_MAXIMUM_LENGTH END), MAX(CASE WHEN COLUMN_NAME='message' THEN CHARACTER_MAXIMUM_LENGTH END), MAX(CASE WHEN COLUMN_NAME='status' THEN CHARACTER_MAXIMUM_LENGTH END) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$JOB_REPORT_DATABASE' AND TABLE_NAME='$JOB_REPORT_TABLE'")" || { _job_report_warn; return 0; }
  read -r job_len host_len message_len status_len <<< "$lengths" || { _job_report_warn; return 0; }
  if [[ ! "$job_len" =~ ^[1-9][0-9]*$ || ! "$host_len" =~ ^[1-9][0-9]*$ || ! "$message_len" =~ ^[1-9][0-9]*$ || ! "$status_len" =~ ^[1-9][0-9]*$ ]] || (( ${#JOB_REPORT_NAME} > job_len || ${#pod} > host_len || status_len < 6 )); then
    _job_report_warn; return 0
  fi
  JOB_REPORT_MESSAGE_LIMIT="$message_len"
  JOB_REPORT_NAME_SQL="$(_job_report_literal "$JOB_REPORT_NAME")"
  JOB_REPORT_HOST_SQL="$(_job_report_literal "$pod")"
  stamp="$(_job_report_sql "$pod" "$password" "SET SESSION sql_mode='STRICT_ALL_TABLES', innodb_lock_wait_timeout=3, lock_wait_timeout=3, max_statement_time=5; SET @job_report_start=NOW(); INSERT INTO $JOB_REPORT_TARGET (job_name,start_time,end_time,status,flag,host,message) SELECT $JOB_REPORT_NAME_SQL,@job_report_start,NULL,'Start',2,$JOB_REPORT_HOST_SQL,'' WHERE NOT EXISTS (SELECT 1 FROM $JOB_REPORT_TARGET WHERE BINARY job_name=BINARY $JOB_REPORT_NAME_SQL AND BINARY host=BINARY $JOB_REPORT_HOST_SQL AND start_time=@job_report_start AND flag=2 AND end_time IS NULL); SELECT IF(ROW_COUNT()=1,DATE_FORMAT(@job_report_start,'%Y-%m-%d %H:%i:%s'),'');")" || { _job_report_warn; return 0; }
  if [[ ! "$stamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then _job_report_warn; return 0; fi
  JOB_REPORT_PASSWORD="$password"
  JOB_REPORT_START="$stamp"
  JOB_REPORT_ACTIVE=true
}

job_report_finish() {
  [[ "${JOB_REPORT_ACTIVE:-false}" == true ]] || return 0
  local state="$1" message="$2" flag=4 label=Failed result
  [[ "$state" != success ]] || { flag=1; label=Finish; }
  # Guard the transition with Start. Completed rows must never be overwritten.
  result="$(_job_report_sql "$JOB_REPORT_POD" "$JOB_REPORT_PASSWORD" "SET SESSION sql_mode='STRICT_ALL_TABLES', innodb_lock_wait_timeout=3, lock_wait_timeout=3, max_statement_time=5; UPDATE $JOB_REPORT_TARGET SET end_time=NOW(),status='$label',flag=$flag,message=LEFT($(_job_report_literal "$message"),$JOB_REPORT_MESSAGE_LIMIT) WHERE BINARY job_name=BINARY $JOB_REPORT_NAME_SQL AND BINARY host=BINARY $JOB_REPORT_HOST_SQL AND start_time='$JOB_REPORT_START' AND flag=2 AND end_time IS NULL; SELECT ROW_COUNT();")" || result=''
  [[ "$result" == 1 ]] || _job_report_warn
  JOB_REPORT_ACTIVE=false
  unset JOB_REPORT_PASSWORD
  return 0
}

# Invoke from the caller's EXIT trap, alongside its existing cleanup.
# A successful process exit without a semantic result is NOT proof of success.
job_report_exit() {
  job_report_finish failure "Task exited without a final result (exit code $1)"
}
