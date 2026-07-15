#!/usr/bin/env bats

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mariadb/restart.sh"
  # These cases target a fixed "mariadb" CR; set it explicitly so the script
  # uses it directly instead of auto-detecting from the (mocked) namespace.
  export MARIADB_NAME=mariadb
  export _LOG_CURRENT_LEVEL=4
  export MOCK_STRATEGY="ReplicasFirstPrimaryLast"
  export MOCK_REPLICAS=2
  export MOCK_ABSENT=0
  export NOT_READY_POD=""
  export PATCH_FAIL=0
  export NO_ROLLOUT=0
  export METADATA_SUPPORT="podMetadata" # podMetadata | inheritMetadata | none
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

if [[ "$cmd" == "cluster-info" ]]; then
  echo "Kubernetes control plane is running"
  exit 0
fi

if [[ "$cmd" == "explain" ]]; then
  field="${args[1]:-}"
  case "${METADATA_SUPPORT:-podMetadata}:$field" in
    podMetadata:*.spec.podMetadata|inheritMetadata:*.spec.inheritMetadata)
      echo "KIND:     MariaDB"
      exit 0
      ;;
    *)
      exit 1
      ;;
  esac
fi

if [[ "$cmd" == "get" ]]; then
  resource="${args[1]:-}"
  name="${args[2]:-}"
  case "$resource" in
    statefulset|sts)
      if [[ "${MOCK_ABSENT:-0}" == "1" ]]; then printf ''; exit 0; fi
      case "$output" in
        *'metadata.name'*) printf 'mariadb' ;;
        *'.spec.replicas'*) printf '%s' "${MOCK_REPLICAS:-2}" ;;
        *) printf '' ;;
      esac
      exit 0
      ;;
    mariadb)
      if [[ "${MOCK_ABSENT:-0}" == "1" ]]; then exit 1; fi
      case "$output" in
        *'metadata.name'*) printf 'mariadb' ;;
        *'updateStrategy.type'*) printf '%s' "${MOCK_STRATEGY}" ;;
        *'.spec.replicas'*) printf '%s' "${MOCK_REPLICAS:-2}" ;;
        *) printf '{}' ;;
      esac
      exit 0
      ;;
    pod)
      case "$output" in
        *'metadata.uid'*)
          if [[ -f "${TEST_TMPDIR}/patched" && "${NO_ROLLOUT:-0}" != "1" ]]; then
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
      printf ''
      exit 0
      ;;
  esac
fi

if [[ "$cmd" == "patch" ]]; then
  resource="${args[1]:-}"
  name="${args[2]:-}"
  if [[ "$resource" != "mariadb" || "$name" != "mariadb" ]]; then
    echo "unexpected patch target: ${args[*]}" >&2
    exit 1
  fi
  if [[ "${PATCH_FAIL:-0}" == "1" ]]; then
    echo "patch forbidden" >&2
    exit 1
  fi
  printf '%s\n' "$output" > "${TEST_TMPDIR}/patch-args"
  touch "${TEST_TMPDIR}/patched"
  echo 'mariadb.k8s.mariadb.com/mariadb patched'
  exit 0
fi

if [[ "$cmd" == "delete" ]]; then
  echo "delete pod must not be used by operator-driven restart" >&2
  exit 1
fi

echo "unexpected kubectl invocation: ${args[*]}" >&2
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/kubectl"
}

@test "dry-run reports operator-controlled annotation patch and changes nothing" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  changed=$(printf '%s' "$output" | jq -r '.changed')
  operator_controlled=$(printf '%s' "$output" | jq -r '.operator_controlled')
  annotation_key=$(printf '%s' "$output" | jq -r '.annotation.key')
  metadata_field=$(printf '%s' "$output" | jq -r '.annotation.metadata_field')

  [ "$result_status" = "READY" ]
  [ "$reason_code" = "RESTART_DRY_RUN" ]
  [ "$changed" = "false" ]
  [ "$operator_controlled" = "true" ]
  [ "$metadata_field" = "podMetadata" ]
  [ "$annotation_key" = "aqsh.null-ptr-exception.dev/restarted-at" ]
  [ ! -f "${TEST_TMPDIR}/patched" ]
}

@test "restart requires confirm when dry-run is false" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --dry-run false --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "BLOCKED" ]
  [ "$reason_code" = "RESTART_CONFIRM_REQUIRED" ]
  [ ! -f "${TEST_TMPDIR}/patched" ]
}

