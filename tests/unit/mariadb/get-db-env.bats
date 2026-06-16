#!/usr/bin/env bats

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mariadb/get-db-env.sh"
  export _LOG_CURRENT_LEVEL=3
  unset MARIADB_NAME MARIADB_STS_NAME || true
  mkdir -p "${TEST_TMPDIR}/bin"

  # Default mock values for env vars fetched via printenv.
  export MOCK_ENV_MARIADB_ROOT_PASSWORD="secret-root-pass"
  export MOCK_ENV_MARIADB_DATABASE="mydb"

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

if [[ "$cmd" == "get" ]]; then
  resource="${args[1]:-}"
  name="${args[2]:-}"
  output="${args[*]}"

  # List form used by auto-detect: get <resource> -o jsonpath=...items[*]...
  if [[ "$output" == *'items[*]'* ]]; then
    if [[ "$resource" == "mariadb" ]]; then
      printf '%s' "${KUBECTL_CR_NAMES:-}" | tr ' ' '\n' | sed '/^$/d'
    elif [[ "$resource" == "statefulset" ]]; then
      printf '%s' "${KUBECTL_STS_NAMES:-}" | tr ' ' '\n' | sed '/^$/d'
    fi
    exit 0
  fi

  if [[ "$resource" == "mariadb" && "${KUBECTL_NO_CR:-false}" == "true" ]]; then
    exit 1
  fi

  if [[ "$resource" == "mariadb" && -n "$name" && "$name" != "-o" ]]; then
    cat <<'JSON'
{"spec":{"replicas":1},"status":{"currentPrimary":"mariadb-0","currentPrimaryPodIndex":0,"conditions":[{"type":"Ready","status":"True"}]}}
JSON
    exit 0
  fi

  if [[ "$resource" == "statefulset" && -n "$name" && "$name" != "-o" ]]; then
    cat <<'JSON'
{"spec":{"replicas":1,"updateStrategy":{"type":"RollingUpdate"}},"status":{"readyReplicas":1,"observedGeneration":1}}
JSON
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

  if [[ "${command[0]:-}" == "printenv" && "${#command[@]}" -gt 1 ]]; then
    var_name="${command[1]}"
    mock_key="MOCK_ENV_${var_name}"
    # Exit 1 (unset) when the MOCK_ENV_<VAR> shell variable is not exported.
    if [[ -z "${!mock_key+x}" ]]; then
      exit 1
    fi
    printf '%s' "${!mock_key}"
    exit 0
  fi
fi

echo "unexpected kubectl invocation: ${args[*]}" >&2
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/kubectl"
}

@test "retrieves a single env var" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs MARIADB_ROOT_PASSWORD --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  value=$(printf '%s' "$output" | jq -r '.vars.MARIADB_ROOT_PASSWORD')

  [ "$result_status" = "OK" ]
  [ "$reason_code" = "GET_DB_ENV_OK" ]
  [ "$value" = "secret-root-pass" ]
}

@test "retrieves multiple env vars from a comma-separated list" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs MARIADB_ROOT_PASSWORD,MARIADB_DATABASE --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  pass_val=$(printf '%s' "$output" | jq -r '.vars.MARIADB_ROOT_PASSWORD')
  db_val=$(printf '%s' "$output" | jq -r '.vars.MARIADB_DATABASE')

  [ "$result_status" = "OK" ]
  [ "$pass_val" = "secret-root-pass" ]
  [ "$db_val" = "mydb" ]
}

@test "returns null for an unset env var" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs MARIADB_ROOT_PASSWORD,DOES_NOT_EXIST --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "OK" ]
  [ "$(printf '%s' "$output" | jq -r '.vars.MARIADB_ROOT_PASSWORD')" = "secret-root-pass" ]
  [ "$(printf '%s' "$output" | jq -r '.vars.DOES_NOT_EXIST')" = "null" ]
}

@test "target pod is included in the result" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 --mdb mariadb \
    --envs MARIADB_ROOT_PASSWORD --json

  [ "$status" -eq 0 ]
  pod=$(printf '%s' "$output" | jq -r '.target.pod')
  [ "$pod" = "mariadb-0" ]
}

@test "auto-detects the MariaDB CR when --mdb is omitted" {
  export KUBECTL_CR_NAMES="mdb-v24"

  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 \
    --envs MARIADB_ROOT_PASSWORD --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "OK" ]
  [ "$(printf '%s' "$output" | jq -r '.target.mdb')" = "mdb-v24" ]
}

@test "auto-detects a StatefulSet when no CR exists" {
  export KUBECTL_CR_NAMES=""
  export KUBECTL_STS_NAMES="legacy-mdb"
  export KUBECTL_NO_CR=true

  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 \
    --envs MARIADB_ROOT_PASSWORD --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.target.mdb')" = "legacy-mdb" ]
}

@test "reports MARIADB_AMBIGUOUS when several CRs exist and --mdb is omitted" {
  export KUBECTL_CR_NAMES="alpha beta"

  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 \
    --envs MARIADB_ROOT_PASSWORD --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "MARIADB_AMBIGUOUS" ]
  [ "$(printf '%s' "$output" | jq -r '.candidates | join(",")')" = "alpha,beta" ]
  [ "$(printf '%s' "$output" | jq -r '.target.mdb')" = "null" ]
}

@test "reports MARIADB_NOT_FOUND when no CR or StatefulSet exists" {
  export KUBECTL_CR_NAMES=""
  export KUBECTL_STS_NAMES=""

  run "${SCRIPT}" --context kind-cluster-dbs --namespace db-1 \
    --envs MARIADB_ROOT_PASSWORD --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "MARIADB_NOT_FOUND" ]
}

@test "exits 2 when --namespace is missing" {
  run "${SCRIPT}" --mdb mariadb --envs MARIADB_ROOT_PASSWORD --json
  [ "$status" -eq 2 ]
}

@test "exits 2 when --envs is missing" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --json
  [ "$status" -eq 2 ]
}
