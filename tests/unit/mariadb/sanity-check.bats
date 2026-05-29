#!/usr/bin/env bats

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mariadb/sanity-check.sh"
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

if [[ "$cmd" == "get" ]]; then
  resource="${args[1]:-}"
  name="${args[2]:-}"

  if [[ "$resource" == "mariadb" && "$name" == "missing" ]]; then
    echo "Error from server (NotFound): mariadbs.k8s.mariadb.com \"missing\" not found" >&2
    exit 1
  fi

  if [[ "$resource" == "mariadb" && "$name" == "mariadb" ]]; then
    output="${args[*]}"
    case "$output" in
      *'.status.conditions[?(@.type=="Ready")].status'*)
        printf 'True'
        ;;
      *'.status.currentPrimaryPodIndex'*)
        printf '0'
        ;;
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

  if [[ "$resource" == "pod" && "$name" == "mariadb-0" ]]; then
    output="${args[*]}"
    case "$output" in
      *'.status.phase'*)
        printf 'Running'
        ;;
      *'.ready'*)
        printf 'true'
        ;;
      *'.restartCount'*)
        printf '0'
        ;;
      *'.state.waiting.reason'*)
        printf ''
        ;;
      *)
        printf '{}'
        ;;
    esac
    exit 0
  fi

  if [[ "$resource" == "service" && "$name" == "mariadb-primary" ]]; then
    output="${args[*]}"
    case "$output" in
      *'statefulset'*'pod-name'*)
        printf 'mariadb-0'
        ;;
      *'.spec.selector.pod-name'*)
        printf ''
        ;;
      *)
        printf '{}'
        ;;
    esac
    exit 0
  fi

  if [[ "$resource" == "statefulset" && "$name" == "mariadb" ]]; then
    printf '%s' "${KUBECTL_STS_REPLICAS:-1}"
    exit 0
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
  case "$query" in
    'SELECT 1')
      printf '1\n'
      ;;
    'SELECT @@read_only')
      printf '0\n'
      ;;
    'SELECT @@gtid_binlog_pos')
      printf '0-1-10\n'
      ;;
    "SHOW STATUS LIKE 'Threads_connected'")
      printf 'Threads_connected\t1\n'
      ;;
    'SELECT @@max_connections')
      printf '100\n'
      ;;
    *'FROM information_schema.innodb_trx'*)
      printf '0\n'
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

@test "local JSON output passes for a single-pod MariaDB target" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --resource mariadb --mdb mariadb --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  check_count=$(printf '%s' "$output" | jq -r '.checks | length')

  [ "$result_status" = "PASS" ]
  [ "$reason_code" = "SANITY_PASS" ]
  [ "$check_count" -gt 0 ]
}

@test "missing MariaDB CR returns structured ERROR JSON" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --resource mariadb --mdb missing --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "ERROR" ]
  [ "$reason_code" = "CR_NOT_FOUND" ]
}

@test "native StatefulSet mode can run SQL checks without operator CR" {
  export KUBECTL_STS_REPLICAS=3

  run "${SCRIPT}" \
    --context kind-cluster-dbs \
    --namespace mariadb-1 \
    --resource mariadb \
    --mdb mariadb \
    --skip-operator \
    --skip-pods \
    --skip-service \
    --skip-replication \
    --skip-semi-sync \
    --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  inferred_primary=$(printf '%s' "$output" | jq -r '.checks[] | select(.reason_code == "CURRENT_PRIMARY_INFERRED") | .pod')

  [ "$result_status" = "PASS" ]
  [ "$reason_code" = "SANITY_PASS" ]
  [ "$inferred_primary" = "mariadb-0" ]
}
