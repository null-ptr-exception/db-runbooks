#!/usr/bin/env bats

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mariadb/migration/setup-replication.sh"
  export MARIADB_NAME=mariadb
  export _LOG_CURRENT_LEVEL=3
  # Post-START-SLAVE health check retries instantly in tests.
  export SETUP_REPL_HEALTH_DELAY=0
  mkdir -p "${TEST_TMPDIR}/bin"

  # Mock kubectl
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

  if [[ "$resource" == "secret" ]]; then
    if [[ "${MOCK_SECRET_MISSING:-false}" == "true" ]]; then
      echo "Error: secrets \"${name}\" not found" >&2
      exit 1
    fi
    # k8s_secret_value reads the full Secret via -o json then does its own
    # jq map-key lookup — every test here uses the default "password" key
    # (no test overrides --repl-password-key), so wrap the single mock
    # value under that one key.
    printf '{"data":{"password":"%s"}}' "${MOCK_SECRET_B64:-cmVwbC1zZWNyZXQtcGFzcw==}"
    exit 0
  fi

  if [[ "$output" == *'items[*]'* ]]; then
    if [[ "$resource" == "mariadb" ]]; then
      printf '%s' "${KUBECTL_CR_NAMES-mariadb}" | tr ' ' '\n' | sed '/^$/d'
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
      last_idx=$(( ${#command[@]} - 1 ))
      query="${command[$last_idx]}"
      case "$query" in
        "STOP SLAVE"*) exit "${MOCK_STOP_SLAVE_EXIT:-0}" ;;
        "CHANGE MASTER"*) exit "${MOCK_CHANGE_MASTER_EXIT:-0}" ;;
        "SET GLOBAL rpl_semi_sync_slave_enabled=OFF") exit 0 ;;
        "START SLAVE"*) exit "${MOCK_START_SLAVE_EXIT:-0}" ;;
        "SHOW ALL SLAVES STATUS")
          printf '%s\n' "${MOCK_SLAVE_STATUS_OUT:-Slave_IO_Running: Yes}"
          exit 0
          ;;
        "SHOW SLAVE"*)
          # Channel-specific status query the post-START-SLAVE health check
          # polls. Defaults to healthy so existing DONE-path tests don't need
          # to opt in; override MOCK_CHANNEL_IO_RUNNING/_SQL_RUNNING to
          # simulate a channel that never comes up healthy.
          printf 'Slave_IO_Running: %s\nSlave_SQL_Running: %s\nLast_IO_Error: %s\nLast_SQL_Error: %s\n' \
            "${MOCK_CHANNEL_IO_RUNNING:-Yes}" "${MOCK_CHANNEL_SQL_RUNNING:-Yes}" \
            "${MOCK_CHANNEL_LAST_IO_ERROR:-}" "${MOCK_CHANNEL_LAST_SQL_ERROR:-}"
          exit 0
          ;;
        *) exit 0 ;;
      esac
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
# Argument validation
# ---------------------------------------------------------------------------

@test "reports INVALID_INPUT when --namespace is missing" {
  run "${SCRIPT}" --host 10.0.0.1 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "INVALID_INPUT" ]
  [[ "$(printf '%s' "$output" | jq -r '.errors[]')" == *"namespace is required"* ]]
}

@test "reports INVALID_INPUT when --host is missing" {
  run "${SCRIPT}" --namespace db-1 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  [[ "$(printf '%s' "$output" | jq -r '.errors[]')" == *"host is required"* ]]
}

@test "reports INVALID_INPUT when --port is not numeric" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --port abc --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  [[ "$(printf '%s' "$output" | jq -r '.errors[]')" == *"port must be"* ]]
  # A non-numeric port must not corrupt the JSON response itself.
  [ "$(printf '%s' "$output" | jq -r '.replication.port')" = "null" ]
}

@test "reports INVALID_INPUT when --port is 0" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --port 0 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  [[ "$(printf '%s' "$output" | jq -r '.errors[]')" == *"port must be"* ]]
}

@test "reports INVALID_INPUT when --port is above 65535" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --port 99999999 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  [[ "$(printf '%s' "$output" | jq -r '.errors[]')" == *"port must be"* ]]
}

@test "reports INVALID_INPUT when --delay is negative" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --delay -5 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  [[ "$(printf '%s' "$output" | jq -r '.errors[]')" == *"delay must be"* ]]
}

