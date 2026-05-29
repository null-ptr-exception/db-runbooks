#!/usr/bin/env bats

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mariadb/create-account.sh"
  export _LOG_CURRENT_LEVEL=3
  mkdir -p "${TEST_TMPDIR}/bin"

  cat > "${TEST_TMPDIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context|--namespace|--kubeconfig)
      shift 2
      ;;
    -n)
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

cmd="${args[0]:-}"

if [[ "$cmd" == "cluster-info" ]]; then
  echo "Kubernetes control plane is running"
  exit 0
fi

if [[ "$cmd" == "apply" ]]; then
  if [[ "${KUBECTL_APPLY_FAIL:-0}" == "1" ]]; then
    echo "simulated apply failure" >&2
    exit 1
  fi
  cat > "${TEST_TMPDIR}/applied-secret.yaml"
  exit 0
fi

if [[ "$cmd" == "get" ]]; then
  resource="${args[1]:-}"
  name="${args[2]:-}"
  output="${args[*]}"

  if [[ "$resource" == "mariadb" && "$name" == "mariadb" ]]; then
    case "$output" in
      *'.status.currentPrimary'*)
        printf 'mariadb-0'
        ;;
      *'.spec.replicas'*)
        printf '1'
        ;;
      *)
        printf '{}'
        ;;
    esac
    exit 0
  fi

  if [[ "$resource" == "statefulset" && "$name" == "mariadb" ]]; then
    printf '1'
    exit 0
  fi

  if [[ "$resource" == "secret" && "$name" == "provided-password" ]]; then
    printf 'UHJvdmlkZWRQYXNzMTIz'
    exit 0
  fi

  if [[ "$resource" == "secret" ]]; then
    echo "secret ${name} not found" >&2
    exit 1
  fi
fi

if [[ "$cmd" == "exec" ]]; then
  pod="${args[1]:-}"
  shift_index=0
  for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "--" ]]; then
      shift_index=$((i + 1))
      break
    fi
  done
  command=("${args[@]:$shift_index}")

  if [[ "$pod" == "mariadb-0" && "${command[*]}" == "printenv MARIADB_ROOT_PASSWORD" ]]; then
    printf 'root-pass'
    exit 0
  fi

  last_index=$((${#command[@]} - 1))
  query="${command[$last_index]}"
  printf '%s\n' "$query" >> "${TEST_TMPDIR}/sql.log"

  case "$query" in
    SELECT\ COUNT\(\*\)\ FROM\ mysql.user*)
      printf '%s\n' "${CREATE_ACCOUNT_EXISTS:-0}"
      ;;
    CREATE\ USER*)
      if [[ "${SQL_FAIL_CREATE:-0}" == "1" ]]; then
        echo "simulated create failure" >&2
        exit 1
      fi
      printf 'ok\n'
      ;;
    GRANT*)
      if [[ "${SQL_FAIL_GRANT:-0}" == "1" ]]; then
        echo "simulated grant failure" >&2
        exit 1
      fi
      printf 'ok\n'
      ;;
    SHOW\ GRANTS*)
      printf 'ok\n'
      ;;
    *)
      printf ''
      ;;
  esac
  exit 0
fi

echo "unexpected kubectl invocation: ${args[*]}" >&2
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/kubectl"
}

@test "dry-run returns READY with a redacted SQL plan" {
  run "${SCRIPT}" \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT,INSERT \
    --password-secret-name app-user-password \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  dry_run=$(printf '%s' "$output" | jq -r '.dry_run')
  redacted=$(printf '%s' "$output" | jq -r '.sql_plan[]' | grep -c '<redacted>')

  [ "$result_status" = "READY" ]
  [ "$reason_code" = "DRY_RUN_READY" ]
  [ "$dry_run" = "true" ]
  [ "$redacted" -gt 0 ]
}

