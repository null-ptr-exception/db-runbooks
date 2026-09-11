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

@test "replica configure creates an owned named channel with a quoted password" {
  local captured="$BATS_TEST_TMPDIR/change-master.sql"
  mariadb_exec() { printf '%s' "${@: -1}" > "$captured"; }

  mdbr_replica_configure pod-0 's3cr!t' peer.example 3306 current_pos

  grep -q "CHANGE MASTER 'aqsh-cross-cluster' TO" "$captured"
  grep -q "MASTER_HOST='peer.example'" "$captured"
  grep -q "MASTER_PASSWORD='s3cr!t'" "$captured"
  grep -q 'MASTER_USE_GTID=current_pos' "$captured"
  grep -q "START SLAVE 'aqsh-cross-cluster'" "$captured"
}

@test "replica configure safely quotes apostrophes and backslashes" {
  local captured="$BATS_TEST_TMPDIR/change-master-special.sql"
  mariadb_exec() { printf '%s' "${@: -1}" > "$captured"; }

  mdbr_replica_configure pod-0 "pa'ss\\word" peer.example 3306 slave_pos

  grep -Fq "NO_BACKSLASH_ESCAPES" "$captured"
  grep -Fq "MASTER_PASSWORD='pa''ss\\word'" "$captured"
}

@test "replica configure rejects an unsafe source host before SQL" {
  mariadb_sql() { return 99; }
  run mdbr_replica_configure pod-0 secret "peer';DROP TABLE x" 3306 slave_pos
  [ "$status" -eq 2 ]
}

@test "restored named source metadata is removed before cross-cluster wiring" {
  local counter="$BATS_TEST_TMPDIR/reset-restored.calls"
  local captured="$BATS_TEST_TMPDIR/reset-restored.sql"
  printf '0' > "$counter"
  mdbr_replica_status() {
    local calls
    calls="$(cat "$counter")"
    calls=$((calls + 1))
    printf '%s' "$calls" > "$counter"
    if (( calls == 1 )); then
      jq -nc '{configured:true,connectionName:"mariadb-operator",error:null}'
    else
      jq -nc '{configured:false,connectionName:null,error:null}'
    fi
  }
  mariadb_sql() { printf '%s' "$3" > "$captured"; }

  run mdbr_replica_reset_restored_source pod-0 secret
  [ "$status" -eq 0 ]
  grep -q "STOP SLAVE 'mariadb-operator'" "$captured"
  grep -q "RESET SLAVE 'mariadb-operator' ALL" "$captured"
}

@test "restored replication cleanup fails closed on multiple connections" {
  mdbr_replica_status() {
    jq -nc '{configured:true,error:"MULTIPLE_REPLICATION_CONNECTIONS",rows:2}'
  }
  mariadb_sql() { return 99; }

  run mdbr_replica_reset_restored_source pod-0 secret
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
EOF

  run bash -c "
    export MDBT_CONFIG_FILE='$cfg' LIB_DIR='$LIB_DIR'
    source '$LIB_DIR/mariadb-replication-link.sh'
    printf '%s|%s|%s\n' \"\$MDBR_PEER_PORT\" \"\$MDBR_MAX_EXTERNAL_CONNECTIONS\" \"\$(mdbr_peer_host db-ops)\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "30091|5|db-ops-write.db-ops.svc.cluster.local" ]
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

@test "v24 cross-cluster standby rejects operator local replication" {
  run mdbr_is_standalone '{"spec":{"replicas":2,"replication":{"enabled":true}}}'
  [ "$status" -eq 1 ]

  run mdbr_is_standalone '{"spec":{"replicas":1}}'
  [ "$status" -eq 0 ]
}

@test "standalone target falls back to pod zero when status has no primary" {
  MARIADB_NAME=mariadb
  run mdbr_primary_pod '{"spec":{"replicas":1},"status":{}}'
  [ "$status" -eq 0 ]
  [ "$output" = "mariadb-0" ]
}

@test "replica configure retains the SQL error code without secret-bearing backend text" {
  mariadb_exec() {
    echo "ERROR 1201 (HY000): could not configure MASTER_PASSWORD='sensitive'" >&2
    return 1
  }
  if mdbr_replica_configure pod-0 sensitive peer.example 3306 current_pos; then
    return 1
  fi
  [ "$MDBR_REPLICA_SQL_ERR" = SQL_ERROR_1201 ]
  [[ "$MDBR_REPLICA_SQL_ERR" != *sensitive* ]]
}
