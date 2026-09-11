#!/usr/bin/env bash
# =============================================================================
# lib/mariadb-replication-link.sh
# Cross-cluster replication link: assessment helpers.
#
# Context: both databases already exist. cluster-a runs the primary, cluster-b
# runs a standalone standby that must be attached to it. This lib answers the
# one question
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
# SQL link mutations live here; assessment lives in mariadb-replication-assessment.sh.
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
# shellcheck source=aqsh-tasks/lib/mariadb-peer-transport.sh
source "${LIB_DIR}/mariadb-peer-transport.sh"
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

# Own the SQL channel by name. This prevents unqualified replication commands
# from accidentally targeting an operator-created channel restored from a
# physical backup.
MDBR_CONNECTION_NAME="aqsh-cross-cluster"

MDBR_PEER_TOKEN_SA="${REPL_PEER_TOKEN_SA_DEFAULT:-}"

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

# v0.0.24's local-replication controller owns every replica channel: each
# reconcile stops/resets all channels and restores server_id=10+ordinal. It
# therefore cannot safely share a MariaDB instance with this SQL-managed
# cross-cluster channel. The standby must be a one-Pod CR with operator local
# replication disabled; its distinct server_id belongs in persistent myCnf.
mdbr_is_standalone() {
  local cr_json="$1" replicas replication_enabled
  replicas="$(jq -r '.spec.replicas // 1' <<<"$cr_json")"
  replication_enabled="$(jq -r '.spec.replication.enabled // false' <<<"$cr_json")"
  [[ "$replicas" == "1" && "$replication_enabled" != "true" ]]
}

mdbr_primary_pod() {
  local cr_json="$1" primary replicas
  primary="$(jq -r '.status.currentPrimary // empty' <<<"$cr_json")"
  if [[ -n "$primary" ]]; then
    printf '%s' "$primary"
    return 0
  fi
  replicas="$(jq -r '.spec.replicas // 1' <<<"$cr_json")"
  [[ "$replicas" == "1" ]] || return 1
  mariadb_pod_name 0
}

# --- Peer address ------------------------------------------------------------

# mdbr_peer_host [namespace]
# The same-namespace mesh Service this cluster uses to reach the primary. Derived from the
# namespace alone — there is no per-site catalog to keep in sync.
mdbr_peer_host() {
  local ns="${1:-$DB_NAMESPACE}"
  printf '%s%s' "$ns" "$MDBR_PEER_SUFFIX"
}

