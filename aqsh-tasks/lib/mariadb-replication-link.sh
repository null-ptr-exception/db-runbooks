#!/usr/bin/env bash
# =============================================================================
# lib/mariadb-replication-link.sh
# Cross-cluster replication link: assessment helpers.
#
# Context: both databases already exist. cluster-a runs the primary, cluster-b
# runs a standby that must be attached to it. This lib answers the one question
# `replication/attach` is built around:
#
#     can this standby be attached to the primary as-is, or must it be rebuilt?
#
# The peer address is derived, never configured per site: the platform's Cilium
# cluster mesh publishes an ExternalName Service `<namespace>-rw` in every
# namespace of every cluster, aliasing the primary's Service. An ExternalName
# carries no port of its own (it is a DNS alias), so the port belongs to the
# target Service and is internal config here, not a task input.
#
# Nothing in this file mutates anything. Wiring lives in the task scripts.
# =============================================================================

[[ -n "${_MARIADB_REPLICATION_LINK_LOADED:-}" ]] && return 0
_MARIADB_REPLICATION_LINK_LOADED=1

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$SCRIPT_DIR"
fi

# shellcheck source=aqsh-tasks/lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"
# shellcheck source=aqsh-tasks/lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"

# --- Deploy-time policy ------------------------------------------------------
# None of these are task inputs. They are per-deployment naming convention and
# safety policy, resolved as: internal config (*_DEFAULT) -> hardcoded fallback.
# The same reasoning the object-storage resolver uses: two deployments could
# reasonably differ, but one deployment wants the same value on every call.
#
# The config file MUST be loaded before the defaults below are evaluated — they
# read REPL_* values that do not exist until it has been sourced. Loading it
# here rather than relying on the task script means no caller can silently get
# hardcoded fallbacks by calling mdbt_load_config after this file. The task
# scripts call it again later; it is idempotent and never clobbers a value that
# is already set.
mdbt_load_config

# Mesh Service naming convention. `<namespace><suffix>` in `<namespace>`.
MDBR_PEER_SUFFIX="${REPL_PEER_SERVICE_SUFFIX_DEFAULT:--rw}"
MDBR_PEER_PORT="${REPL_PEER_PORT_DEFAULT:-3306}"

# Connection guard. Rebuilding destroys the standby's data, so an attach that
# might rebuild must not run while anything is still using it. 0 = any external
# connection blocks. Accounts listed here are platform-owned (operator probes,
# monitoring, healthchecks) and never count as external.
MDBR_MAX_EXTERNAL_CONNECTIONS="${REPL_MAX_EXTERNAL_CONNECTIONS_DEFAULT:-0}"
MDBR_IGNORED_ACCOUNTS="${REPL_IGNORED_ACCOUNTS_DEFAULT:-root,mariadb.sys,healthcheck,monitor,exporter,repl}"

# Bound every remote probe so an unreachable peer fails fast instead of hanging
# until the aqsh task timeout.
MDBR_PEER_CONNECT_TIMEOUT="${REPL_PEER_CONNECT_TIMEOUT_DEFAULT:-10}"

# --- Peer address ------------------------------------------------------------

# mdbr_peer_host [namespace]
# The mesh Service FQDN this cluster uses to reach the primary. Derived from the
# namespace alone — there is no per-site catalog to keep in sync.
mdbr_peer_host() {
  local ns="${1:-$DB_NAMESPACE}"
  printf '%s%s.%s.svc.cluster.local' "$ns" "$MDBR_PEER_SUFFIX" "$ns"
}

# --- SQL plumbing ------------------------------------------------------------

# mdbr_remote_sql <pod> <password> <host> <query>
# Run a query against the PEER database, from inside a local pod (the mesh
# Service is only resolvable in-cluster). Credentials are the local root
# credentials: the deployment provisions both clusters from the same secret
# material, which is also what makes the shared backup location work.
mdbr_remote_sql() {
  local pod="${1:?pod is required}" password="${2:?password is required}"
  local host="${3:?host is required}" query="${4:?query is required}"

  mariadb_exec "$pod" mariadb \
    -h "$host" -P "$MDBR_PEER_PORT" \
    --connect-timeout="$MDBR_PEER_CONNECT_TIMEOUT" \
    -u root -p"$password" -N -B -e "$query" 2>/dev/null
}