@test "reports INVALID_INPUT for a malformed namespace" {
  run "${SCRIPT}" --namespace "Bad_NS!" --host 10.0.0.1 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  [[ "$(printf '%s' "$output" | jq -r '.errors[]')" == *"namespace must be"* ]]
}

@test "reports INVALID_INPUT for a non-boolean dry_run" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run maybe --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  [[ "$(printf '%s' "$output" | jq -r '.errors[]')" == *"DRY_RUN must be"* ]]
}

@test "exits 2 on an unknown option" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --bogus-flag
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------

@test "dry_run renders SQL plan without applying anything" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "READY" ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "DRY_RUN_READY" ]
  [ "$(printf '%s' "$output" | jq -r '.dry_run')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.sql_plan | length')" -gt 0 ]
}

@test "dry_run SQL plan redacts the replication password" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --json

  [ "$status" -eq 0 ]
  plan=$(printf '%s' "$output" | jq -r '.sql_plan[] | select(startswith("CHANGE MASTER"))')
  [[ "$plan" == *"MASTER_PASSWORD='<redacted>'"* ]]
}

@test "dry_run SQL plan includes MASTER_DELAY when --delay is set" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --delay 30 --json

  [ "$status" -eq 0 ]
  plan=$(printf '%s' "$output" | jq -r '.sql_plan[] | select(startswith("CHANGE MASTER"))')
  [[ "$plan" == *"MASTER_DELAY=30"* ]]
}

@test "dry_run SQL plan includes semi-sync disable when --async=true" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --async true --json

  [ "$status" -eq 0 ]
  [[ "$(printf '%s' "$output" | jq -c '.sql_plan')" == *"rpl_semi_sync_slave_enabled=OFF"* ]]
}

@test "dry_run SQL plan omits semi-sync statement by default" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --json

  [ "$status" -eq 0 ]
  [[ "$(printf '%s' "$output" | jq -c '.sql_plan')" != *"rpl_semi_sync"* ]]
}

@test "dry_run does not touch kubectl" {
  # PATH still has the mock kubectl, but a namespace-only dry run must never
  # attempt to resolve a target or exec into a pod.
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.target.pod')" = "" ]
}

# ---------------------------------------------------------------------------
# Confirm gating
# ---------------------------------------------------------------------------

@test "reports BLOCKED when dry_run=false without confirm" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false \
    --repl-password-secret repl-creds --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "BLOCKED" ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "CONFIRM_REQUIRED" ]
}

@test "a real run (dry_run=false) without repl_password_secret is INVALID_INPUT, even for repl_user=root" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false --confirm true --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "INVALID_INPUT" ]
  [[ "$(printf '%s' "$output" | jq -r '.errors[]')" == *"repl_password_secret is required when dry_run is false"* ]]
}

@test "dry_run=true (SQL plan preview) still works without repl_password_secret" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "READY" ]
}

# ---------------------------------------------------------------------------
# Real run: k8s / target resolution failures
# ---------------------------------------------------------------------------

@test "reports MARIADB_AMBIGUOUS when several CRs exist and --mdb is omitted" {
  export KUBECTL_CR_NAMES="alpha beta"
  unset MARIADB_NAME

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false --confirm true \
    --repl-password-secret repl-creds --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "MARIADB_AMBIGUOUS" ]
}

@test "reports MARIADB_NOT_FOUND when no CR or StatefulSet exists" {
  export KUBECTL_CR_NAMES=""
  export KUBECTL_STS_NAMES=""
  unset MARIADB_NAME

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false --confirm true \
    --repl-password-secret repl-creds --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "MARIADB_NOT_FOUND" ]
}

@test "reports NO_POD_FOUND when the target has zero replicas" {
  export KUBECTL_CR_REPLICAS=0

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false --confirm true \
    --repl-password-secret repl-creds --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "NO_POD_FOUND" ]
}

@test "reports ROOT_PASSWORD_UNAVAILABLE when the pod has no root password" {
  export MOCK_NO_ROOT_PASSWORD=true

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false --confirm true \
    --repl-password-secret repl-creds --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "ROOT_PASSWORD_UNAVAILABLE" ]
}

# ---------------------------------------------------------------------------
# Real run: replication password from a Secret
# ---------------------------------------------------------------------------

@test "reads the replication password from repl_password_secret when provided" {
  export MOCK_SECRET_B64="bXktcmVwbC1wYXNz"  # "my-repl-pass"

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 \
    --repl-password-secret repl-creds --dry-run false --confirm true --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "DONE" ]
  [[ "$output" != *"my-repl-pass"* ]]
}

