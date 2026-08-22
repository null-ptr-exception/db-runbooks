#!/usr/bin/env bats
# =============================================================================
# Unit tests for lib/mariadb-replication-link.sh
#
# The attach/rebuild assessment is the whole point of replication/attach: a
# wrong "attach" silently diverges two databases, and a wrong "rebuild"
# destroys a standby that was fine. Both directions are pinned here, with the
# SQL layer mocked so the decision matrix is tested on its own.
# =============================================================================

setup() {
  LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../../../aqsh-tasks/lib" && pwd)"
  export LIB_DIR
  # shellcheck disable=SC1091
  source "$LIB_DIR/mariadb-replication-link.sh"
}

# --- mock helpers ------------------------------------------------------------
# Replace the two SQL entry points with table-driven fakes. Every scenario sets
# the four values the assessment reads; STANDBY_* are local, PRIMARY_* remote.

_install_mocks() {
  mariadb_sql() {
    case "$3" in
      *gtid_slave_pos*)  printf '%s\n' "$STANDBY_SLAVE_POS" ;;
      *gtid_binlog_pos*) printf '%s\n' "$STANDBY_BINLOG_POS" ;;
      *server_id*)       printf '%s\n' "$STANDBY_SERVER_ID" ;;
      *) return 1 ;;
    esac
  }
  mdbr_remote_sql() {
    [[ "${PEER_REACHABLE:-true}" == "true" ]] || return 1
    case "$4" in
      *gtid_binlog_pos*)   printf '%s\n' "$PRIMARY_POS" ;;
      # Distinct from the standby's id unless a scenario says otherwise: equal
      # ids are a hard stop, so they must not be the accidental default.
      *server_id*)         printf '%s\n' "${PRIMARY_SERVER_ID-101}" ;;
      *SHOW\ BINARY\ LOGS*) printf '%s\n' "${PRIMARY_BINLOG_FILE:-mariadb-bin.000001} 1024" ;;
      *BINLOG_GTID_POS*)   printf '%s\n' "$PRIMARY_EARLIEST_POS" ;;
      *) return 1 ;;
    esac
  }
}

_assess() {
  _install_mocks
  mdbr_assess pod-0 secret peer-host
}

# Same scenario, but for a standby already carrying the expected v24 SQL link.
_assess_linked() {
  _install_mocks
  mdbr_assess pod-0 secret peer-host true
}

# --- v24 capability gate ----------------------------------------------------

@test "v24 capability gate accepts a confidently detected legacy operator" {
  mdb_operator_group_is_confident() { return 0; }
  mdb_is_legacy_operator() { return 0; }

  run mdbr_require_v24 replication/attach
  [ "$status" -eq 0 ]
}

@test "v24 capability gate rejects a current-generation operator" {
  MDBT_RESULT_FILE="$BATS_TEST_TMPDIR/result.json"
  mdb_operator_group_is_confident() { return 0; }
  mdb_is_legacy_operator() { return 1; }

  run mdbr_require_v24 replication/attach
  [ "$status" -eq 2 ]
  [ "$(jq -r '.reason' "$MDBT_RESULT_FILE")" = "OPERATION_UNAVAILABLE" ]
}

@test "v24 capability gate fails closed when discovery is unavailable" {
  MDBT_RESULT_FILE="$BATS_TEST_TMPDIR/result.json"
  mdb_operator_group_is_confident() { return 2; }

  run mdbr_require_v24 replication/attach
  [ "$status" -eq 1 ]
  [ "$(jq -r '.reason' "$MDBT_RESULT_FILE")" = "INTERNAL_ERROR" ]
}

@test "peer token is read from a non-empty projected service-account file" {
  local token_file="$BATS_TEST_TMPDIR/token"
  printf 'federated-service-account-token' > "$token_file"

  run mdbr_read_peer_token "$token_file"
  [ "$status" -eq 0 ]
  [ "$output" = "federated-service-account-token" ]
}

@test "peer token fails closed when its projection is missing or empty" {
  local token_file="$BATS_TEST_TMPDIR/token"
  : > "$token_file"

  run mdbr_read_peer_token "$token_file"
  [ "$status" -ne 0 ]
  run mdbr_read_peer_token "$BATS_TEST_TMPDIR/missing-token"
  [ "$status" -ne 0 ]
}

# --- peer address ------------------------------------------------------------

