#!/usr/bin/env bats

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mariadb/restart.sh"
  export _LOG_CURRENT_LEVEL=3
  # Default mock behaviour; individual tests override these before `run`.
  export MOCK_MODE="operator"      # operator | native
  export MOCK_STRATEGY="OnDelete"  # statefulset .spec.updateStrategy.type
  export MOCK_REPLICAS=2           # .spec.replicas
  export MOCK_ABSENT=0             # 1 => no StatefulSet / CR / pods
  export ROLE_CHANGE_SIM=0         # 1 => a pod delete promotes mariadb-1
  export NO_ROOT_PASSWORD=0        # 1 => printenv returns no root password
  export NOT_READY_POD=""          # a pod name that never reports Ready
  export DELETE_FAIL=0             # 1 => kubectl delete pod fails before changes
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
output="${args[*]}"

current_primary() {
  if [[ "${ROLE_CHANGE_SIM:-0}" == "1" && -f "${TEST_TMPDIR}/role_changed" ]]; then
    printf 'mariadb-1'
  else
    printf 'mariadb-0'
  fi
}

if [[ "$cmd" == "cluster-info" ]]; then
  echo "Kubernetes control plane is running"
  exit 0
fi

if [[ "$cmd" == "get" ]]; then
  resource="${args[1]:-}"
  name="${args[2]:-}"
  case "$resource" in
    statefulset|sts)
      if [[ "${MOCK_ABSENT:-0}" == "1" ]]; then printf ''; exit 0; fi
      case "$output" in
        *'updateStrategy.type'*) printf '%s' "${MOCK_STRATEGY}" ;;
        *'metadata.name'*) printf 'mariadb' ;;
        *'.spec.replicas'*) printf '%s' "${MOCK_REPLICAS:-2}" ;;
        *) printf '' ;;
      esac
      exit 0
      ;;
    mariadb)
      # Native mode and "absent" mode have no MariaDB CR.
      if [[ "${MOCK_MODE}" == "native" || "${MOCK_ABSENT:-0}" == "1" ]]; then exit 1; fi
      case "$output" in
        *'currentPrimaryPodIndex'*) printf '0' ;;
        *'currentPrimary'*) current_primary ;;
        *'.spec.replicas'*) printf '%s' "${MOCK_REPLICAS:-2}" ;;
        *) printf '{}' ;;
      esac
      exit 0
      ;;
    pod)
      case "$output" in
        *'metadata.uid'*)
          # UID flips after the pod is deleted, modelling recreation.
          if [[ -f "${TEST_TMPDIR}/deleted-${name}" ]]; then
            printf 'uid-new-%s' "$name"
          else
            printf 'uid-old-%s' "$name"
          fi
          ;;
        *'containerStatuses'*|*'.ready'*)
          if [[ "${NOT_READY_POD:-}" == "$name" ]]; then printf 'false'; else printf 'true'; fi
          ;;
        *) printf '' ;;
      esac
      exit 0
      ;;
    pods)
      # Label-selector fallback list (only hit when replicas are unknown).
      printf ''
      exit 0
      ;;
  esac
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
    if [[ "${NO_ROOT_PASSWORD:-0}" == "1" ]]; then printf ''; exit 0; fi
    printf 'root-pass'
    exit 0
  fi

  last_index=$((${#command[@]} - 1))
  query="${command[$last_index]}"
  case "$query" in
    'SELECT 1') printf '1\n' ;;
    'SELECT @@read_only')
      if [[ "$pod" == "$(current_primary)" ]]; then
        printf '0\n'
      else
        printf '1\n'
      fi
      ;;
    *) printf '' ;;
  esac
  exit 0
fi

if [[ "$cmd" == "delete" ]]; then
  if [[ "${DELETE_FAIL:-0}" == "1" ]]; then
    echo "delete forbidden" >&2
    exit 1
  fi
  target="${args[2]:-}"
  if [[ -n "$target" ]]; then touch "${TEST_TMPDIR}/deleted-${target}"; fi
  if [[ "${ROLE_CHANGE_SIM:-0}" == "1" ]]; then touch "${TEST_TMPDIR}/role_changed"; fi
  exit 0
fi

echo "unexpected kubectl invocation: ${args[*]}" >&2
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/kubectl"
}

@test "dry-run plans replica-only restart and changes nothing" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  changed=$(printf '%s' "$output" | jq -r '.changed')
  order=$(printf '%s' "$output" | jq -rc '.restart_order')
  primary_before=$(printf '%s' "$output" | jq -r '.primary_before')

  [ "$result_status" = "READY" ]
  [ "$reason_code" = "RESTART_DRY_RUN" ]
  [ "$changed" = "false" ]
  [ "$order" = '["mariadb-1"]' ]
  [ "$primary_before" = "mariadb-0" ]
}

@test "restart requires confirm when dry-run is false" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --dry-run false --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "BLOCKED" ]
  [ "$reason_code" = "RESTART_CONFIRM_REQUIRED" ]
}