# --- GTID comparison ---------------------------------------------------------
#
# A MariaDB GTID position is a comma-separated list of `domain-server-seq`.
# Coverage must be compared PER DOMAIN, not per domain+server: the server_id
# component records whichever server last wrote that domain, so it changes
# whenever the primary is switched. Keying on domain+server (as the older
# mariadb_gtid_covers does, which is safe for its single-cluster sanity-check
# use) would read a post-failover position as "not covered" and send a healthy
# standby down the destructive rebuild path.

# mdbr_gtid_domain_covers <required> <actual>
# Returns 0 when <actual> is at or past <required> in every domain <required>
# names. An empty <required> is covered by anything.
mdbr_gtid_domain_covers() {
  local required="$1" actual="$2"

  awk -v required="$required" -v actual="$actual" '
    function remember(set, seen,   part, n, i, q, fields) {
      n = split(set, part, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", part[i])
        if (part[i] == "") continue
        fields = split(part[i], q, "-")
        if (fields != 3) continue
        if (!(q[1] in seen) || q[3] + 0 > seen[q[1]]) seen[q[1]] = q[3] + 0
      }
    }
    BEGIN {
      remember(actual, actual_seen)
      n = split(required, part, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", part[i])
        if (part[i] == "") continue
        fields = split(part[i], q, "-")
        if (fields != 3) continue
        if (!(q[1] in actual_seen) || actual_seen[q[1]] + 0 < q[3] + 0) exit 1
      }
      exit 0
    }'
}

# mdbr_gtid_has_server <gtid_list> <server_id>
# True when <gtid_list> contains at least one entry written by <server_id>.
# Replicated events keep the ORIGINATING server_id, so a standby's own id
# appearing in its binlog position means the standby itself was written to.
mdbr_gtid_has_server() {
  local gtid="$1" server_id="$2"

  awk -v gtid="$gtid" -v want="$server_id" '
    BEGIN {
      n = split(gtid, part, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", part[i])
        if (part[i] == "") continue
        if (split(part[i], q, "-") != 3) continue
        if (q[2] + 0 == want + 0) exit 0
      }
      exit 1
    }'
}

# --- Connection guard --------------------------------------------------------