@test "peer host is derived from the namespace alone" {
  run mdbr_peer_host "mariadb-1"
  [ "$status" -eq 0 ]
  [ "$output" = "mariadb-1-rw.mariadb-1.svc.cluster.local" ]
}

@test "peer service suffix is deploy-time configurable" {
  MDBR_PEER_SUFFIX="-write"
  run mdbr_peer_host "db-ops"
  [ "$output" = "db-ops-write.db-ops.svc.cluster.local" ]
}

# --- GTID coverage -----------------------------------------------------------

@test "coverage compares per domain, not per domain+server" {
  # The primary's server_id changes on every switch-primary. Keying on
  # domain+server would read this healthy standby as diverged and destroy it.
  run mdbr_gtid_domain_covers "1-101-500" "1-102-600"
  [ "$status" -eq 0 ]
}

@test "coverage rejects a standby ahead of the primary" {
  run mdbr_gtid_domain_covers "1-101-700" "1-102-600"
  [ "$status" -eq 1 ]
}

@test "coverage requires every domain present" {
  run mdbr_gtid_domain_covers "0-1-10,2-5-3" "0-1-20,1-101-600"
  [ "$status" -eq 1 ]
}

@test "empty requirement is covered by anything" {
  run mdbr_gtid_domain_covers "" "1-101-500"
  [ "$status" -eq 0 ]
}

@test "nothing covers a non-empty requirement when actual is empty" {
  run mdbr_gtid_domain_covers "1-101-500" ""
  [ "$status" -eq 1 ]
}

@test "server detection ignores the domain and sequence components" {
  run mdbr_gtid_has_server "1-101-500,2-201-7" 201
  [ "$status" -eq 0 ]
  run mdbr_gtid_has_server "1-101-500" 201
  [ "$status" -eq 1 ]
}

# --- assessment: attach ------------------------------------------------------

@test "standby behind the primary and within retained binlog attaches" {
  STANDBY_SLAVE_POS="1-101-500" STANDBY_BINLOG_POS="" STANDBY_SERVER_ID=201 \
  PRIMARY_POS="1-101-600" PRIMARY_EARLIEST_POS="1-101-100" \
  run _assess
  [ "$status" -eq 0 ]
  [ "$(jq -r '.action' <<<"$output")" = "attach" ]
  [ "$(jq -r '.reason' <<<"$output")" = "LINK_RESUMABLE" ]
}

@test "standby exactly caught up attaches" {
  STANDBY_SLAVE_POS="1-101-600" STANDBY_BINLOG_POS="" STANDBY_SERVER_ID=201 \
  PRIMARY_POS="1-101-600" PRIMARY_EARLIEST_POS="1-101-100" \
  run _assess
  [ "$(jq -r '.action' <<<"$output")" = "attach" ]
}

@test "a primary that has switched its own primary still attaches" {
  STANDBY_SLAVE_POS="1-101-500" STANDBY_BINLOG_POS="" STANDBY_SERVER_ID=201 \
  PRIMARY_POS="1-102-600" PRIMARY_EARLIEST_POS="1-101-100" \
  run _assess
  [ "$(jq -r '.action' <<<"$output")" = "attach" ]
}

@test "a primary that has never purged a binlog attaches" {
  # BINLOG_GTID_POS returns NULL when the position predates GTID tracking.
  STANDBY_SLAVE_POS="1-101-500" STANDBY_BINLOG_POS="" STANDBY_SERVER_ID=201 \
  PRIMARY_POS="1-101-600" PRIMARY_EARLIEST_POS="NULL" \
  run _assess
  [ "$(jq -r '.action' <<<"$output")" = "attach" ]
}

# --- assessment: rebuild -----------------------------------------------------

@test "a standby with no replication history needs a rebuild" {
  STANDBY_SLAVE_POS="" STANDBY_BINLOG_POS="" STANDBY_SERVER_ID=201 \
  PRIMARY_POS="1-101-600" PRIMARY_EARLIEST_POS="1-101-100" \
  run _assess
  [ "$(jq -r '.action' <<<"$output")" = "rebuild" ]
  [ "$(jq -r '.reason' <<<"$output")" = "NO_REPLICATION_HISTORY" ]
  [ "$(jq -r '.checks.has_replication_history' <<<"$output")" = "false" ]
}