@test "include-primary appends the primary last in the plan" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --include-primary true --json

  [ "$status" -eq 0 ]
  order=$(printf '%s' "$output" | jq -rc '.restart_order')
  [ "$order" = '["mariadb-1","mariadb-0"]' ]
}

@test "restarting the primary is blocked without include-primary" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --target-pod mariadb-0 --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "BLOCKED" ]
  [ "$reason_code" = "PRIMARY_RESTART_NOT_ALLOWED" ]
}

@test "unknown target pod returns a structured blocked result" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --target-pod mariadb-9 --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "BLOCKED" ]
  [ "$reason_code" = "TARGET_POD_NOT_FOUND" ]
}

@test "native StatefulSet mode resolves primary via SQL and plans dry-run" {
  export MOCK_MODE="native"
  export MOCK_STRATEGY="RollingUpdate"
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  order=$(printf '%s' "$output" | jq -rc '.restart_order')
  update_strategy=$(printf '%s' "$output" | jq -r '.target.update_strategy')

  [ "$result_status" = "READY" ]
  [ "$reason_code" = "RESTART_DRY_RUN" ]
  [ "$order" = '["mariadb-1"]' ]
  [ "$update_strategy" = "RollingUpdate" ]
}

@test "confirmed restart cycles replicas and reports completion" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 \
    --dry-run false --confirm true --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  changed=$(printf '%s' "$output" | jq -r '.changed')
  restarted=$(printf '%s' "$output" | jq -rc '[.pods[] | select(.restarted)] | map(.name)')
  primary_after=$(printf '%s' "$output" | jq -r '.primary_after')

  [ "$result_status" = "RESTARTED" ]
  [ "$reason_code" = "RESTART_COMPLETED" ]
  [ "$changed" = "true" ]
  [ "$restarted" = '["mariadb-1"]' ]
  [ "$primary_after" = "mariadb-0" ]
}

@test "primary role move during restart is treated as an error" {
  export ROLE_CHANGE_SIM=1
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 \
    --include-primary true --dry-run false --confirm true --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "ERROR" ]
  [ "$reason_code" = "ROLE_CHANGED" ]
}

@test "role move is tolerated when allow-role-change is set" {
  export ROLE_CHANGE_SIM=1
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 \
    --include-primary true --allow-role-change true --dry-run false --confirm true --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "WARN" ]
  [ "$reason_code" = "ROLE_CHANGED" ]
}

# --- Conservative guards (the whole point of the rewrite) --------------------

@test "unknown primary blocks the default restart instead of cycling everything" {
  # Native mode with no root password => primary cannot be resolved at all.
  export MOCK_MODE="native"
  export MOCK_STRATEGY="RollingUpdate"
  export NO_ROOT_PASSWORD=1
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  order=$(printf '%s' "$output" | jq -rc '.restart_order')

  [ "$result_status" = "BLOCKED" ]
  [ "$reason_code" = "PRIMARY_UNKNOWN" ]
  # Must NOT have planned to restart any pod.
  [ "$order" = '[]' ]
}

@test "a not-Ready peer pod blocks the restart" {
  export NOT_READY_POD="mariadb-0"   # primary (a peer of the replica target) is down
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --target-pod mariadb-1 --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "BLOCKED" ]
  [ "$reason_code" = "PEER_POD_NOT_READY" ]
}

@test "single-pod cluster with only a primary yields no restart targets" {
  export MOCK_REPLICAS=1   # only mariadb-0, which is the primary
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "BLOCKED" ]
  [ "$reason_code" = "NO_RESTART_TARGETS" ]
}

@test "missing MariaDB returns a structured blocked result" {
  export MOCK_ABSENT=1
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "BLOCKED" ]
  [ "$reason_code" = "MARIADB_NOT_FOUND" ]
}

@test "a pod that never becomes Ready halts with an error" {
  export NOT_READY_POD="mariadb-1"   # the replica we restart never comes back Ready
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 \
    --target-pod mariadb-1 --dry-run false --confirm true --wait-timeout 1 --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  changed=$(printf '%s' "$output" | jq -r '.changed')

  [ "$result_status" = "ERROR" ]
  [ "$reason_code" = "RESTART_POD_NOT_READY" ]
  [ "$changed" = "true" ]
}

@test "delete failure reports RESTART_DELETE_FAILED before marking pod restarted" {
  export DELETE_FAIL=1
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 \
    --target-pod mariadb-1 --dry-run false --confirm true --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  changed=$(printf '%s' "$output" | jq -r '.changed')
  restarted=$(printf '%s' "$output" | jq -rc '[.pods[] | select(.restarted)] | map(.name)')

  [ "$result_status" = "ERROR" ]
  [ "$reason_code" = "RESTART_DELETE_FAILED" ]
  [ "$changed" = "false" ]
  [ "$restarted" = '[]' ]
}
