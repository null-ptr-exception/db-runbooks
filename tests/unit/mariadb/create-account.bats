#!/usr/bin/env bats

setup() {
  load '../../test_helper/bats-support/load.bash'
  load '../../test_helper/bats-assert/load.bash'

  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mariadb/create-account.sh"
  # These cases target a fixed "mariadb" CR; set it explicitly so the script
  # uses it directly instead of auto-detecting from the (mocked) namespace.
  export MARIADB_NAME=mariadb
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
  if [[ "${KUBECTL_UNAVAILABLE:-0}" == "1" ]]; then
    echo "connection refused" >&2
    exit 1
  fi
  echo "Kubernetes control plane is running"
  exit 0
fi

if [[ "$cmd" == "create" && "${args[1]:-}" == "secret" ]]; then
  if [[ "${KUBECTL_CREATE_FAIL:-0}" == "1" ]]; then
    echo "simulated create failure" >&2
    exit 1
  fi
  printf '%s\n' "${args[*]}" > "${TEST_TMPDIR}/created-secret.args"
  exit 0
fi

if [[ "$cmd" == "annotate" ]]; then
  printf '%s\n' "${args[*]}" > "${TEST_TMPDIR}/annotate-secret.args"
  exit 0
fi

if [[ "$cmd" == "get" ]]; then
  resource="${args[1]:-}"
  name="${args[2]:-}"
  output="${args[*]}"

  if [[ "$resource" == "mariadb" && "$name" == "mariadb" ]]; then
    case "$output" in
      *'.status.currentPrimary'*)
        if [[ "${CURRENT_PRIMARY_EMPTY:-0}" == "1" ]]; then printf ''; else printf 'mariadb-0'; fi
        ;;
      *'.spec.replicas'*)
        printf '%s' "${MOCK_REPLICAS:-1}"
        ;;
      *)
        printf '{}'
        ;;
    esac
    exit 0
  fi

  if [[ "$resource" == "statefulset" && "$name" == "mariadb" ]]; then
    printf '%s' "${MOCK_REPLICAS:-1}"
    exit 0
  fi

  if [[ "$resource" == "pods" ]]; then
    printf ''
    exit 0
  fi

  if [[ "$resource" == "secret" && "$output" == *annotations* ]]; then
    printf '%s' "${MOCK_SECRET_OWNER:-}"
    exit 0
  fi

  if [[ "$resource" == "secret" && "$name" == "mariadb-account-provided-password" ]]; then
    printf 'UHJvdmlkZWRQYXNzMTIz'
    exit 0
  fi

  if [[ "$resource" == "secret" && "$name" == "mariadb-account-invalid-password" ]]; then
    printf 'YmFkJ3Bhc3N3b3Jk'
    exit 0
  fi

  if [[ "$resource" == "secret" && "$name" == "mariadb-account-app-user-password" && "${KUBECTL_CREATE_FAIL:-0}" == "1" && "${SECRET_ALREADY_EXISTS:-0}" == "1" ]]; then
    printf 'RXhpc3RpbmdQYXNzMTIz'
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
    if [[ "${ROOT_PASSWORD_UNAVAILABLE:-0}" == "1" ]]; then
      echo "root password unavailable" >&2
      exit 1
    fi
    printf 'root-pass'
    exit 0
  fi

  last_index=$((${#command[@]} - 1))
  query="${command[$last_index]}"
  printf '%s\n' "$query" >> "${TEST_TMPDIR}/sql.log"

  case "$query" in
    SELECT\ COUNT\(\*\)\ FROM\ mysql.user*)
      if [[ "${SQL_FAIL_ACCOUNT_COUNT:-0}" == "1" ]]; then
        echo "simulated account count failure" >&2
        exit 1
      fi
      printf '%s\n' "${CREATE_ACCOUNT_COUNT:-${CREATE_ACCOUNT_EXISTS:-0}}"
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
      if [[ "${SQL_FAIL_VERIFY:-0}" == "1" ]]; then
        echo "simulated verify failure" >&2
        exit 1
      fi
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

common_args() {
  echo "--context kind-cluster-dbs \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT \
    --password-secret-name mariadb-account-app-user-password \
    --dry-run false \
    --confirm true \
    --json"
}

assert_json() {
  local field="$1" expected="$2" actual
  actual="$(printf '%s' "$output" | jq -r "$field")"
  assert_equal "$actual" "$expected"
}

@test "dry-run returns READY with a redacted SQL plan" {
  run "${SCRIPT}" \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT,INSERT \
    --password-secret-name mariadb-account-app-user-password \
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
    --password-secret-name mariadb-account-app-user-password \
    --dry-run false \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "BLOCKED" ]
  [ "$reason_code" = "CONFIRM_REQUIRED" ]
  [ ! -f "${TEST_TMPDIR}/created-secret.args" ]
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

@test "password Secret name outside the managed prefix is rejected" {
  run "${SCRIPT}" \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT \
    --password-secret-name unrelated-secret \
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
    --password-secret-name mariadb-account-app-user-password \
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
  [ -f "${TEST_TMPDIR}/created-secret.args" ]
  ! printf '%s' "$output" | grep -q 'stringData'
  ! printf '%s' "$output" | grep -q 'root-pass'
}

@test "password Secret name is derived by convention when not provided" {
  run "${SCRIPT}" \
    --context kind-cluster-dbs \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT \
    --dry-run true \
    --json

  [ "$status" -eq 0 ]
  # underscores in the username are normalised into a valid Secret name
  [ "$(printf '%s' "$output" | jq -r '.password_secret.name')" = "mariadb-account-app-user" ]
  [ "$(printf '%s' "$output" | jq -r '.password_secret.key')" = "password" ]
}

@test "secret-provided password path blocks when Secret is unreadable" {
  run "${SCRIPT}" \
    --context kind-cluster-dbs \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT \
    --password-secret-name mariadb-account-missing-password \
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
    --password-secret-name mariadb-account-app-user-password \
    --dry-run false \
    --confirm true \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "ERROR" ]
  [ "$reason_code" = "SQL_FAILED" ]
}

@test "SQL account lookup failure returns SQL_FAILED" {
  export SQL_FAIL_ACCOUNT_COUNT=1

  run "${SCRIPT}" \
    --context kind-cluster-dbs \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT \
    --password-secret-name mariadb-account-app-user-password \
    --dry-run false \
    --confirm true \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "ERROR" ]
  [ "$reason_code" = "SQL_FAILED" ]
}