@test "a standby ahead of the primary needs a rebuild" {
  STANDBY_SLAVE_POS="1-101-700" STANDBY_BINLOG_POS="" STANDBY_SERVER_ID=201 \
  PRIMARY_POS="1-101-600" PRIMARY_EARLIEST_POS="1-101-100" \
  run _assess
  [ "$(jq -r '.action' <<<"$output")" = "rebuild" ]
  [ "$(jq -r '.reason' <<<"$output")" = "GTID_DIVERGED" ]
}

@test "a standby that only ever wrote its own history has no resume point" {
  # Regression: this used to fall back to the standby's binlog position as a
  # resume point, which compared two unrelated histories that merely shared a
  # domain — precisely the case a fresh, never-attached database presents.
  STANDBY_SLAVE_POS="" STANDBY_BINLOG_POS="0-10-4" STANDBY_SERVER_ID=10 \
  PRIMARY_POS="0-101-100" PRIMARY_EARLIEST_POS="0-101-1" \
  run _assess
  [ "$(jq -r '.action' <<<"$output")" = "rebuild" ]
  [ "$(jq -r '.reason' <<<"$output")" = "NO_REPLICATION_HISTORY" ]
}

@test "identical server ids are a hard stop, whatever the GTIDs say" {
  # Observed live: two clusters both defaulting to server_id 10 produce
  # positions like 0-10-100 and 0-10-4 that compare as "covered" while sharing
  # no history. MariaDB refuses the link outright (errno 1593), so this must be
  # decided before any GTID reasoning.
  STANDBY_SLAVE_POS="0-10-4" STANDBY_BINLOG_POS="0-10-4" STANDBY_SERVER_ID=10 \
  PRIMARY_SERVER_ID=10 PRIMARY_POS="0-10-100" PRIMARY_EARLIEST_POS="0-10-1" \
  run _assess
  [ "$(jq -r '.action' <<<"$output")" = "rebuild" ]
  [ "$(jq -r '.reason' <<<"$output")" = "SERVER_ID_CONFLICT" ]
  [ "$(jq -r '.checks.server_ids_distinct' <<<"$output")" = "false" ]
}

@test "distinct server ids let the assessment proceed to the GTID checks" {
  STANDBY_SLAVE_POS="0-101-500" STANDBY_BINLOG_POS="" STANDBY_SERVER_ID=201 \
  PRIMARY_SERVER_ID=101 PRIMARY_POS="0-101-600" PRIMARY_EARLIEST_POS="0-101-100" \
  run _assess
  [ "$(jq -r '.action' <<<"$output")" = "attach" ]
  [ "$(jq -r '.checks.server_ids_distinct' <<<"$output")" = "true" ]
}

@test "a standby carrying its own writes needs a rebuild even when seq numbers look covered" {
  # 1-201-501 vs primary 1-101-600: per-domain coverage says "covered", but the
  # standby wrote 501 itself. Sequence coverage cannot tell these apart, so the
  # local-write check must not defer to it.
  STANDBY_SLAVE_POS="1-101-500" STANDBY_BINLOG_POS="1-201-501" STANDBY_SERVER_ID=201 \
  PRIMARY_POS="1-101-600" PRIMARY_EARLIEST_POS="1-101-100" \
  run _assess
  [ "$(jq -r '.action' <<<"$output")" = "rebuild" ]
  [ "$(jq -r '.reason' <<<"$output")" = "STANDBY_HAS_LOCAL_WRITES" ]
  [ "$(jq -r '.checks.standby_has_local_writes' <<<"$output")" = "true" ]
}

@test "a standby whose starting point the primary has purged needs a rebuild" {
  STANDBY_SLAVE_POS="1-101-50" STANDBY_BINLOG_POS="" STANDBY_SERVER_ID=201 \
  PRIMARY_POS="1-101-600" PRIMARY_EARLIEST_POS="1-101-100" \
  run _assess
  [ "$(jq -r '.action' <<<"$output")" = "rebuild" ]
  [ "$(jq -r '.reason' <<<"$output")" = "PRIMARY_BINLOG_PURGED" ]
  [ "$(jq -r '.checks.primary_retains_binlog' <<<"$output")" = "false" ]
}

@test "replicated events keep their originating server id and are not local writes" {
  # The standby's binlog carries the primary's server_id for events it replayed.
  # Mistaking those for local writes would rebuild every healthy standby that
  # has log_slave_updates on.
  STANDBY_SLAVE_POS="1-101-500" STANDBY_BINLOG_POS="1-101-500" STANDBY_SERVER_ID=201 \
  PRIMARY_POS="1-101-600" PRIMARY_EARLIEST_POS="1-101-100" \
  run _assess
  [ "$(jq -r '.action' <<<"$output")" = "attach" ]
  [ "$(jq -r '.checks.standby_has_local_writes' <<<"$output")" = "false" ]
}