@test "reports REPL_PASSWORD_UNAVAILABLE when the secret cannot be read" {
  export MOCK_SECRET_MISSING=true

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 \
    --repl-password-secret repl-creds --dry-run false --confirm true --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "REPL_PASSWORD_UNAVAILABLE" ]
}

# ---------------------------------------------------------------------------
# repl_user
# ---------------------------------------------------------------------------

@test "MASTER_USER defaults to root in the dry-run SQL plan" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --json

  [ "$status" -eq 0 ]
  plan=$(printf '%s' "$output" | jq -r '.sql_plan[] | select(startswith("CHANGE MASTER"))')
  [[ "$plan" == *"MASTER_USER='root'"* ]]
  [ "$(printf '%s' "$output" | jq -r '.replication.user')" = "root" ]
}

@test "a custom repl_user without repl_password_secret is INVALID_INPUT" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --repl-user repl_svc --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "INVALID_INPUT" ]
  [[ "$(printf '%s' "$output" | jq -r '.errors[]')" == *"repl_password_secret is required"* ]]
}

@test "a custom repl_user with repl_password_secret renders the correct MASTER_USER" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --repl-user repl_svc \
    --repl-password-secret repl-creds --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "READY" ]
  plan=$(printf '%s' "$output" | jq -r '.sql_plan[] | select(startswith("CHANGE MASTER"))')
  [[ "$plan" == *"MASTER_USER='repl_svc'"* ]]
}

@test "a custom repl_user completes a real run using the secret's password, not root's" {
  export MOCK_SECRET_B64="bXktcmVwbC1wYXNz" # "my-repl-pass"
  export MOCK_ROOT_PASSWORD="target-root-pw"

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --repl-user repl_svc \
    --repl-password-secret repl-creds --dry-run false --confirm true --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "DONE" ]
  [ "$(printf '%s' "$output" | jq -r '.replication.user')" = "repl_svc" ]
  [[ "$output" != *"my-repl-pass"* ]]
  [[ "$output" != *"target-root-pw"* ]]
}

# ---------------------------------------------------------------------------
# Real run: SQL execution failures
# ---------------------------------------------------------------------------

@test "reports CHANGE_MASTER_FAILED when CHANGE MASTER TO fails" {
  export MOCK_CHANGE_MASTER_EXIT=1

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false --confirm true \
    --repl-password-secret repl-creds --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "CHANGE_MASTER_FAILED" ]
}

@test "reports START_SLAVE_FAILED when START SLAVE fails" {
  export MOCK_START_SLAVE_EXIT=1

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false --confirm true \
    --repl-password-secret repl-creds --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "START_SLAVE_FAILED" ]
}

@test "STOP SLAVE failure is tolerated (slave may not be configured yet)" {
  export MOCK_STOP_SLAVE_EXIT=1

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false --confirm true \
    --repl-password-secret repl-creds --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "DONE" ]
}

# ---------------------------------------------------------------------------
# Real run: success
# ---------------------------------------------------------------------------

@test "DONE on a successful real run, includes slave status" {
  export MOCK_SLAVE_STATUS_OUT="Slave_IO_Running: Yes
Slave_SQL_Running: Yes"

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false --confirm true \
    --repl-password-secret repl-creds --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "DONE" ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "REPLICATION_CONFIGURED" ]
  [ "$(printf '%s' "$output" | jq -r '.target.pod')" = "mariadb-0" ]
  [[ "$(printf '%s' "$output" | jq -r '.slave_status')" == *"Slave_IO_Running: Yes"* ]]
}

# ---------------------------------------------------------------------------
# Post-START-SLAVE health verification
# ---------------------------------------------------------------------------

@test "reports ERROR with REPLICATION_NOT_HEALTHY when Slave_IO_Running never becomes Yes" {
  export MOCK_CHANNEL_IO_RUNNING="Connecting"
  export MOCK_CHANNEL_LAST_IO_ERROR="Can't connect to MySQL server"

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false --confirm true \
    --repl-password-secret repl-creds --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "REPLICATION_NOT_HEALTHY" ]
  [[ "$(printf '%s' "$output" | jq -r '.summary')" == *"Can't connect to MySQL server"* ]]
}

