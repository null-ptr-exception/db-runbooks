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
# Read by attach/rebuild, which source this lib.
# shellcheck disable=SC2034
MDBR_MAX_EXTERNAL_CONNECTIONS="${REPL_MAX_EXTERNAL_CONNECTIONS_DEFAULT:-0}"
MDBR_IGNORED_ACCOUNTS="${REPL_IGNORED_ACCOUNTS_DEFAULT:-root,mariadb.sys,healthcheck,monitor,exporter,repl}"

# Bound every remote probe so an unreachable peer fails fast instead of hanging
# until the aqsh task timeout.
MDBR_PEER_CONNECT_TIMEOUT="${REPL_PEER_CONNECT_TIMEOUT_DEFAULT:-10}"

# mariadb-operator 0.0.24 hard-codes 10+ordinal when it first configures
# local replication; it does not have the newer serverIdStartIndex field. A
# standby deployment therefore supplies its disjoint range as deploy-time
# policy, and attach applies it to the live members before using native SQL.
# Empty means that the deployment has not opted into this v24 remapping; the
# normal SERVER_ID_CONFLICT guard remains in force.
MDBR_SERVER_ID_START_INDEX="${REPL_SERVER_ID_START_INDEX_DEFAULT:-}"

# ServiceAccount used to mint the peer TokenRequest bearer. Prefer this over
# JWT parsing so a projected-token claim shape cannot silently skip minting.
MDBR_PEER_TOKEN_SA="${REPL_PEER_TOKEN_SA_DEFAULT:-}"

# Operator local replication uses the named connection "mariadb-operator".
# Cross-cluster attach wires the *default* (unnamed) connection on the writable
# primary: named CHANGE MASTER requires master_info_repository=TABLE, which the
# primary often still has as FILE, so aqsh-cross-cluster never appears and wire
# fails with configured=false. Status/detach ignore the operator connection.
MDBR_OPERATOR_CONNECTION_NAME="${REPL_OPERATOR_CONNECTION_NAME_DEFAULT:-mariadb-operator}"

# mdbr_require_v24 <operation>
# PR #99 intentionally targets mariadb-operator 0.24 only. That generation has
# no ExternalMariaDB or multiCluster API, so the runbook owns the SQL link. Fail
# closed when discovery is uncertain or a different generation is selected.
mdbr_require_v24() {
  local op="$1" profile_rc=0
  mdb_operator_group_is_confident || profile_rc=$?
  if [[ "$profile_rc" -eq 2 ]]; then
    mdbt_fail "$op" "database operator profile could not be verified" \
      '{"stage":"capability"}' 1 INTERNAL_ERROR
  fi
  if [[ "$profile_rc" -ne 0 ]] || ! mdb_is_legacy_operator; then
    mdbt_fail "$op" "cross-cluster replication is unavailable for this database" \
      '{"stage":"capability"}' 2 OPERATION_UNAVAILABLE
  fi
}

# --- Peer address ------------------------------------------------------------

# mdbr_peer_host [namespace]
# The mesh Service FQDN this cluster uses to reach the primary. Derived from the
# namespace alone — there is no per-site catalog to keep in sync.
mdbr_peer_host() {
  local ns="${1:-$DB_NAMESPACE}"
  printf '%s%s.%s.svc.cluster.local' "$ns" "$MDBR_PEER_SUFFIX" "$ns"
}

# mdbr_service_account_name <projected-token-file>
# Resolve this workload's ServiceAccount name from the projected JWT. Used to
# mint a TokenRequest for peer AQSH auth; the projected volume token itself is
# audience-bound to the local apiserver and often fails peer TokenReview.
mdbr_service_account_name() {
  local token_file="${1:-/var/run/secrets/kubernetes.io/serviceaccount/token}"
  local token payload padded name
  [[ -r "$token_file" ]] || return 1
  token="$(<"$token_file")"
  [[ -n "$token" ]] || return 1
  payload="${token#*.}"
  payload="${payload%%.*}"
  [[ -n "$payload" ]] || return 1
  padded="$payload$(printf '%*s' $(( (4 - ${#payload} % 4) % 4 )) '' | tr ' ' '=')"
  name="$(printf '%s' "$padded" | tr '_-' '/+' | base64 -d 2>/dev/null     | jq -r '."kubernetes.io".serviceaccount.name // empty' 2>/dev/null)" || return 1
  [[ -n "$name" ]] || return 1
  printf '%s' "$name"
}