# --- assessment: errors ------------------------------------------------------

@test "an unreachable peer is an error, not a rebuild" {
  STANDBY_SLAVE_POS="1-101-500" STANDBY_BINLOG_POS="" STANDBY_SERVER_ID=201 \
  PEER_REACHABLE=false \
  run _assess
  [ "$status" -eq 1 ]
}

@test "unreachable peer reports a stable reason code" {
  STANDBY_SLAVE_POS="1-101-500"; STANDBY_BINLOG_POS=""; STANDBY_SERVER_ID=201
  PEER_REACHABLE=false
  _install_mocks
  # Called without `run`: MDBR_ASSESS_ERROR is set in the caller's shell, and
  # `run` would swallow it in a subshell.
  mdbr_assess pod-0 secret peer-host || true
  [ "$MDBR_ASSESS_ERROR" = "PEER_UNREACHABLE" ]
}

@test "a primary with binary logging off is an error, not a rebuild" {
  STANDBY_SLAVE_POS="1-101-500"; STANDBY_BINLOG_POS=""; STANDBY_SERVER_ID=201
  PRIMARY_POS=""; PRIMARY_EARLIEST_POS="1-101-100"
  _install_mocks
  mdbr_assess pod-0 secret peer-host || true
  [ "$MDBR_ASSESS_ERROR" = "PRIMARY_BINLOG_UNAVAILABLE" ]
}

@test "a standby whose own position cannot be read is an error" {
  _install_mocks
  mariadb_sql() { return 1; }
  mdbr_assess pod-0 secret peer-host || true
  [ "$MDBR_ASSESS_ERROR" = "DATABASE_NOT_READY" ]
}

# --- v24 SQL link ------------------------------------------------------------

@test "replica status reports an unconfigured v24 primary" {
  mariadb_sql_vertical() { printf ''; }

  run mdbr_replica_status pod-0 secret
  [ "$status" -eq 0 ]
  [ "$(jq -r '.configured' <<<"$output")" = "false" ]
  [ "$(jq -r '.running' <<<"$output")" = "false" ]
  [ "$(jq -r '.sourceHost' <<<"$output")" = "null" ]
}

@test "replica status parses one running SQL connection" {
  mariadb_sql_vertical() {
    printf '%s\n' \
      '*************************** 1. row ***************************' \
      '              Connection_name:' \
      '                  Master_Host: mariadb-1-rw.mariadb-1.svc.cluster.local' \
      '                  Master_Port: 3306' \
      '             Slave_IO_Running: Yes' \
      '            Slave_SQL_Running: Yes' \
      '        Seconds_Behind_Master: 4' \
      '                    Using_Gtid: Slave_Pos' \
      '                 Last_IO_Error:' \
      '                Last_SQL_Error:'
  }

  run mdbr_replica_status pod-0 secret
  [ "$status" -eq 0 ]
  [ "$(jq -r '.configured' <<<"$output")" = "true" ]
  [ "$(jq -r '.running' <<<"$output")" = "true" ]
  [ "$(jq -r '.sourceHost' <<<"$output")" = "mariadb-1-rw.mariadb-1.svc.cluster.local" ]
  [ "$(jq -r '.sourcePort' <<<"$output")" = "3306" ]
  [ "$(jq -r '.secondsBehind' <<<"$output")" = "4" ]
}

@test "replica status refuses to choose between multiple SQL connections" {
  mariadb_sql_vertical() {
    printf '%s\n' \
      'Slave_IO_Running: Yes' \
      'Slave_IO_Running: No'
  }

  run mdbr_replica_status pod-0 secret
  [ "$status" -eq 0 ]
  [ "$(jq -r '.configured' <<<"$output")" = "true" ]
  [ "$(jq -r '.running' <<<"$output")" = "false" ]
  [ "$(jq -r '.error' <<<"$output")" = "MULTIPLE_REPLICATION_CONNECTIONS" ]
  [ "$(jq -r '.rows' <<<"$output")" = "2" ]
}

