#!/usr/bin/env bash
set +x
set -euo pipefail

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi
# shellcheck source=../../lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=../../lib/k8s.sh
source "${LIB_DIR}/k8s.sh"
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"
CONFIG_FILE="${MARIADB_CONFIG_FILE:-/etc/aqsh/config/mariadb.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
# shellcheck source=../../lib/mariadb-sessions.sh
source "${LIB_DIR}/mariadb-sessions.sh"

NAMESPACE="${DB_NAMESPACE:-}"
TARGET_POD="${TARGET_POD:-}"
ACTION="${SESSION_ACTION:-diagnose}"
CONNECTION_ID="${CONNECTION_ID:-}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"
EXPECTED_SESSION="${EXPECTED_SESSION:-}"
SESSION_ROW_LIMIT="${SESSION_ROW_LIMIT_DEFAULT:-100}"
SESSION_SQL_LIMIT="${SESSION_SQL_LIMIT_DEFAULT:-4096}"
SESSION_READ_TIMEOUT="${SESSION_READ_TIMEOUT_DEFAULT:-5}"
SESSION_VERIFY_ATTEMPTS="${SESSION_VERIFY_ATTEMPTS_DEFAULT:-3}"
PROTECTED_USERS="root,mariadb.sys,mysql,system user,event_scheduler,${SESSION_PROTECTED_USERS_DEFAULT:-}"
RESULT_FILE="${AQSH_RESULT_FILE:-}"
COLLECTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
POD_EPOCH=""