# mdbr_external_connections <pod> <password>
# Echo a JSON object: {"total": N, "accounts": [{"account": ..., "connections": N}]}
# counting only genuinely external sessions. Excluded: this session, MariaDB's
# own internal threads, replication threads (their COMMAND is one of the
# Binlog Dump / Slave_* / Daemon set), and the platform accounts listed in
# MDBR_IGNORED_ACCOUNTS. Returns 1 if the query itself fails — an unreadable
# process list must not be mistaken for "nobody is connected".
mdbr_external_connections() {
  local pod="$1" password="$2"
  local ignored_sql rows

  # Build the account exclusion list as a quoted SQL set. Accounts are matched
  # on the bare username, lowercased, so 'app'@'10.0.0.1' and 'app'@'%' fold
  # together the same way information_schema reports them.
  ignored_sql="$(printf '%s' "$MDBR_IGNORED_ACCOUNTS" | awk -F, '
    {
      out = ""
      for (i = 1; i <= NF; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", $i)
        if ($i == "") continue
        gsub(/'"'"'/, "", $i)
        out = out (out == "" ? "" : ",") "'"'"'" tolower($i) "'"'"'"
      }
      print out
    }')"
  # Always exclude MariaDB's own pseudo-accounts even if config emptied the list.
  if [[ -n "$ignored_sql" ]]; then
    ignored_sql="'system user','event_scheduler',${ignored_sql}"
  else
    ignored_sql="'system user','event_scheduler'"
  fi

  rows="$(mariadb_sql "$pod" "$password" \
    "SELECT JSON_OBJECT('account', USER, 'connections', COUNT(*)) \
     FROM information_schema.PROCESSLIST \
     WHERE ID <> CONNECTION_ID() \
       AND USER IS NOT NULL AND USER <> '' \
       AND LOWER(USER) NOT IN (${ignored_sql}) \
       AND COMMAND NOT IN ('Binlog Dump','Slave_IO','Slave_SQL','Daemon') \
     GROUP BY USER ORDER BY COUNT(*) DESC, USER ASC")" || return 1

  printf '%s\n' "$rows" | jq -sc '
    map(select(. != null)) as $accounts
    | {total: ($accounts | map(.connections) | add // 0), accounts: $accounts}
  ' 2>/dev/null || return 1
}

# --- Link assessment ---------------------------------------------------------
#
# Four checks decide attach-vs-rebuild. Each one that fails is a distinct,
# actionable reason; the first failure wins because they are ordered from
# "no history at all" to "history exists but is unusable".
#
#   1 NO_REPLICATION_HISTORY  standby has no GTID position — nothing to resume
#                             from, and MariaDB cannot invent a starting point
#   2 GTID_DIVERGED           standby is ahead of the primary in some domain
#   3 STANDBY_HAS_LOCAL_WRITES standby's binlog carries its own writes
#   4 PRIMARY_BINLOG_PURGED   primary no longer keeps the binlog segment the
#                             standby would have to start from (the classic
#                             error 1236 — the most common real-world case)
#
# Anything the assessment cannot read (peer unreachable, unreadable position)
# is an ERROR, never a silent pass and never an implicit rebuild: guessing in
# either direction is worse than stopping.

# mdbr_assess <pod> <password> <peer_host> [already_linked]
# Echo a JSON object:
#   {"action":"attach"|"rebuild", "reason":<code>, "checks":{...}}
# Returns 0 on a usable assessment, 1 when it could not be completed (in which
# case MDBR_ASSESS_ERROR holds a stable reason code).
MDBR_ASSESS_ERROR=""
mdbr_assess() {
  local pod="$1" password="$2" peer_host="$3" already_linked="${4:-false}"
  local standby_slave_pos standby_binlog_pos standby_server_id
  local primary_pos primary_server_id primary_earliest_file primary_earliest_pos

  MDBR_ASSESS_ERROR=""

  standby_slave_pos="$(mariadb_sql "$pod" "$password" 'SELECT @@GLOBAL.gtid_slave_pos')" || {
    MDBR_ASSESS_ERROR="DATABASE_NOT_READY"; return 1; }
  standby_binlog_pos="$(mariadb_sql "$pod" "$password" 'SELECT @@GLOBAL.gtid_binlog_pos')" || {
    MDBR_ASSESS_ERROR="DATABASE_NOT_READY"; return 1; }
  standby_server_id="$(mariadb_sql "$pod" "$password" 'SELECT @@GLOBAL.server_id')" || {
    MDBR_ASSESS_ERROR="DATABASE_NOT_READY"; return 1; }

  primary_pos="$(mdbr_remote_sql "$pod" "$password" "$peer_host" 'SELECT @@GLOBAL.gtid_binlog_pos')" || {
    MDBR_ASSESS_ERROR="PEER_UNREACHABLE"; return 1; }
  primary_server_id="$(mdbr_remote_sql "$pod" "$password" "$peer_host" 'SELECT @@GLOBAL.server_id')" || {
    MDBR_ASSESS_ERROR="PEER_UNREACHABLE"; return 1; }
  if [[ -z "$primary_pos" ]]; then
    # A primary with an empty binlog position has binary logging off, so no
    # standby can ever attach to it. That is a configuration fault, not a
    # rebuildable state.
    MDBR_ASSESS_ERROR="PRIMARY_BINLOG_UNAVAILABLE"; return 1
  fi

  # Oldest binlog the primary still keeps, and the GTID position at its head:
  # everything before this point has been purged and is unrecoverable from the
  # primary. Position 4 is the first event after the binlog file header.
  primary_earliest_file="$(mdbr_remote_sql "$pod" "$password" "$peer_host" 'SHOW BINARY LOGS' \
    | awk 'NR == 1 { print $1 }')" || true
  if [[ -z "$primary_earliest_file" ]]; then
    MDBR_ASSESS_ERROR="PRIMARY_BINLOG_UNAVAILABLE"; return 1
  fi
  primary_earliest_pos="$(mdbr_remote_sql "$pod" "$password" "$peer_host" \
    "SELECT BINLOG_GTID_POS('${primary_earliest_file}', 4)")" || {
    MDBR_ASSESS_ERROR="PRIMARY_BINLOG_UNAVAILABLE"; return 1; }
  # NULL renders as the literal "NULL" under -N -B; treat it as "no purge floor
  # known" rather than a GTID list.
  [[ "$primary_earliest_pos" == "NULL" ]] && primary_earliest_pos=""

  # The standby's resume point is its SLAVE position, full stop. An earlier
  # version fell back to the standby's own binlog position when it had never
  # replicated — that is exactly backwards: a database that has only ever
  # written its own history has no resume point, and treating its binlog as one
  # invites comparing two unrelated histories that merely share a domain.
  local resume_pos="$standby_slave_pos"

  local action="attach" reason="LINK_RESUMABLE"

  # Server-id collision is checked FIRST and reported as its own outcome: with
  # equal ids MariaDB refuses to replicate at all ("master and slave have equal
  # MariaDB server ids", errno 1593), so no amount of GTID agreement helps. It
  # also makes GTID comparison meaningless — two clusters both writing as
  # server 10 produce positions like 0-10-100 and 0-10-4 that compare as
  # "covered" while sharing no history whatsoever.
  if [[ -n "$standby_server_id" && -n "$primary_server_id" \
        && "$standby_server_id" == "$primary_server_id" ]]; then
    action="rebuild"; reason="SERVER_ID_CONFLICT"
  elif [[ -z "$resume_pos" ]]; then
    action="rebuild"; reason="NO_REPLICATION_HISTORY"
  elif ! mdbr_gtid_domain_covers "$resume_pos" "$primary_pos"; then
    action="rebuild"; reason="GTID_DIVERGED"
  elif [[ "$already_linked" != "true" ]] \
    && [[ -n "$standby_binlog_pos" ]] \
    && mdbr_gtid_has_server "$standby_binlog_pos" "$standby_server_id"; then
    # Any write the standby made itself is treated as divergence, without
    # asking whether the primary "already covers" it. Within one domain both
    # servers allocate seq_no from the same counter, so a standby-local write
    # at 1-201-501 and an unrelated primary write at 1-101-600 compare as
    # covered while being entirely different history. Coverage cannot
    # distinguish them, and the failure mode of getting this wrong is silent
    # data divergence, so the check errs toward rebuild.
    #
    # Only applied to a standby that has NEVER been wired into the topology.
    # Once attached, the operator's own post-restore initialisation writes to
    # the standby under its own server_id (observed live: slave=0-10-100 while
    # binlog=0-100-104 on a freshly seeded, perfectly healthy standby), so
    # applying this check to an already-linked database would condemn every one
    # of them to a rebuild. For those, a broken link is a repair, not a
    # first-time attach.
    #
    # Cost of the conservatism that remains: a standby that was legitimately
    # promoted and later rejoined would also be sent to rebuild. That cannot
    # arise yet — nothing here promotes a standby. Revisit with promote.
    action="rebuild"; reason="STANDBY_HAS_LOCAL_WRITES"
  elif [[ -n "$primary_earliest_pos" ]] \
    && ! mdbr_gtid_domain_covers "$primary_earliest_pos" "$resume_pos"; then
    action="rebuild"; reason="PRIMARY_BINLOG_PURGED"
  fi

  jq -nc \
    --arg action "$action" \
    --arg reason "$reason" \
    --argjson idsDistinct \
      "$([[ -n "$standby_server_id" && -n "$primary_server_id" \
           && "$standby_server_id" != "$primary_server_id" ]] && echo true || echo false)" \
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