@test "replica configure emits native MariaDB SQL without plaintext password" {
  local captured="$BATS_TEST_TMPDIR/change-master.sql"
  mariadb_sql() { printf '%s' "$3" > "$captured"; }

  mdbr_replica_configure pod-0 's3cr!t' peer.example 3306 current_pos

  grep -q 'RESET SLAVE ALL' "$captured"
  grep -q "MASTER_HOST='peer.example'" "$captured"
  grep -q 'MASTER_PASSWORD=0x733363722174' "$captured"
  grep -q 'MASTER_USE_GTID=current_pos' "$captured"
  grep -q 'START SLAVE' "$captured"
  ! grep -q 's3cr!t' "$captured"
}

@test "replica configure rejects an unsafe source host before SQL" {
  mariadb_sql() { return 99; }
  run mdbr_replica_configure pod-0 secret "peer';DROP TABLE x" 3306 slave_pos
  [ "$status" -eq 2 ]
}

# --- deploy-time config ------------------------------------------------------

@test "deploy-time config is loaded before the policy defaults are evaluated" {
  # Regression: the policy variables were evaluated at source time, but the task
  # scripts called mdbt_load_config AFTER sourcing — so every REPL_* setting in
  # a deployment's config file was silently ignored and the hardcoded fallbacks
  # won. It surfaced in the e2e as an unreachable peer, because the port stayed
  # 3306 instead of the configured one.
  local cfg="$BATS_TEST_TMPDIR/mariadb.env"
  cat > "$cfg" <<EOF
REPL_PEER_PORT_DEFAULT=30091
REPL_PEER_SERVICE_SUFFIX_DEFAULT=-write
REPL_MAX_EXTERNAL_CONNECTIONS_DEFAULT=5
REPL_SERVER_ID_START_INDEX_DEFAULT=100
EOF

  run bash -c "
    export MDBT_CONFIG_FILE='$cfg' LIB_DIR='$LIB_DIR'
    source '$LIB_DIR/mariadb-replication-link.sh'
    printf '%s|%s|%s|%s\n' \"\$MDBR_PEER_PORT\" \"\$MDBR_MAX_EXTERNAL_CONNECTIONS\" \"\$(mdbr_peer_host db-ops)\" \"\$MDBR_SERVER_ID_START_INDEX\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "30091|5|db-ops-write.db-ops.svc.cluster.local|100" ]
}

@test "an explicit environment override still beats the config file" {
  local cfg="$BATS_TEST_TMPDIR/mariadb.env"
  echo "REPL_PEER_PORT_DEFAULT=30091" > "$cfg"

  run bash -c "
    export MDBT_CONFIG_FILE='$cfg' LIB_DIR='$LIB_DIR' REPL_PEER_PORT_DEFAULT=13306
    source '$LIB_DIR/mariadb-replication-link.sh'
    printf '%s\n' \"\$MDBR_PEER_PORT\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "13306" ]
}

@test "v24 server-id policy maps each local ordinal to the configured range" {
  MDBR_SERVER_ID_START_INDEX=100
  local captured="$BATS_TEST_TMPDIR/server-id.sql"
  local current_server_id=""

  mariadb_sql() {
    case "$3" in
      "SET GLOBAL server_id = "*)
        printf '%s\n' "$3" >> "$captured"
        current_server_id="$(printf '%s' "$3" | sed 's/.*= //')"
        ;;
      'SELECT @@GLOBAL.server_id')
        printf '%s\n' "$current_server_id"
        ;;
      *) return 1 ;;
    esac
  }

  mdbr_configure_server_ids secret mariadb-0 mariadb-1
  [ "$(cat "$captured")" = $'SET GLOBAL server_id = 100\nSET GLOBAL server_id = 101' ]
}

@test "v24 server-id policy rejects an invalid range or pod name" {
  MDBR_SERVER_ID_START_INDEX=0
  run mdbr_configure_server_ids secret mariadb-0
  [ "$status" -eq 2 ]

  MDBR_SERVER_ID_START_INDEX=100
  run mdbr_configure_server_ids secret mariadb
  [ "$status" -eq 2 ]
}

@test "an already-linked standby is not condemned by its own post-restore writes" {
  # Observed live on a freshly seeded, healthy standby: slave=0-10-100 while
  # binlog=0-100-104, because the operator writes its own initialisation under
  # the standby's server_id. Applying the local-write check to a linked standby
  # would send every healthy one to a rebuild.
  STANDBY_SLAVE_POS="0-10-100" STANDBY_BINLOG_POS="0-100-104" STANDBY_SERVER_ID=100 \
  PRIMARY_SERVER_ID=10 PRIMARY_POS="0-10-100" PRIMARY_EARLIEST_POS="0-10-1" \
  run _assess_linked
  [ "$(jq -r '.action' <<<"$output")" = "attach" ]
  [ "$(jq -r '.checks.already_linked' <<<"$output")" = "true" ]
}

