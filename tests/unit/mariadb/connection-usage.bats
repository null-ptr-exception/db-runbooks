#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/connection-usage.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"
  MOCK_DIR="$(mktemp -d)"
  RESULT="${MOCK_DIR}/result.json"

  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
args="$*"

if [[ "$args" == *"get mariadb"*"items[*]"* ]]; then
  printf '%s\n' ${MOCK_MDB_NAMES:-mariadb}
  exit 0
fi
if [[ "$args" == *"get mariadb"*"currentPrimary"* ]]; then
  printf '%s' "${MOCK_PRIMARY:-mariadb-0}"
  exit 0
fi
if [[ "$args" == *"get pods"* ]]; then
  printf '%s\n' ${MOCK_PODS:-mariadb-0 mariadb-1}
  exit 0
fi

if [[ " $args " == *" exec "* ]]; then
  pod=""
  previous=""
  for arg in "$@"; do
    if [[ "$previous" == "exec" ]]; then pod="$arg"; break; fi
    previous="$arg"
  done

  if [[ "$args" == *"printenv MARIADB_ROOT_PASSWORD"* ]]; then
    [[ "${MOCK_ROOT_PASSWORD-testpass}" == "__EMPTY__" ]] && exit 1
    printf '%s' "${MOCK_ROOT_PASSWORD-testpass}"
    exit 0
  fi

  if [[ "$args" == *"SELECT @@GLOBAL.max_connections;"* ]]; then
    [[ "$args" == *"ID <> CONNECTION_ID()"* ]] || {
      echo "task query did not exclude its own session" >&2
      exit 9
    }
    [[ "$args" != *"INFO"* ]] || {
      echo "task query must not select SQL text" >&2
      exit 9
    }
    if [[ -n "${MOCK_FAIL_POD:-}" && "$pod" == "$MOCK_FAIL_POD" ]]; then
      exit 1
    fi
    if [[ "${MOCK_EMPTY:-false}" == "true" ]]; then
      printf '%s\n' "${MOCK_MAX_CONNECTIONS:-100}"
      exit 0
    fi
    case "$pod" in
      mariadb-0)
        cat <<'ROWS'
100
{"account": "app_a", "current_connections": 3, "active_connections": "2", "idle_connections": "1", "longest_active_seconds": 12}
{"account": "app_b", "current_connections": 1, "active_connections": "0", "idle_connections": "1", "longest_active_seconds": 0}
ROWS
        ;;
      mariadb-1)
        cat <<'ROWS'
200
{"account": "app_a", "current_connections": 2, "active_connections": "1", "idle_connections": "1", "longest_active_seconds": 5}
{"account": "report_user", "current_connections": 4, "active_connections": "4", "idle_connections": "0", "longest_active_seconds": 30}
ROWS
        ;;
      *)
        printf '100\n'
        ;;
    esac
    exit 0
  fi
fi

echo "unexpected kubectl invocation: $args" >&2
exit 1
MOCK
  chmod +x "${MOCK_DIR}/kubectl"

  export DB_NAMESPACE="mariadb-1" MARIADB_NAME="mariadb"
  unset MOCK_FAIL_POD MOCK_EMPTY MOCK_ROOT_PASSWORD MOCK_PODS MOCK_MDB_NAMES || true
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

run_usage() {
  run env "PATH=${MOCK_DIR}:${PATH}" "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" "$@" bash "${SCRIPT}"
}

field() {
  jq -r "$1" "${RESULT}"
}

@test "connection-usage aggregates and sorts accounts across pods" {
  run_usage TOP_ACCOUNTS=2

  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "READY" ]
  [ "$(field '.reason_code')" = "CONNECTION_USAGE_READY" ]
  [ "$(field '.snapshot_type')" = "point-in-time" ]
  [ "$(field '.total_connections')" = "10" ]
  [ "$(field '.connection_capacity')" = "300" ]
  [ "$(field '.utilization_percent')" = "3.3" ]
  [ "$(field '.account_count')" = "3" ]
  [ "$(field '.accounts | length')" = "2" ]
  [ "$(field '.accounts[0].account')" = "app_a" ]
  [ "$(field '.accounts[0].current_connections')" = "5" ]
  [ "$(field '.accounts[0].active_connections')" = "3" ]
  [ "$(field '.accounts[0].idle_connections')" = "2" ]
  [ "$(field '.accounts[0].longest_active_seconds')" = "12" ]
  [ "$(field '.accounts[0].share_percent')" = "50" ]
  [ "$(field '.accounts[0].pods | join(",")')" = "mariadb-0,mariadb-1" ]
  [ "$(field '.accounts[1].account')" = "report_user" ]
}