# mdbr_read_peer_token <projected-token-file>
# Peer authentication is workload identity, not caller input. Prefer a freshly
# minted TokenRequest token: projected volume tokens are audience-bound to the
# local apiserver, while peer AQSH auth goes through federated TokenReview and
# needs a reviewable bearer (the same shape `kubectl create token` produces).
# Fall back to the projected file only when minting is unavailable. Fail closed
# when neither yields a non-empty token.
mdbr_read_peer_token() {
  local token_file="$1" token sa_ns sa_name
  local ttl="${MDBR_PEER_TOKEN_TTL:-30m}"
  local sa_configured=0

  sa_ns="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || true)"
  # Prefer deploy-time SA name; JWT parse is only a fallback when unset.
  sa_name="${MDBR_PEER_TOKEN_SA:-}"
  if [[ -n "$sa_name" ]]; then
    sa_configured=1
  else
    sa_name="$(mdbr_service_account_name "$token_file" 2>/dev/null || true)"
  fi
  if [[ -n "$sa_ns" && -n "$sa_name" ]]; then
    # Use _kubectl_global: task K8S_NAMESPACE is the MariaDB namespace, but the
    # ServiceAccount lives in the AQSH release namespace (e.g. db-ops).
    # Omit --audience so the minted bearer matches `kubectl create token`
    # clients that already pass federated TokenReview in this suite.
    token="$(_kubectl_global -n "$sa_ns" create token "$sa_name" --duration="$ttl" 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
      printf '%s' "$token"
      return 0
    fi
    # Deploy-time SA means TokenRequest is required. Falling back to the
    # projected volume token would only produce PEER_AUTH_FAILED later: that
    # bearer is audience-bound to the local apiserver and fails federated
    # TokenReview on the peer.
    if [[ "$sa_configured" -eq 1 ]]; then
      return 1
    fi
  fi

  [[ -r "$token_file" ]] || return 1
  token="$(<"$token_file")"
  [[ -n "$token" ]] || return 1
  printf '%s' "$token"
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

# mdbr_configure_server_ids <password> <pod>...
# v0.0.24 has no CR field for a cross-cluster server-id range. Set every local
# member to the deployment's disjoint range so both the current primary and a
# future local failover member are valid MariaDB replication participants.
# The setting is dynamic; callers invoke this before assessment and again after
# an in-place restore, whose physical data may carry the peer's old value.
#
# rc: 0 configured and verified, 1 SQL failure, 2 missing/invalid policy.
mdbr_configure_server_ids() {
  local password="$1"
  shift
  local pod ordinal server_id observed

  [[ "$MDBR_SERVER_ID_START_INDEX" =~ ^[1-9][0-9]*$ ]] || return 2
  (( $# > 0 )) || return 2

  for pod in "$@"; do
    [[ "$pod" =~ -([0-9]+)$ ]] || return 2
    ordinal="${BASH_REMATCH[1]}"
    server_id=$((MDBR_SERVER_ID_START_INDEX + ordinal))
    (( server_id > 0 && server_id <= 4294967295 )) || return 2
    mariadb_sql "$pod" "$password" "SET GLOBAL server_id = ${server_id}" \
      >/dev/null || return 1
    observed="$(mariadb_sql "$pod" "$password" \
      'SELECT @@GLOBAL.server_id')" || return 1
    [[ "$observed" == "$server_id" ]] || return 1
  done
}

# --- cross-cluster replica control ------------------------------------------
#
# The v24 operator manages the MariaDB instance and its local replicas, but it
# does not know about a primary in another cluster.  The cross-cluster link is
# therefore configured on this cluster's current primary with MariaDB's native
# replication statements.  Keep all SQL that mutates that link here so attach,
# restore-in-place, status, and detach share one v24-compatible contract.

# mdbr_replica_status <pod> <password>
# Emit a redacted view of the cross-cluster (non-operator) replication
# connection on this pod. The mariadb-operator local link is ignored so a local
# replica topology never looks like a peer attach / source mismatch.
# Row boundaries are Slave_IO_Running lines so parsing works with or without
# the "**** N. row ****" banner from mariadb -E.
mdbr_replica_status() {
  local pod="$1" password="$2" out
  local filtered count

  out="$(mariadb_sql_vertical "$pod" "$password" 'SHOW ALL SLAVES STATUS')" || return 1
  filtered="$(mdbr_filter_peer_slave_status "$out")" || return 1
  count="$(jq -r 'length' <<<"$filtered")"

  if [[ "$count" == "0" ]]; then
    jq -nc '{configured: false, running: false, ioRunning: false,
      sqlRunning: false, secondsBehind: null, sourceHost: null,
      sourcePort: null, connectionName: null, error: null}'
    return 0
  fi

  if [[ "$count" != "1" ]]; then
    jq -nc --argjson rows "$count" '{configured: true, running: false,
      ioRunning: null, sqlRunning: null, secondsBehind: null,
      sourceHost: null, sourcePort: null, connectionName: null,
      error: "MULTIPLE_REPLICATION_CONNECTIONS", rows: $rows}'
    return 0
  fi

  jq -c '.[0]' <<<"$filtered"
}

# mdbr_filter_peer_slave_status <show_all_slaves_vertical>
# Parse SHOW ALL SLAVES STATUS (-E) into JSON objects and drop operator-local
# rows (connectionName=mariadb-operator or Master_Host under *.mariadb-internal.*).
# stdout: JSON array.
mdbr_filter_peer_slave_status() {
  local out="$1"
  local parsed
  local _op_name="${MDBR_OPERATOR_CONNECTION_NAME:-mariadb-operator}"

  parsed="$(awk -F': *' -v op="$_op_name" '
    function json_str(s) {
      gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\""
    }
    function flush() {
      if (!have) return
      if (conn == op) return
      if (host ~ /\.mariadb-internal\./) return
      io_json = (io == "Yes") ? "true" : "false"
      sql_json = (sql == "Yes") ? "true" : "false"
      lag_json = (lag == "" || lag == "NULL") ? "null" : lag
      if (lag_json != "null" && lag_json !~ /^[0-9]+$/) lag_json = "null"
      port_json = (port == "" || port == "NULL") ? "null" : port
      if (port_json != "null" && port_json !~ /^[0-9]+$/) port_json = "null"
      host_json = (host == "" ? "null" : json_str(host))
      conn_json = (conn == "" ? "null" : json_str(conn))
      gtid_json = (gtid == "" ? "null" : json_str(gtid))
      err = io_err; if (err == "") err = sql_err
      err_json = (err == "" ? "null" : json_str(err))
      printf "{\"configured\":true,\"running\":%s,\"ioRunning\":%s,\"sqlRunning\":%s,\"secondsBehind\":%s,\"sourceHost\":%s,\"sourcePort\":%s,\"connectionName\":%s,\"usingGtid\":%s,\"error\":%s}\n",
        ((io == "Yes" && sql == "Yes") ? "true" : "false"),
        io_json, sql_json, lag_json, host_json, port_json, conn_json, gtid_json, err_json
    }
    $1 ~ /^[* ]*Slave_IO_Running$/ {
      flush()
      have=1; io=$2; sql=""; lag=""; host=""; port=""; conn=""; gtid=""; io_err=""; sql_err=""
      next
    }
    !have { next }
    $1 ~ /^[* ]*Slave_SQL_Running$/ { sql=$2; next }
    $1 ~ /^[* ]*Seconds_Behind_Master$/ { lag=$2; next }
    $1 ~ /^[* ]*Master_Host$/ { host=$2; next }
    $1 ~ /^[* ]*Master_Port$/ { port=$2; next }
    $1 ~ /^[* ]*Connection_name$/ { conn=$2; next }
    $1 ~ /^[* ]*Using_Gtid$/ { gtid=$2; next }
    $1 ~ /^[* ]*Last_IO_Error$/ { io_err=$2; next }
    $1 ~ /^[* ]*Last_SQL_Error$/ { sql_err=$2; next }
    END { flush() }
  ' <<<"$out")" || return 1

  if [[ -z "$parsed" ]]; then
    printf '[]'
    return 0
  fi

  jq -sc '.' <<<"$parsed"
}

# mdbr_replica_raw_slave_rows <pod> <password>
# Count Slave_IO_Running rows in SHOW ALL SLAVES STATUS (includes operator).
# Used before wire RESET: peer status filters operator out, so configured=false
# can hide a FILE-repo conflict with an existing named local link.
mdbr_replica_raw_slave_rows() {
  local pod="$1" password="$2" out
  out="$(mariadb_sql_vertical "$pod" "$password" 'SHOW ALL SLAVES STATUS')" || return 1
  awk -F': *' '$1 ~ /^[* ]*Slave_IO_Running$/ { n++ } END { print n+0 }' <<<"$out"
}

# Populated on configure failure for attach.sh to embed in LINK_STATUS.
export MDBR_REPLICA_SQL_ERR=""

# mdbr_replica_configure <pod> <password> <host> <port> <gtid_mode>
# Wire the default (unnamed) cross-cluster source on the writable primary.
#
# CI (75696bc / 34182885346): configure still failed with configured=false after
# rebuild. Peer status ignores mariadb-operator, so a residual local link leaves
# configured=false, skips STOP/RESET, then CHANGE MASTER TO fights FILE
# master_info_repository / existing slave metadata and never creates a peer link.
# Attach only calls this after read_only=0, so clearing ALL slaves on this pod is
# safe (the primary must not keep a local operator slave). Skip STOP/RESET when
# raw row count is 0 — ER_SLAVE_NOT_CONFIGURED (1200) aborts the multi-statement.
mdbr_replica_configure() {
  local pod="$1" password="$2" host="$3" port="$4" gtid_mode="$5"
  local password_sql raw_rows=0 sql_err=""

  MDBR_REPLICA_SQL_ERR=""
  [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  [[ "$port" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "$gtid_mode" == "current_pos" || "$gtid_mode" == "slave_pos" ]] || return 2
  # CHANGE MASTER only accepts a string literal for MASTER_PASSWORD — not 0x…
  # hex and not UNHEX(...) (both ERROR 1064 on MariaDB 10.6 in CI). Escape
  # single quotes the SQL way; never log this value.
  password_sql="$(printf '%s' "$password" | sed "s/'/''/g")"

  raw_rows="$(mdbr_replica_raw_slave_rows "$pod" "$password")" || return 1
  if (( raw_rows > 0 )); then
    # Writable primary only (attach read_only gate). Clear operator + junk so
    # default CHANGE MASTER can use FILE or TABLE cleanly.
    if ! sql_err="$(mariadb_exec "$pod" mariadb -u root -p"$password" -N -B -e \
      'STOP ALL SLAVES; RESET SLAVE ALL;' 2>&1 >/dev/null)"; then
      MDBR_REPLICA_SQL_ERR="${sql_err//$'\n'/; }"
      return 1
    fi
  fi

  if ! sql_err="$(mariadb_exec "$pod" mariadb -u root -p"$password" -N -B -e "
    CHANGE MASTER TO
      MASTER_HOST='${host}',
      MASTER_PORT=${port},
      MASTER_USER='root',
      MASTER_PASSWORD='${password_sql}',
      MASTER_USE_GTID=${gtid_mode};
    START SLAVE;
  " 2>&1 >/dev/null)"; then
    MDBR_REPLICA_SQL_ERR="${sql_err//$'\n'/; }"
    return 1
  fi
  return 0
}

# mdbr_replica_stop_reset <pod> <password>
# Remove the default cross-cluster connection. Call only when peer status said
# configured (operator-local rows are filtered out first in detach).
mdbr_replica_stop_reset() {
  local pod="$1" password="$2"
  mariadb_sql "$pod" "$password" 'STOP SLAVE; RESET SLAVE ALL;' >/dev/null
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
# Binlog Dump[ GTID] / Slave_* / Daemon set — including the Slave_worker
# threads parallel replication creates when slave_parallel_threads > 0, which
# would otherwise be counted as external and block attach outright), and the
# platform accounts listed in
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
       AND COMMAND NOT IN ('Binlog Dump','Binlog Dump GTID','Slave_IO','Slave_SQL','Slave_worker','Slave_SQL_worker','Daemon') \
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
# MDBR_ASSESS_ERROR is set for callers that invoke this directly. Callers that
# capture stdout with $( ) run it in a subshell where that assignment is lost,
# so every failure ALSO emits {"error": "<reason>"} on stdout — see
# mdbr_assess_reason.
# shellcheck disable=SC2034
MDBR_ASSESS_ERROR=""

# mdbr_assess_reason <captured_stdout>
# The stable reason code for a failed assessment, read from whatever mdbr_assess
# printed. Falls back to INTERNAL_ERROR rather than inventing a specific cause.
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

mdbr_assess() {
  local pod="$1" password="$2" peer_host="$3" already_linked="${4:-false}"
  local standby_slave_pos standby_binlog_pos standby_server_id
  local primary_pos primary_server_id primary_earliest_file primary_earliest_pos

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
  # mariadb_sql/mdbr_remote_sql succeed with empty output when a query returns
  # no row. An unknown server_id cannot be compared, and treating it as "the
  # ids differ" would skip the hard stop while still reporting
  # server_ids_distinct:false — a verdict contradicting its own evidence.
  if [[ -z "$standby_server_id" || -z "$primary_server_id" ]]; then
    _mdbr_assess_fail "DATABASE_NOT_READY"; return 1
  fi
  if [[ -z "$primary_pos" ]]; then
    # A primary with an empty binlog position has binary logging off, so no
    # standby can ever attach to it. That is a configuration fault, not a
    # rebuildable state.
    _mdbr_assess_fail "PRIMARY_BINLOG_UNAVAILABLE"; return 1
  fi

  # Oldest binlog the primary still keeps, and the GTID position at its head:
  # everything before this point has been purged and is unrecoverable from the
  # primary. Position 4 is the first event after the binlog file header.
  # Capture first, THEN parse: piping straight into awk replaces the remote
  # query's exit status, making an unreachable peer indistinguishable from a
  # primary with binary logging off. Those two reason codes lead an operator to
  # completely different actions.
  local primary_binlogs
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
  if [[ "$standby_server_id" == "$primary_server_id" ]]; then
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
