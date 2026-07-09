#!/usr/bin/env bats

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mariadb/migration/check-connection.sh"
  export MARIADB_NAME=mariadb
  export _LOG_CURRENT_LEVEL=3
  mkdir -p "${TEST_TMPDIR}/bin"

  cat > "${TEST_TMPDIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context|--namespace|--kubeconfig) shift 2 ;;
    -n) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

cmd="${args[0]:-}"

if [[ "$cmd" == "cluster-info" ]]; then
  echo "Kubernetes control plane is running"
  exit 0
fi

if [[ "$cmd" == "get" ]]; then
  resource="${args[1]:-}"
  name="${args[2]:-}"
  output="${args[*]}"

  if [[ "$output" == *'items[*]'* ]]; then
    if [[ "$resource" == "mariadb" ]]; then
      printf '%s' "${KUBECTL_CR_NAMES:-}" | tr ' ' '\n' | sed '/^$/d'
    elif [[ "$resource" == "statefulset" ]]; then
      printf '%s' "${KUBECTL_STS_NAMES:-}" | tr ' ' '\n' | sed '/^$/d'
    fi
    exit 0
  fi

  if [[ "$resource" == "mariadb" && -n "$name" && "$name" != "-o" ]]; then
    case "$output" in
      *'.spec.replicas'*) printf '%s' "${KUBECTL_CR_REPLICAS:-1}" ;;
      *) printf '{}' ;;
    esac
    exit 0
  fi

  if [[ "$resource" == "statefulset" && -n "$name" && "$name" != "-o" ]]; then
    case "$output" in
      *'.spec.replicas'*) printf '%s' "${KUBECTL_STS_REPLICAS:-1}" ;;
      *) printf '{}' ;;
    esac
    exit 0
  fi
fi

if [[ "$cmd" == "exec" ]]; then
  shift_index=0
  for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "--" ]]; then
      shift_index=$((i + 1))
      break
    fi
  done
  command=("${args[@]:$shift_index}")

  pod="${args[1]:-}"
  if [[ "${KUBECTL_POD_EXEC_FAIL:-false}" == "true" ]]; then
    echo "Error: pods \"${pod}\" not found" >&2
    exit 1
  fi

  case "${command[0]:-}" in
    "true") exit 0 ;;
    "printenv")
      var_name="${command[1]:-}"
      if [[ "$var_name" == "MARIADB_ROOT_PASSWORD" ]]; then
        if [[ "${MOCK_NO_ROOT_PASSWORD:-false}" == "true" ]]; then
          exit 1
        fi
        printf '%s' "${MOCK_ROOT_PASSWORD:-secret-root-pass}"
        exit 0
      fi
      exit 1
      ;;
    "mariadb")
      exit "${MOCK_MARIADB_CONNECT_EXIT:-0}"
      ;;
    *) exit 0 ;;
  esac
fi

echo "unexpected kubectl invocation: ${args[*]}" >&2
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/kubectl"
}

# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

@test "connection PASS returns structured JSON with CONNECTION_OK" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --ip 10.0.0.1 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "PASS" ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "CONNECTION_OK" ]
}

@test "connection PASS includes pod in result" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --ip 10.0.0.1 --json

  [ "$status" -eq 0 ]
  pod=$(printf '%s' "$output" | jq -r '.target.pod')
  [ "$pod" = "mariadb-0" ]
}

@test "connection PASS includes target host and port in result" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --ip 10.0.0.1 --port 3307 --json

  [ "$status" -eq 0 ]
  host=$(printf '%s' "$output" | jq -r '.connection.host')
  port=$(printf '%s' "$output" | jq -r '.connection.port')
  [ "$host" = "10.0.0.1" ]
  [ "$port" = "3307" ]
}

@test "all three checks pass in happy path" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --ip 10.0.0.1 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "pod_exec") | .status')" = "PASS" ]
  [ "$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "root_password") | .status')" = "PASS" ]
  [ "$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "connection") | .status')" = "PASS" ]
}

# ---------------------------------------------------------------------------
# Connection failure
# ---------------------------------------------------------------------------