@test "SQL grant failure returns SQL_FAILED" {
  export SQL_FAIL_GRANT=1

  run "${SCRIPT}" \
    --context kind-cluster-dbs \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT \
    --password-secret-name mariadb-account-app-user-password \
    --dry-run false \
    --confirm true \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "ERROR" ]
  [ "$reason_code" = "SQL_FAILED" ]
}

@test "KUBECTL_UNAVAILABLE when cluster-info fails" {
  export KUBECTL_UNAVAILABLE=1

  run "${SCRIPT}" $(common_args)

  assert_success
  assert_json '.status' 'ERROR'
  assert_json '.reason_code' 'KUBECTL_UNAVAILABLE'
}

@test "CURRENT_PRIMARY_EMPTY when no primary or pods can be determined" {
  export CURRENT_PRIMARY_EMPTY=1
  export MOCK_REPLICAS=0

  run "${SCRIPT}" $(common_args)

  assert_success
  assert_json '.status' 'ERROR'
  assert_json '.reason_code' 'CURRENT_PRIMARY_EMPTY'
}

@test "ROOT_PASSWORD_UNAVAILABLE when password cannot be read" {
  export ROOT_PASSWORD_UNAVAILABLE=1

  run "${SCRIPT}" $(common_args)

  assert_success
  assert_json '.status' 'ERROR'
  assert_json '.reason_code' 'ROOT_PASSWORD_UNAVAILABLE'
}

@test "PASSWORD_SECRET_WRITE_FAILED when generated Secret cannot be created or read" {
  export KUBECTL_CREATE_FAIL=1

  run "${SCRIPT}" $(common_args)

  assert_success
  assert_json '.status' 'ERROR'
  assert_json '.reason_code' 'PASSWORD_SECRET_WRITE_FAILED'
}

@test "PASSWORD_SECRET_INVALID when provided Secret contains unsafe password" {
  run "${SCRIPT}" \
    --context kind-cluster-dbs \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT \
    --password-secret-name mariadb-account-invalid-password \
    --generate-password false \
    --dry-run false \
    --confirm true \
    --json

  assert_success
  assert_json '.status' 'BLOCKED'
  assert_json '.reason_code' 'PASSWORD_SECRET_INVALID'
}

@test "SQL_VERIFY_FAILED when SHOW GRANTS fails after successful create" {
  export SQL_FAIL_VERIFY=1

  run "${SCRIPT}" $(common_args)

  assert_success
  assert_json '.status' 'ERROR'
  assert_json '.reason_code' 'SQL_VERIFY_FAILED'
}

@test "existing generated password Secret is reused instead of overwritten" {
  export KUBECTL_CREATE_FAIL=1
  export SECRET_ALREADY_EXISTS=1

  run "${SCRIPT}" $(common_args)

  assert_success
  assert_json '.status' 'CREATED'
  assert_json '.reason_code' 'ACCOUNT_CREATED'
  assert_json '.password_secret.managed' 'false'
}

@test "PASSWORD_SECRET_CONFLICT when the derived Secret belongs to a different account" {
  export KUBECTL_CREATE_FAIL=1        # Secret already exists
  export SECRET_ALREADY_EXISTS=1
  export MOCK_SECRET_OWNER=other_user # owned by a different account

  run "${SCRIPT}" $(common_args)

  assert_json '.status' 'BLOCKED'
  assert_json '.reason_code' 'PASSWORD_SECRET_CONFLICT'
}

@test "existing account is idempotent and does not rewrite password Secret" {
  export CREATE_ACCOUNT_EXISTS=1

  run "${SCRIPT}" \
    --context kind-cluster-dbs \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT \
    --password-secret-name mariadb-account-app-user-password \
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
  [ ! -f "${TEST_TMPDIR}/created-secret.args" ]
  ! grep -q '^GRANT' "${TEST_TMPDIR}/sql.log"
}

@test "secret-provided password path is supported" {
  run "${SCRIPT}" \
    --context kind-cluster-dbs \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT \
    --password-secret-name mariadb-account-provided-password \
    --generate-password false \
    --dry-run false \
    --confirm true \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  managed=$(printf '%s' "$output" | jq -r '.password_secret.managed')

  [ "$result_status" = "CREATED" ]
  [ "$managed" = "false" ]
  [ ! -f "${TEST_TMPDIR}/created-secret.args" ]
}