@test "reports ERROR with REPLICATION_NOT_HEALTHY when Slave_SQL_Running never becomes Yes" {
  export MOCK_CHANNEL_SQL_RUNNING="No"
  export MOCK_CHANNEL_LAST_SQL_ERROR="Duplicate entry"

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false --confirm true \
    --repl-password-secret repl-creds --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ERROR" ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "REPLICATION_NOT_HEALTHY" ]
  [[ "$(printf '%s' "$output" | jq -r '.summary')" == *"Duplicate entry"* ]]
}

@test "DONE when the channel comes up healthy only after a retry" {
  cat > "${TEST_TMPDIR}/bin/kubectl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
attempt_file="${TEST_TMPDIR}/attempts"
args=()
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --context|--namespace|--kubeconfig) shift 2 ;;
    -n) shift 2 ;;
    *) args+=("\$1"); shift ;;
  esac
done
cmd="\${args[0]:-}"
[[ "\$cmd" == "cluster-info" ]] && { echo ok; exit 0; }
if [[ "\$cmd" == "get" ]]; then
  resource="\${args[1]:-}"
  output="\${args[*]}"
  if [[ "\$resource" == "secret" ]]; then
    printf '{"data":{"password":"cmVwbC1zZWNyZXQtcGFzcw=="}}'; exit 0
  fi
  if [[ "\$output" == *'items[*]'* ]]; then
    [[ "\$resource" == "mariadb" ]] && printf 'mariadb\n'
    exit 0
  fi
  [[ "\$output" == *'.spec.replicas'* ]] && { printf '1'; exit 0; }
  printf '{}'; exit 0
fi
if [[ "\$cmd" == "exec" ]]; then
  shift_index=0
  for i in "\${!args[@]}"; do [[ "\${args[\$i]}" == "--" ]] && { shift_index=\$((i+1)); break; }; done
  command=("\${args[@]:\$shift_index}")
  case "\${command[0]:-}" in
    printenv) printf 'secret-root-pass'; exit 0 ;;
    mariadb)
      last_idx=\$(( \${#command[@]} - 1 ))
      query="\${command[\$last_idx]}"
      case "\$query" in
        "SHOW ALL SLAVES STATUS") printf 'Slave_IO_Running: Yes\n'; exit 0 ;;
        "SHOW SLAVE"*)
          n=0
          [[ -f "\$attempt_file" ]] && n=\$(cat "\$attempt_file")
          n=\$((n + 1))
          echo "\$n" > "\$attempt_file"
          if [[ "\$n" -lt 2 ]]; then
            printf 'Slave_IO_Running: Connecting\nSlave_SQL_Running: Yes\n'
          else
            printf 'Slave_IO_Running: Yes\nSlave_SQL_Running: Yes\n'
          fi
          exit 0 ;;
        *) exit 0 ;;
      esac
      ;;
    *) exit 0 ;;
  esac
fi
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/kubectl"

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false --confirm true \
    --repl-password-secret repl-creds --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "DONE" ]
  # Proves it actually retried, not just got lucky on attempt 1.
  [ "$(cat "${TEST_TMPDIR}/attempts")" -ge 2 ]
}

@test "result never exposes the real replication password" {
  export MOCK_ROOT_PASSWORD="super-secret-root-pw"

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false --confirm true \
    --repl-password-secret repl-creds --json

  [ "$status" -eq 0 ]
  [[ "$output" != *"super-secret-root-pw"* ]]
  [[ "$(printf '%s' "$output" | jq -c '.sql_plan')" == *"<redacted>"* ]]
}

# ---------------------------------------------------------------------------
# strict-exit
# ---------------------------------------------------------------------------

@test "strict-exit exits 2 on ERROR" {
  export MOCK_NO_ROOT_PASSWORD=true

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false --confirm true --strict-exit \
    --repl-password-secret repl-creds --json
  [ "$status" -eq 2 ]
}

@test "strict-exit exits 1 on BLOCKED" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false --strict-exit \
    --repl-password-secret repl-creds --json
  [ "$status" -eq 1 ]
}

@test "strict-exit exits 0 on DONE" {
  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --dry-run false --confirm true --strict-exit \
    --repl-password-secret repl-creds --json
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Result file
# ---------------------------------------------------------------------------

@test "writes JSON result to result file when --result-file is specified" {
  local result_file="${TEST_TMPDIR}/result.json"

  run "${SCRIPT}" --namespace db-1 --host 10.0.0.1 --result-file "$result_file"

  [ "$status" -eq 0 ]
  [ -f "$result_file" ]
  [ "$(jq -r '.status' "$result_file")" = "READY" ]
}