@test "connection BLOCK when mariadb client returns non-zero" {
  export MOCK_MARIADB_CONNECT_EXIT=1

  run "${SCRIPT}" --namespace db-1 --mdb mariadb --ip 10.0.0.1 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "BLOCK" ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "CONNECTION_FAILED" ]
}

@test "connection check reason code is CONNECTION_FAILED on failure" {
  export MOCK_MARIADB_CONNECT_EXIT=1

  run "${SCRIPT}" --namespace db-1 --mdb mariadb --ip 192.0.2.1 --json

  [ "$status" -eq 0 ]
  reason=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "connection") | .reason_code')
  [ "$reason" = "CONNECTION_FAILED" ]
}

# ---------------------------------------------------------------------------
# Pod exec failure
# ---------------------------------------------------------------------------

@test "pod exec failure emits BLOCK with POD_EXEC_FAILED" {
  export KUBECTL_POD_EXEC_FAIL=true

  run "${SCRIPT}" --namespace db-1 --mdb mariadb --ip 10.0.0.1 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "BLOCK" ]
  reason=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "pod_exec") | .reason_code')
  [ "$reason" = "POD_EXEC_FAILED" ]
}

# ---------------------------------------------------------------------------
# Root password unavailable
# ---------------------------------------------------------------------------

@test "root password unavailable emits ERROR with ROOT_PASSWORD_NOT_FOUND" {
  export MOCK_NO_ROOT_PASSWORD=true

  run "${SCRIPT}" --namespace db-1 --mdb mariadb --ip 10.0.0.1 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  reason=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "root_password") | .reason_code')
  [ "$reason" = "ROOT_PASSWORD_NOT_FOUND" ]
}

@test "connection check is ERROR when root password unavailable" {
  export MOCK_NO_ROOT_PASSWORD=true

  run "${SCRIPT}" --namespace db-1 --mdb mariadb --ip 10.0.0.1 --json

  [ "$status" -eq 0 ]
  conn_status=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "connection") | .status')
  [ "$conn_status" = "ERROR" ]
}

# ---------------------------------------------------------------------------
# Auto-detection
# ---------------------------------------------------------------------------

@test "auto-detects MariaDB CR when --mdb is omitted" {
  export KUBECTL_CR_NAMES="mdb-source"
  unset MARIADB_NAME

  run "${SCRIPT}" --namespace db-1 --ip 10.0.0.1 --json

  [ "$status" -eq 0 ]
  mdb=$(printf '%s' "$output" | jq -r '.target.mdb')
  [ "$mdb" = "mdb-source" ]
}

@test "reports MARIADB_AMBIGUOUS when several CRs exist and --mdb is omitted" {
  export KUBECTL_CR_NAMES="alpha beta"
  unset MARIADB_NAME

  run "${SCRIPT}" --namespace db-1 --ip 10.0.0.1 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  check_reason=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "target_resolve") | .reason_code')
  [ "$check_reason" = "MARIADB_AMBIGUOUS" ]
}

@test "reports MARIADB_NOT_FOUND when no CR or StatefulSet exists" {
  export KUBECTL_CR_NAMES=""
  export KUBECTL_STS_NAMES=""
  unset MARIADB_NAME

  run "${SCRIPT}" --namespace db-1 --ip 10.0.0.1 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  check_reason=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "target_resolve") | .reason_code')
  [ "$check_reason" = "MARIADB_NOT_FOUND" ]
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "exits 2 when --ip is missing" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --json
  [ "$status" -eq 2 ]
}

@test "exits 2 when --port is not numeric" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --ip 10.0.0.1 --port abc --json
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Default port
# ---------------------------------------------------------------------------

@test "default port is 3306" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --ip 10.0.0.1 --json

  [ "$status" -eq 0 ]
  port=$(printf '%s' "$output" | jq -r '.connection.port')
  [ "$port" = "3306" ]
}

# ---------------------------------------------------------------------------
# Result file
# ---------------------------------------------------------------------------

@test "writes JSON result to result file when --result-file is specified" {
  local result_file="${TEST_TMPDIR}/result.json"

  run "${SCRIPT}" --namespace db-1 --mdb mariadb --ip 10.0.0.1 \
    --result-file "$result_file"

  [ "$status" -eq 0 ]
  [ -f "$result_file" ]
  [ "$(jq -r '.status' "$result_file")" = "PASS" ]
}