# Accept the exact historical FQDN without treating other namespaces or DNS
# aliases as the same source. Preserve the actual Master_Host in status output.
mdbr_peer_host_matches() {
  local host="${1:-}" ns="${2:?namespace is required}" peer
  peer="$(mdbr_peer_host "$ns")"
  [[ "$host" == "$peer" || "$host" == "$peer.$ns.svc.cluster.local" ]]
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

# --- cross-cluster replica control ------------------------------------------
#
# The v24 operator manages the standalone MariaDB instance but does not know
# about a primary in another cluster. The cross-cluster link is configured on
# that Pod with MariaDB's native replication statements. Keep all SQL that
# mutates that link here so attach,
# restore-in-place, status, and detach share one v24-compatible contract.

# mdbr_replica_status <pod> <password>
# Emit a redacted, stable view of the current primary's first replication
# connection.  A v24 standby has one cross-cluster connection; multiple rows are
# reported as ambiguous instead of silently selecting an arbitrary source.
mdbr_replica_status() {
  local pod="$1" password="$2" out row_count io sql lag host port connection_name
  local io_error sql_error using_gtid configured

  out="$(mariadb_sql_vertical "$pod" "$password" 'SHOW ALL SLAVES STATUS')" || return 1
  row_count="$(awk -F': *' '$1 ~ "^[* ]*Slave_IO_Running$" {n++} END {print n+0}' <<<"$out")"

  if [[ "$row_count" == "0" ]]; then
    jq -nc '{configured: false, running: false, ioRunning: false,
      sqlRunning: false, secondsBehind: null, sourceHost: null,
      sourcePort: null, connectionName: null, error: null}'
    return 0
  fi

  if [[ "$row_count" != "1" ]]; then
    jq -nc --argjson rows "$row_count" '{configured: true, running: false,
      ioRunning: null, sqlRunning: null, secondsBehind: null,
      sourceHost: null, sourcePort: null, connectionName: null,
      error: "MULTIPLE_REPLICATION_CONNECTIONS", rows: $rows}'
    return 0
  fi

  io="$(mariadb_status_field Slave_IO_Running <<<"$out")"
  sql="$(mariadb_status_field Slave_SQL_Running <<<"$out")"
  lag="$(mariadb_status_field Seconds_Behind_Master <<<"$out")"
  host="$(mariadb_status_field Master_Host <<<"$out")"
  port="$(mariadb_status_field Master_Port <<<"$out")"
  connection_name="$(mariadb_status_field Connection_name <<<"$out")"
  io_error="$(mariadb_status_field Last_IO_Error <<<"$out")"
  sql_error="$(mariadb_status_field Last_SQL_Error <<<"$out")"
  using_gtid="$(mariadb_status_field Using_Gtid <<<"$out")"

  [[ "$lag" == "NULL" || -z "$lag" ]] && lag=""
  [[ -n "$io_error" ]] || io_error="$sql_error"
  [[ -n "$io_error" ]] || io_error=""
  [[ "$io" == "Yes" ]] && io=true || io=false
  [[ "$sql" == "Yes" ]] && sql=true || sql=false
  configured=true

  jq -nc \
    --arg host "$host" --arg port "$port" --arg lag "$lag" \
    --arg connection "$connection_name" --arg usingGtid "$using_gtid" \
    --arg error "$io_error" \
    --argjson ioRunning "$io" --argjson sqlRunning "$sql" \
    --argjson configured "$configured" \
    '{
      configured: $configured,
      running: ($ioRunning and $sqlRunning),
      ioRunning: $ioRunning,
      sqlRunning: $sqlRunning,
      secondsBehind: (if $lag == "" then null else ($lag | tonumber? // null) end),
      sourceHost: (if $host == "" then null else $host end),
      sourcePort: (if $port == "" then null else ($port | tonumber? // null) end),
      connectionName: (if $connection == "" then null else $connection end),
      usingGtid: (if $usingGtid == "" then null else $usingGtid end),
      error: (if $error == "" then null else $error end)
    }'
}

# Read by attach after a failed SQL command; never contains backend text.
# shellcheck disable=SC2034
MDBR_REPLICA_SQL_ERR=""

# mdbr_replica_configure <pod> <password> <host> <port> <gtid_mode> [old_connection]
# Configure one cross-cluster source and start it.  The remote root password is
# intentionally the same platform-managed credential already used by
# mdbr_remote_sql; it never appears in the task result or logs.  A session-local SQL mode and quote doubling preserve arbitrary secret values.
# shellcheck disable=SC2034
mdbr_replica_configure() {
  local pod="$1" password="$2" host="$3" port="$4" gtid_mode="$5"
  local old_connection="${6:-}" password_sql sql_error error_code
  MDBR_REPLICA_SQL_ERR=""

  [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  [[ "$port" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "$gtid_mode" == "current_pos" || "$gtid_mode" == "slave_pos" ]] || return 2
  [[ "$MDBR_CONNECTION_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  [[ -z "$old_connection" || "$old_connection" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  [[ -n "$password" ]] || return 2

  # CHANGE MASTER accepts a quoted string, not an arbitrary SQL expression.
  # Enable NO_BACKSLASH_ESCAPES for this client session and use standard SQL
  # quote doubling, so both apostrophes and backslashes retain their exact
  # secret value without ever logging the plaintext credential.
  password_sql="${password//\'/\'\'}"

  if [[ -n "$old_connection" ]]; then
    mdbr_replica_stop_reset "$pod" "$password" "$old_connection" || return 1
  fi

  if ! sql_error="$(mariadb_exec "$pod" mariadb -u root -p"$password" -N -B -e "
    SET SESSION sql_mode = IF(
      FIND_IN_SET('NO_BACKSLASH_ESCAPES', @@SESSION.sql_mode),
      @@SESSION.sql_mode,
      CONCAT_WS(',', @@SESSION.sql_mode, 'NO_BACKSLASH_ESCAPES'));
    CHANGE MASTER '${MDBR_CONNECTION_NAME}' TO
      MASTER_HOST='${host}',
      MASTER_PORT=${port},
      MASTER_USER='root',
      MASTER_PASSWORD='${password_sql}',
      MASTER_USE_GTID=${gtid_mode};
    START SLAVE '${MDBR_CONNECTION_NAME}';
  " 2>&1 >/dev/null)"; then
    # MariaDB error text may quote the SQL (including MASTER_PASSWORD). Expose
    # only the numeric server code, retaining useful diagnostics without secrets.
    error_code="$(sed -nE 's/^ERROR ([0-9]+).*/\1/p' <<<"$sql_error" | head -n1)"
    MDBR_REPLICA_SQL_ERR="SQL_EXECUTION_FAILED"
    [[ -z "$error_code" ]] || MDBR_REPLICA_SQL_ERR="SQL_ERROR_${error_code}"
    return 1
  fi
  return 0
}

# mdbr_replica_stop_reset <pod> <password> [connection_name]
# Stop and remove only the cross-cluster source configuration.  The MariaDB
# instance, its data, and the v24 operator's local replication remain intact.
mdbr_replica_stop_reset() {
  local pod="$1" password="$2" connection_name="${3:-}"
  if [[ -n "$connection_name" ]]; then
    [[ "$connection_name" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
    mariadb_sql "$pod" "$password" \
      "STOP SLAVE '${connection_name}'; RESET SLAVE '${connection_name}' ALL;" >/dev/null
    return
  fi
  mariadb_sql "$pod" "$password" 'STOP SLAVE; RESET SLAVE ALL;' >/dev/null
}

# mdbr_replica_reset_restored_source <pod> <password>
# A physical backup taken from an operator-managed replica contains that
# replica's named source metadata. After restoring it onto the standby primary,
# the connection is stale backup state, not a live local-operator contract.
# Remove the single restored connection before creating the cross-cluster link;
# fail closed if the restored datadir contains several connections.
mdbr_replica_reset_restored_source() {
  local pod="$1" password="$2" status connection_name verified
  status="$(mdbr_replica_status "$pod" "$password")" || return 1
  [[ "$(jq -r '.error // empty' <<<"$status")" != "MULTIPLE_REPLICATION_CONNECTIONS" ]] || return 2
  [[ "$(jq -r '.configured // false' <<<"$status")" == "true" ]] || return 0

  connection_name="$(jq -r '.connectionName // empty' <<<"$status")"
  mdbr_replica_stop_reset "$pod" "$password" "$connection_name" || return 1

  verified="$(mdbr_replica_status "$pod" "$password")" || return 1
  [[ "$(jq -r '.configured // false' <<<"$verified")" == "false" ]]
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

# Load the read-only attach-versus-rebuild decision after the SQL and GTID
# helpers above are available.
# shellcheck source=aqsh-tasks/lib/mariadb-replication-assessment.sh
source "${LIB_DIR}/mariadb-replication-assessment.sh"