@test "actual run without confirm is blocked before changing anything" {
  run "${SCRIPT}" \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT \
    --password-secret-name app-user-password \
    --dry-run false \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "BLOCKED" ]
  [ "$reason_code" = "CONFIRM_REQUIRED" ]
  [ ! -f "${TEST_TMPDIR}/applied-secret.yaml" ]
}

@test "invalid username is rejected" {
  run "${SCRIPT}" \
    --namespace mariadb-2 \
    --database app_db \
    --username root \
    --privileges SELECT \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "ERROR" ]
  [ "$reason_code" = "INVALID_INPUT" ]
}

@test "global scope is rejected by default" {
  run "${SCRIPT}" \
    --namespace mariadb-2 \
    --database '*.*' \
    --username app_user \
    --privileges SELECT \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "ERROR" ]
  [ "$reason_code" = "INVALID_INPUT" ]
}

@test "admin privilege is rejected by default" {
  run "${SCRIPT}" \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SUPER \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "ERROR" ]
  [ "$reason_code" = "INVALID_INPUT" ]
}

@test "unsafe host is rejected" {
  run "${SCRIPT}" \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --host "bad host" \
    --privileges SELECT \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "ERROR" ]
  [ "$reason_code" = "INVALID_INPUT" ]
}

@test "actual run creates a password Secret and does not print the password" {
  run "${SCRIPT}" \
    --context kind-cluster-dbs \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT,INSERT \
    --password-secret-name app-user-password \
    --dry-run false \
    --confirm true \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  managed=$(printf '%s' "$output" | jq -r '.password_secret.managed')

  [ "$result_status" = "CREATED" ]
  [ "$reason_code" = "ACCOUNT_CREATED" ]
  [ "$managed" = "true" ]
  [ -f "${TEST_TMPDIR}/applied-secret.yaml" ]
  ! printf '%s' "$output" | grep -q 'stringData'
  ! printf '%s' "$output" | grep -q 'root-pass'
}

@test "new account without password Secret name is blocked" {
  run "${SCRIPT}" \
    --context kind-cluster-dbs \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT \
    --dry-run false \
    --confirm true \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "BLOCKED" ]
  [ "$reason_code" = "PASSWORD_SECRET_REQUIRED" ]
}

@test "secret-provided password path blocks when Secret is unreadable" {
  run "${SCRIPT}" \
    --context kind-cluster-dbs \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT \
    --password-secret-name missing-password \
    --generate-password false \
    --dry-run false \
    --confirm true \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "BLOCKED" ]
  [ "$reason_code" = "PASSWORD_SECRET_UNAVAILABLE" ]
}

@test "SQL create failure returns SQL_FAILED" {
  export SQL_FAIL_CREATE=1

  run "${SCRIPT}" \
    --context kind-cluster-dbs \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT \
    --password-secret-name app-user-password \
    --dry-run false \
    --confirm true \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "ERROR" ]
  [ "$reason_code" = "SQL_FAILED" ]
}

@test "existing account is idempotent and does not rewrite password Secret" {
  export CREATE_ACCOUNT_EXISTS=1

  run "${SCRIPT}" \
    --context kind-cluster-dbs \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT \
    --password-secret-name app-user-password \
    --dry-run false \
    --confirm true \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  exists=$(printf '%s' "$output" | jq -r '.account_exists')

  [ "$result_status" = "UNCHANGED" ]
  [ "$reason_code" = "ACCOUNT_EXISTS" ]
  [ "$exists" = "true" ]
  [ ! -f "${TEST_TMPDIR}/applied-secret.yaml" ]
}

@test "secret-provided password path is supported" {
  run "${SCRIPT}" \
    --context kind-cluster-dbs \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT \
    --password-secret-name provided-password \
    --generate-password false \
    --dry-run false \
    --confirm true \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  managed=$(printf '%s' "$output" | jq -r '.password_secret.managed')

  [ "$result_status" = "CREATED" ]
  [ "$managed" = "false" ]
  [ ! -f "${TEST_TMPDIR}/applied-secret.yaml" ]
}