@test "connection-usage reports per-pod capacity without treating it as one global limit" {
  run_usage

  [ "$(field '.pods | length')" = "2" ]
  [ "$(field '.pods[] | select(.pod=="mariadb-0") | .current_connections')" = "4" ]
  [ "$(field '.pods[] | select(.pod=="mariadb-0") | .max_connections')" = "100" ]
  [ "$(field '.pods[] | select(.pod=="mariadb-1") | .current_connections')" = "6" ]
  [ "$(field '.pods[] | select(.pod=="mariadb-1") | .max_connections')" = "200" ]
}

@test "connection-usage returns an empty snapshot when there are no client sessions" {
  run_usage MOCK_EMPTY=true

  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "READY" ]
  [ "$(field '.total_connections')" = "0" ]
  [ "$(field '.account_count')" = "0" ]
  [ "$(field '.accounts | length')" = "0" ]
  [ "$(field '.warnings | length')" = "0" ]
}

@test "connection-usage validates the top bound" {
  run_usage TOP_ACCOUNTS=0

  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "BLOCKED" ]
  [ "$(field '.reason_code')" = "INVALID_TOP" ]
}

@test "connection-usage makes a failed pod explicit and marks data partial" {
  run_usage MOCK_FAIL_POD=mariadb-1

  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "PARTIAL" ]
  [ "$(field '.reason_code')" = "CONNECTION_USAGE_PARTIAL" ]
  [ "$(field '.partial')" = "true" ]
  [ "$(field '.queried_pods')" = "1" ]
  [ "$(field '.failed_pods')" = "1" ]
  [ "$(field '.pods[] | select(.pod=="mariadb-1") | .collected')" = "false" ]
  [ "$(field '.connection_capacity')" = "100" ]
}

@test "connection-usage fails when every pod query fails" {
  export MOCK_PODS="mariadb-1"
  run_usage MOCK_FAIL_POD=mariadb-1

  [ "$status" -ne 0 ]
  [ "$(field '.status')" = "ERROR" ]
  [ "$(field '.reason_code')" = "CONNECTION_USAGE_UNAVAILABLE" ]
  [ "$(field '.pods[0].error')" = "SQL collection failed" ]
}

@test "connection-usage blocks when the managed root credential is unavailable" {
  run_usage MOCK_ROOT_PASSWORD=__EMPTY__

  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "BLOCKED" ]
  [ "$(field '.reason_code')" = "ROOT_PASSWORD_UNAVAILABLE" ]
}

@test "connection-usage emits structured utilization and account-share warnings" {
  run_usage CONNECTION_USAGE_WARN_PCT=3 \
    CONNECTION_USAGE_ACCOUNT_SHARE_WARN_PCT=40 \
    CONNECTION_USAGE_ACCOUNT_SHARE_WARN_MIN=1

  [ "$(field '.status')" = "WARN" ]
  [ "$(field '.warnings | map(.code) | sort | join(",")')" = \
    "ACCOUNT_CONNECTION_SHARE_HIGH,CONNECTION_UTILIZATION_HIGH" ]
  [ "$(field '.warnings[] | select(.code=="ACCOUNT_CONNECTION_SHARE_HIGH") | .account')" = "app_a" ]
}

@test "connection-usage output never contains credentials, SQL text, hosts, or connection ids" {
  run_usage MARIADB_ROOT_PASSWORD=super-secret-value

  [ "$status" -eq 0 ]
  run grep -Fq 'super-secret-value' "${RESULT}"
  [ "$status" -ne 0 ]
  run grep -Eqi 'select |processlist|connection_id|client.address|"host"|"id"' "${RESULT}"
  [ "$status" -ne 0 ]
}

@test "connection-usage auto-detects a single MariaDB instance" {
  unset MARIADB_NAME
  run_usage MOCK_MDB_NAMES=custom-db MOCK_PODS=custom-db-0 MOCK_EMPTY=true

  [ "$status" -eq 0 ]
  [ "$(field '.mdb')" = "custom-db" ]
}
