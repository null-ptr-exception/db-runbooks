#!/usr/bin/env bash
# =============================================================================
# lib/mariadb-replication-assessment.sh
# Read-only attach-versus-rebuild decision for the v24 cross-cluster link.
# Sourced by mariadb-replication-link.sh after its SQL/GTID helpers are defined.
# =============================================================================

[[ -n "${_MARIADB_REPLICATION_ASSESSMENT_LOADED:-}" ]] && return 0
_MARIADB_REPLICATION_ASSESSMENT_LOADED=1

# Every failure emits its stable reason because command substitutions cannot
# retain a variable assignment made in the child shell.
# shellcheck disable=SC2034
MDBR_ASSESS_ERROR=""

mdbr_assess_reason() {
  local out="$1" reason
  reason="$(jq -r '.error // empty' <<<"$out" 2>/dev/null || true)"
  printf '%s' "${reason:-INTERNAL_ERROR}"
}

_mdbr_assess_fail() {
  MDBR_ASSESS_ERROR="$1"
  jq -nc --arg e "$1" '{error: $e}'
  return 1
}

# mdbr_assess <pod> <password> <peer_host> [already_linked]
# Echo {action,reason,checks}; return 1 with a stable JSON error if any required
# local or peer value cannot be read. Unknown state never authorizes rebuild.
mdbr_assess() {
  local pod="$1" password="$2" peer_host="$3" already_linked="${4:-false}"
  local standby_slave_pos standby_binlog_pos standby_server_id
  local primary_pos primary_server_id primary_earliest_file primary_earliest_pos
  local primary_binlogs resume_pos action="attach" reason="LINK_RESUMABLE"

  # Direct callers read this; command-substitution callers use JSON stdout.
  # shellcheck disable=SC2034
  MDBR_ASSESS_ERROR=""
  standby_slave_pos="$(mariadb_sql "$pod" "$password" 'SELECT @@GLOBAL.gtid_slave_pos')" || {
    _mdbr_assess_fail "DATABASE_NOT_READY"; return 1; }
  standby_binlog_pos="$(mariadb_sql "$pod" "$password" 'SELECT @@GLOBAL.gtid_binlog_pos')" || {
    _mdbr_assess_fail "DATABASE_NOT_READY"; return 1; }
  standby_server_id="$(mariadb_sql "$pod" "$password" 'SELECT @@GLOBAL.server_id')" || {
    _mdbr_assess_fail "DATABASE_NOT_READY"; return 1; }

  primary_pos="$(mdbr_remote_sql "$pod" "$password" "$peer_host" 'SELECT @@GLOBAL.gtid_binlog_pos')" || {
    _mdbr_assess_fail "PEER_UNREACHABLE"; return 1; }
  primary_server_id="$(mdbr_remote_sql "$pod" "$password" "$peer_host" 'SELECT @@GLOBAL.server_id')" || {
    _mdbr_assess_fail "PEER_UNREACHABLE"; return 1; }
  if [[ -z "$standby_server_id" || -z "$primary_server_id" ]]; then
    _mdbr_assess_fail "DATABASE_NOT_READY"; return 1
  fi
  if [[ -z "$primary_pos" ]]; then
    _mdbr_assess_fail "PRIMARY_BINLOG_UNAVAILABLE"; return 1
  fi

  # Capture the query before parsing so an unreachable peer is distinct from a
  # successful primary with no binary logs.
  if ! primary_binlogs="$(mdbr_remote_sql "$pod" "$password" "$peer_host" 'SHOW BINARY LOGS')"; then
    _mdbr_assess_fail "PEER_UNREACHABLE"; return 1
  fi
  primary_earliest_file="$(awk 'NR == 1 { print $1 }' <<<"$primary_binlogs")"
  if [[ -z "$primary_earliest_file" ]]; then
    _mdbr_assess_fail "PRIMARY_BINLOG_UNAVAILABLE"; return 1
  fi
  primary_earliest_pos="$(mdbr_remote_sql "$pod" "$password" "$peer_host" \
    "SELECT BINLOG_GTID_POS('${primary_earliest_file}', 4)")" || {
    _mdbr_assess_fail "PRIMARY_BINLOG_UNAVAILABLE"; return 1; }
  [[ "$primary_earliest_pos" == "NULL" ]] && primary_earliest_pos=""

  # Only gtid_slave_pos is a resume point. A local binlog position without
  # replication history belongs to a different history.
  resume_pos="$standby_slave_pos"
  if [[ "$standby_server_id" == "$primary_server_id" ]]; then
    action="rebuild"; reason="SERVER_ID_CONFLICT"
  elif [[ -z "$resume_pos" ]]; then
    action="rebuild"; reason="NO_REPLICATION_HISTORY"
  elif ! mdbr_gtid_domain_covers "$resume_pos" "$primary_pos"; then
    action="rebuild"; reason="GTID_DIVERGED"
  elif [[ "$already_linked" != "true" ]] \
    && [[ -n "$standby_binlog_pos" ]] \
    && mdbr_gtid_has_server "$standby_binlog_pos" "$standby_server_id"; then
    # A first-time standby write is divergence. Already-linked standbys may
    # legitimately contain operator initialization under their own server_id.
    action="rebuild"; reason="STANDBY_HAS_LOCAL_WRITES"
  elif [[ -n "$primary_earliest_pos" ]] \
    && ! mdbr_gtid_domain_covers "$primary_earliest_pos" "$resume_pos"; then
    action="rebuild"; reason="PRIMARY_BINLOG_PURGED"
  fi

  jq -nc \
    --arg action "$action" \
    --arg reason "$reason" \
    --argjson idsDistinct \
      "$([[ "$standby_server_id" != "$primary_server_id" ]] && echo true || echo false)" \
    --argjson has_history "$([[ -n "$resume_pos" ]] && echo true || echo false)" \
    --argjson within_primary_history \
      "$(mdbr_gtid_domain_covers "$resume_pos" "$primary_pos" && echo true || echo false)" \
    --argjson primary_retains_binlog \
      "$([[ -z "$primary_earliest_pos" ]] || mdbr_gtid_domain_covers "$primary_earliest_pos" "$resume_pos" \
         && echo true || echo false)" \
    --argjson local_writes \
      "$([[ -n "$standby_binlog_pos" ]] && mdbr_gtid_has_server "$standby_binlog_pos" "$standby_server_id" \
         && echo true || echo false)" \
    --argjson already_linked "$([[ "$already_linked" == "true" ]] && echo true || echo false)" \
    '{
      action: $action,
      reason: $reason,
      checks: {
        already_linked: $already_linked,
        server_ids_distinct: $idsDistinct,
        has_replication_history: $has_history,
        within_primary_history: $within_primary_history,
        primary_retains_binlog: $primary_retains_binlog,
        standby_has_local_writes: $local_writes
      }
    }'
}