emit() {
  local status="$1" reason="$2" extra="${3:-}" result
  [[ -n "$extra" ]] || extra='{}'
  result="$(jq -nc --arg status "$status" --arg reason "$reason" \
    --arg ns "$NAMESPACE" --arg pod "$TARGET_POD" --arg action "$ACTION" \
    --arg at "$COLLECTED_AT" --argjson extra "$extra" \
    '{status:$status, reason_code:$reason, namespace:$ns, target_pod:$pod,
      action:$action, collected_at:$at, changed:false} + $extra')"
  [[ -z "$RESULT_FILE" ]] || printf '%s\n' "$result" > "$RESULT_FILE"
  printf '%s\n' "$result"
}
block() { emit BLOCKED "$1"; exit 1; }
error() { emit ERROR "$1"; exit 1; }
is_uint() { [[ "$1" =~ ^[1-9][0-9]*$ && ${#1} -le 10 ]]; }
is_id() { [[ "$1" =~ ^[1-9][0-9]*$ && ${#1} -le 20 ]]; }

[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#NAMESPACE} -le 63 ]] \
  || block SESSION_INVALID_INPUT
[[ "$TARGET_POD" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ && ${#TARGET_POD} -le 253 ]] \
  || block SESSION_INVALID_INPUT
case "$ACTION" in diagnose|kill-query|kill-connection) ;; *) block SESSION_INVALID_INPUT ;; esac
for setting in SESSION_ROW_LIMIT SESSION_SQL_LIMIT SESSION_READ_TIMEOUT SESSION_VERIFY_ATTEMPTS; do
  is_uint "${!setting}" || block SESSION_INVALID_POLICY
done
(( SESSION_ROW_LIMIT <= 1000 && SESSION_SQL_LIMIT <= 65536 &&
   SESSION_READ_TIMEOUT <= 10 && SESSION_VERIFY_ATTEMPTS <= 5 )) || block SESSION_INVALID_POLICY
if [[ "$ACTION" != diagnose ]]; then
  is_id "$CONNECTION_ID" || block SESSION_INVALID_INPUT
  [[ "$DRY_RUN" == true || "$DRY_RUN" == false ]] || block SESSION_INVALID_INPUT
  [[ "$CONFIRM" == true || "$CONFIRM" == false ]] || block SESSION_INVALID_INPUT
  [[ "$DRY_RUN:$CONFIRM" == true:false || "$DRY_RUN:$CONFIRM" == false:true ]] \
    || block SESSION_CONFIRM_REQUIRED
  if [[ "$DRY_RUN" == false ]]; then
    [[ "$EXPECTED_SESSION" =~ ^[a-f0-9]{64}$ ]] || block SESSION_TARGET_CHANGED
  fi
fi

mariadb_set_target "${K8S_CONTEXT:-}" "$NAMESPACE" "${MARIADB_RESOURCE:-mariadb}" "" "${MARIADB_CONTAINER:-mariadb}"
_on_ambiguous() { block SESSION_TARGET_UNRESOLVED; }
_on_none() { block SESSION_TARGET_UNRESOLVED; }
mariadb_autodetect_target true _on_ambiguous _on_none
MEMBERS="$(mariadb_list_member_pods)" || block SESSION_TARGET_UNRESOLVED
printf '%s\n' "$MEMBERS" | grep -Fxq -- "$TARGET_POD" || block SESSION_POD_NOT_MEMBER
POD_JSON="$(_kubectl get pod "$TARGET_POD" -o json 2>/dev/null)" || block SESSION_TARGET_UNRESOLVED
POD_EPOCH="$(jq -er --arg container "$MARIADB_CONTAINER" '
  select(.status.phase == "Running" and .metadata.deletionTimestamp == null) |
  .metadata.uid as $uid | .status.containerStatuses[] |
  select(.name == $container and .state.running != null) |
  "\($uid):\(.restartCount)"' <<< "$POD_JSON")" || block SESSION_TARGET_UNRESOLVED
[[ "$POD_EPOCH" =~ ^[a-zA-Z0-9-]+:[0-9]+$ ]] || block SESSION_TARGET_UNRESOLVED
PASSWORD="$(mariadb_read_root_password "" "$TARGET_POD")" || block SESSION_CREDENTIALS_UNAVAILABLE

# JSON_OBJECT escapes control characters itself. --raw prevents the batch
# client from escaping JSON a second time. Never forward client stderr.
sql() {
  mariadb_exec "$TARGET_POD" mariadb -u root -p"$PASSWORD" \
    --connect-timeout=5 --raw -N -B -e "$1" 2>/dev/null
}
read_rows() {
  local query raw rows
  query="$(sessions_query "$1")" || return 1
  raw="$(sql "SET STATEMENT max_statement_time=$SESSION_READ_TIMEOUT FOR $query")" || return 1
  rows="$(jq -sec 'if all(.[]; type == "object") then . else error("invalid rows") end' <<< "$raw")" || return 1
  if [[ "$1" == connection_status ]]; then
    jq -e 'length == 1 and (.[0] | .threads_running != null and
      .threads_connected != null and .max_connections != null and
      .row_lock_current_waits != null)' <<< "$rows" >/dev/null || return 1
  fi
  printf '%s\n' "$rows"
}
section() {
  local rows at
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if rows="$(read_rows "$1")"; then
    jq -nc --arg at "$at" --argjson rows "$rows" --argjson limit "$SESSION_ROW_LIMIT" \
      '{collected:true, collected_at:$at, truncated:($rows|length > $limit), rows:$rows[:$limit]}'
  else
    jq -nc --arg at "$at" '{collected:false, collected_at:$at,
      truncated:null, rows:null, error:"collection unavailable"}'
  fi
}

if [[ "$ACTION" == diagnose ]]; then
  SECTIONS='{}'
  for name in processlist distribution connection_status transactions lock_waits; do
    DATA="$(section "$name")"
    SECTIONS="$(jq -c --arg name "$name" --argjson data "$DATA" '. + {($name):$data}' <<< "$SECTIONS")"
  done
  EXTRA="$(jq -nc --argjson sections "$SECTIONS" '
    {snapshot_type:"point-in-time", atomic_snapshot:false, sections:$sections,
     partial:([$sections[] | select(.collected == false)]|length > 0),
     findings:(if $sections.lock_waits.collected then
       [$sections.lock_waits.rows | group_by(.blocking_connection_id)[] |
         {type:"observed_row_lock_blocker", connection_id:.[0].blocking_connection_id,
          transaction_id:.[0].blocking_transaction_id,
          observed_waiting_transactions:(map(.waiting_transaction_id)|unique|length)}]
       else null end)}')"
  AVAILABLE="$(jq '[.[] | select(.collected)] | length' <<< "$SECTIONS")"
  if [[ "$AVAILABLE" == 0 ]]; then
    emit ERROR SESSION_DIAGNOSTICS_UNAVAILABLE "$EXTRA"; exit 1
  elif [[ "$AVAILABLE" != 5 ]]; then
    emit PARTIAL SESSION_DIAGNOSTICS_PARTIAL "$EXTRA"
  else
    emit READY SESSION_DIAGNOSTICS_READY "$EXTRA"
  fi
  exit 0
fi

BEFORE="$(read_rows inspect)" || error SESSION_INSPECTION_FAILED
[[ "$(jq length <<< "$BEFORE")" == 0 ]] && { emit NO_ACTION SESSION_NOT_FOUND; exit 0; }
jq -e --arg id "$CONNECTION_ID" 'length == 1 and .[0].connection_id == $id and
  (.[0].query_id|type == "string") and (.[0].fingerprint|test("^[a-f0-9]{64}$"))' \
  <<< "$BEFORE" >/dev/null || error SESSION_INSPECTION_FAILED
BEFORE="$(jq -c '.[0]' <<< "$BEFORE")"
# Only normal client commands are eligible. The built-in protected users cannot
# be removed by deployment configuration; additional users can be protected.
jq -e --arg users "$PROTECTED_USERS" '
  . as $row | (($users|ascii_downcase|split(",")|map(gsub("^ +| +$";""))) |
    index($row.user|ascii_downcase)) == null and
  ($row.self == 0) and
  (["Query","Execute","Sleep"]|index($row.command)) != null' \
  <<< "$BEFORE" >/dev/null || block SESSION_PROTECTED_TARGET
ORIGINAL_QUERY_ID="$(jq -r .query_id <<< "$BEFORE")"
ORIGINAL_TRX_ID="$(jq -r '.transaction_id // ""' <<< "$BEFORE")"
[[ "$ORIGINAL_TRX_ID" =~ ^[0-9]*$ && ${#ORIGINAL_TRX_ID} -le 20 ]] || error SESSION_INSPECTION_FAILED
[[ "$ORIGINAL_QUERY_ID" =~ ^[0-9]+$ && ${#ORIGINAL_QUERY_ID} -le 20 ]] || error SESSION_INSPECTION_FAILED
if [[ "$ACTION" == kill-query ]]; then
  is_id "$ORIGINAL_QUERY_ID" || block SESSION_QUERY_NOT_RUNNING
  jq -e '.command != "Sleep" and .sql != null' <<< "$BEFORE" >/dev/null \
    || block SESSION_QUERY_NOT_RUNNING
fi
EXTRA="$(jq -nc --argjson before "$BEFORE" '{before:$before, kill_issued:false}')"
if [[ "$DRY_RUN" == true ]]; then
  emit DRY_RUN_READY SESSION_DRY_RUN_READY "$EXTRA"; exit 0
fi
[[ "$EXPECTED_SESSION" == "$(jq -r .fingerprint <<< "$BEFORE")" ]] || block SESSION_TARGET_CHANGED
# QUERY ID targets the inspected statement rather than whatever statement the
# same connection might execute next. Connection KILL retains a narrow race
# between the inspection and command, documented in sessions.md.
if [[ "$ACTION" == kill-query ]]; then
  COMMAND="KILL QUERY ID $ORIGINAL_QUERY_ID;"
else
  COMMAND="KILL CONNECTION $CONNECTION_ID;"
fi
# Record an uncertain attempt before the network call as well: the server may
# act even if this process is interrupted before it receives acknowledgement.
EXTRA="$(jq -c '. + {changed:null, kill_issued:true, command_accepted:null,
  verification:{state:"unavailable"}}' <<< "$EXTRA")"
emit UNKNOWN SESSION_KILL_ATTEMPTING "$EXTRA"
if ! sql "$COMMAND" >/dev/null; then
  EXTRA="$(jq -c '. + {changed:null, kill_issued:true, command_accepted:null,
    verification:{state:"unavailable"}}' <<< "$EXTRA")"
  emit ERROR SESSION_KILL_FAILED "$EXTRA"; exit 1
fi
EXTRA="$(jq -c '. + {changed:true, kill_issued:true, command_accepted:true,
  verification:{state:"pending"}}' <<< "$EXTRA")"
# Persist acceptance before verification, so an interrupted task does not leave
# a result claiming that no mutation was attempted.
emit ACCEPTED SESSION_KILL_ACCEPTED "$EXTRA"
for (( attempt=1; attempt<=SESSION_VERIFY_ATTEMPTS; attempt++ )); do
  AFTER="$(read_rows verify)" || {
    EXTRA="$(jq -c '.verification={state:"unavailable"}' <<< "$EXTRA")"
    emit UNKNOWN SESSION_VERIFICATION_UNAVAILABLE "$EXTRA"; exit 0
  }
  jq -e 'length == 1 and (.[0] | .connection_present | IN(0,1)) and
    (.[0] | .original_query_present | IN(0,1)) and
    (.[0] | .original_transaction_present | IN(0,1)) and
    (.[0].original_transaction_waiters | type == "number" and . >= 0)' \
    <<< "$AFTER" >/dev/null || {
      EXTRA="$(jq -c '.verification={state:"unavailable"}' <<< "$EXTRA")"
      emit UNKNOWN SESSION_VERIFICATION_UNAVAILABLE "$EXTRA"; exit 0
    }
  AFTER="$(jq -c '.[0]' <<< "$AFTER")"
  if [[ "$ACTION" == kill-query ]]; then
    DONE="$(jq '.original_query_present == 0' <<< "$AFTER")"
  else
    DONE="$(jq '.connection_present == 0 and .original_transaction_present == 0' <<< "$AFTER")"
  fi
  EXTRA="$(jq -c --argjson after "$AFTER" --argjson 'done' "$DONE" \
    '.verification=$after + {state:(if $done then "verified" else "pending" end)}' <<< "$EXTRA")"
  if [[ "$DONE" == true ]]; then
    emit VERIFIED SESSION_TERMINATION_VERIFIED "$EXTRA"; exit 0
  fi
  (( attempt == SESSION_VERIFY_ATTEMPTS )) || sleep 1
done
emit PENDING SESSION_TERMINATION_PENDING "$EXTRA"