@test "the same standby before it was ever linked still needs a rebuild" {
  # Identical positions, but never wired up: those writes are its own
  # independent history, so attaching would diverge the two databases.
  STANDBY_SLAVE_POS="0-10-100" STANDBY_BINLOG_POS="0-100-104" STANDBY_SERVER_ID=100 \
  PRIMARY_SERVER_ID=10 PRIMARY_POS="0-10-100" PRIMARY_EARLIEST_POS="0-10-1" \
  run _assess
  [ "$(jq -r '.action' <<<"$output")" = "rebuild" ]
  [ "$(jq -r '.reason' <<<"$output")" = "STANDBY_HAS_LOCAL_WRITES" ]
}

# --- review fixes -------------------------------------------------------------

@test "parallel replication workers are not counted as external connections" {
  # slave_parallel_threads > 0 makes MariaDB report Slave_worker threads in the
  # process list. Counting them as external would block attach outright, since
  # the default tolerance is zero.
  local captured="$BATS_TEST_TMPDIR/query.sql"
  mariadb_sql() { printf '%s' "$3" > "$captured"; printf '\n'; }

  mdbr_external_connections pod-0 secret >/dev/null

  for cmd in "Binlog Dump" "Binlog Dump GTID" Slave_IO Slave_SQL Slave_worker Slave_SQL_worker Daemon; do
    grep -q "'${cmd}'" "$captured" || { echo "missing exclusion: ${cmd}" >&2; return 1; }
  done
}

@test "an unreadable server_id is an error, not 'the ids differ'" {
  # An empty result would otherwise skip the SERVER_ID_CONFLICT hard stop while
  # still reporting server_ids_distinct:false — a verdict contradicting itself.
  STANDBY_SLAVE_POS="0-10-100"; STANDBY_BINLOG_POS=""; STANDBY_SERVER_ID=100
  PRIMARY_SERVER_ID=""; PRIMARY_POS="0-10-100"; PRIMARY_EARLIEST_POS="0-10-1"
  _install_mocks
  run mdbr_assess pod-0 secret peer-host
  [ "$status" -eq 1 ]
  [ "$(jq -r '.error' <<<"$output")" = "DATABASE_NOT_READY" ]
}

@test "a failed SHOW BINARY LOGS is a peer failure, not 'binary logging is off'" {
  # The two reason codes lead to different operator actions: retry the network
  # versus fix the primary's configuration.
  STANDBY_SLAVE_POS="0-10-100"; STANDBY_BINLOG_POS=""; STANDBY_SERVER_ID=100
  PRIMARY_SERVER_ID=10; PRIMARY_POS="0-10-100"
  _install_mocks
  mdbr_remote_sql() {
    case "$4" in
      *gtid_binlog_pos*) printf '0-10-100\n' ;;
      *server_id*)       printf '10\n' ;;
      *SHOW\ BINARY\ LOGS*) return 1 ;;   # peer went away mid-assessment
      *) return 1 ;;
    esac
  }
  run mdbr_assess pod-0 secret peer-host
  [ "$status" -eq 1 ]
  [ "$(jq -r '.error' <<<"$output")" = "PEER_UNREACHABLE" ]
}

@test "the failure reason survives command substitution" {
  # Callers capture stdout with $( ), which runs the function in a subshell —
  # MDBR_ASSESS_ERROR never reaches them, so the reason must be on stdout.
  STANDBY_SLAVE_POS="0-10-100"; STANDBY_BINLOG_POS=""; STANDBY_SERVER_ID=100
  PEER_REACHABLE=false
  _install_mocks

  local captured
  captured="$(mdbr_assess pod-0 secret peer-host)" || true
  [ "$(mdbr_assess_reason "$captured")" = "PEER_UNREACHABLE" ]
}

@test "assess_reason falls back to INTERNAL_ERROR rather than inventing a cause" {
  [ "$(mdbr_assess_reason '')" = "INTERNAL_ERROR" ]
  [ "$(mdbr_assess_reason 'not json')" = "INTERNAL_ERROR" ]
}