@test "confirmed restart patches the MariaDB CR and waits for operator rollout" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 \
    --dry-run false --confirm true --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  changed=$(printf '%s' "$output" | jq -r '.changed')
  restarted=$(printf '%s' "$output" | jq -rc '[.pods[] | select(.restarted)] | map(.name)')

  [ "$result_status" = "RESTARTED" ]
  [ "$reason_code" = "RESTART_COMPLETED" ]
  [ "$changed" = "true" ]
  [ "$restarted" = '["mariadb-0","mariadb-1"]' ]
  [ -f "${TEST_TMPDIR}/patched" ]
  run grep -F "spec" "${TEST_TMPDIR}/patch-args"
  [ "$status" -eq 0 ]
  run grep -F "podMetadata" "${TEST_TMPDIR}/patch-args"
  [ "$status" -eq 0 ]
}

@test "custom annotation key is passed to the MariaDB CR patch" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 \
    --annotation-key runbooks.example/restarted-at \
    --dry-run false --confirm true --json

  [ "$status" -eq 0 ]
  annotation_key=$(printf '%s' "$output" | jq -r '.annotation.key')
  [ "$annotation_key" = "runbooks.example/restarted-at" ]
  run grep -F "runbooks.example/restarted-at" "${TEST_TMPDIR}/patch-args"
  [ "$status" -eq 0 ]
}

@test "old CRD fallback patches inheritMetadata when podMetadata is unavailable" {
  export METADATA_SUPPORT="inheritMetadata"
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 \
    --dry-run false --confirm true --json

  [ "$status" -eq 0 ]
  metadata_field=$(printf '%s' "$output" | jq -r '.annotation.metadata_field')
  result_status=$(printf '%s' "$output" | jq -r '.status')

  [ "$result_status" = "RESTARTED" ]
  [ "$metadata_field" = "inheritMetadata" ]
  run grep -F "inheritMetadata" "${TEST_TMPDIR}/patch-args"
  [ "$status" -eq 0 ]
}

@test "unsupported old CRD blocks before patching" {
  export METADATA_SUPPORT="none"
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 \
    --dry-run false --confirm true --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "BLOCKED" ]
  [ "$reason_code" = "RESTART_METADATA_FIELD_UNSUPPORTED" ]
  [ ! -f "${TEST_TMPDIR}/patched" ]
}

@test "invalid metadata field is rejected" {
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 \
    --metadata-field nope --dry-run false --confirm true --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "BLOCKED" ]
  [ "$reason_code" = "RESTART_METADATA_FIELD_INVALID" ]
  [ ! -f "${TEST_TMPDIR}/patched" ]
}

@test "missing MariaDB CR blocks because operator control is required" {
  export MOCK_ABSENT=1
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "BLOCKED" ]
  [ "$reason_code" = "MARIADB_OPERATOR_REQUIRED" ]
}

@test "not-Ready pod blocks before patching the operator resource" {
  export NOT_READY_POD="mariadb-1"
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result_status" = "BLOCKED" ]
  [ "$reason_code" = "POD_NOT_READY" ]
  [ ! -f "${TEST_TMPDIR}/patched" ]
}

@test "patch failure returns structured ERROR JSON" {
  export PATCH_FAIL=1
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 \
    --dry-run false --confirm true --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  changed=$(printf '%s' "$output" | jq -r '.changed')

  [ "$result_status" = "ERROR" ]
  [ "$reason_code" = "RESTART_PATCH_FAILED" ]
  [ "$changed" = "false" ]
}


@test "operator rollout timeout reports partial state after the patch" {
  export NO_ROLLOUT=1
  run "${SCRIPT}" --context kind-cluster-dbs --namespace mariadb-1 \
    --dry-run false --confirm true --wait-timeout 1 --json

  [ "$status" -eq 0 ]
  result_status=$(printf '%s' "$output" | jq -r '.status')
  reason_code=$(printf '%s' "$output" | jq -r '.reason_code')
  changed=$(printf '%s' "$output" | jq -r '.changed')

  [ "$result_status" = "ERROR" ]
  [ "$reason_code" = "OPERATOR_RESTART_TIMEOUT" ]
  [ "$changed" = "true" ]
}
