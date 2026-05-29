#!/usr/bin/env bats

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mariadb/status.sh"
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
  output="${args[*]}"

  if [[ "$resource" == "mariadb" && "${KUBECTL_NO_CR:-false}" == "true" ]]; then
    exit 1
  fi

  if [[ "$resource" == "mariadb" && "$name" == "mariadb" ]]; then
    cat <<'JSON'
{"spec":{"replicas":2},"status":{"currentPrimary":"mariadb-0","currentPrimaryPodIndex":0,"conditions":[{"type":"Ready","status":"True"}]}}
JSON
    exit 0
  fi

  if [[ "$resource" == "statefulset" && "$name" == "mariadb" ]]; then
    cat <<'JSON'
{"spec":{"replicas":2,"updateStrategy":{"type":"RollingUpdate"}},"status":{"readyReplicas":2,"observedGeneration":7}}
JSON
    exit 0
  fi

  if [[ "$resource" == "pod" ]]; then
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
      *)
        printf '{}'
        ;;
    esac
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

  if [[ "${command[*]}" == "printenv MARIADB_ROOT_PASSWORD" ]]; then
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
      if [[ "$pod" == "mariadb-0" ]]; then
        printf '0\n'
      else
        printf '1\n'
      fi
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

@test "status reports operator and pod summary" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --resource mariadb --mdb mariadb --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  cr_present=$(printf '%s' "$output" | jq -r '.operator.present')
  pod_count=$(printf '%s' "$output" | jq -r '.pods | length')
  primary_role=$(printf '%s' "$output" | jq -r '.pods[] | select(.name == "mariadb-0") | .role')

  [ "$result_status" = "OK" ]
  [ "$reason_code" = "MARIADB_STATUS_OK" ]
  [ "$cr_present" = "true" ]
  [ "$pod_count" -eq 2 ]
  [ "$primary_role" = "primary" ]
}

@test "native status works when operator CR is absent" {
  export KUBECTL_NO_CR=true

  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --resource mariadb --mdb mariadb --skip-sql --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  cr_present=$(printf '%s' "$output" | jq -r '.operator.present')
  sts_present=$(printf '%s' "$output" | jq -r '.statefulset.present')
  pod_count=$(printf '%s' "$output" | jq -r '.pods | length')

  [ "$result_status" = "OK" ]
  [ "$cr_present" = "false" ]
  [ "$sts_present" = "true" ]
  [ "$pod_count" -eq 2 ]
}
