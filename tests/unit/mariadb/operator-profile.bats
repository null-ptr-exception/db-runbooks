#!/usr/bin/env bats
# =============================================================================
# Unit tests for lib/mariadb-operator-profile.sh — the operator-generation /
# apiGroup detection layer. Uses a mock kubectl in $TEST_TMPDIR/bin; no cluster.
#
# Mock control env vars:
#   MOCK_API_RESOURCES  space-separated group-qualified resources returned by
#                       `kubectl api-resources -o name`. `mariadbs.<group>` is
#                       the tier-2 operator-generation detection signal.
# =============================================================================

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export _LOG_CURRENT_LEVEL=3
  LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export LIB_DIR

  # Clean slate: no config-tier override, no memoized value.
  unset MARIADB_OPERATOR_GROUP_DEFAULT _MDB_OPERATOR_GROUP
  export MOCK_API_RESOURCES=""

  mkdir -p "${TEST_TMPDIR}/bin"
  cat > "${TEST_TMPDIR}/bin/kubectl" << 'KUBECTL_EOF'
#!/usr/bin/env bash
# strip global flags injected by _kubectl_global
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context|--namespace|-n|--kubeconfig) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
flags="${args[*]}"

# API discovery is available to authenticated service accounts through the
# standard system:discovery binding; no list-all-CRDs RBAC is required.
if [[ "${args[0]:-}" == "api-resources" && "$flags" == *"-o name"* ]]; then
  requested_group=""
  for arg in "${args[@]}"; do
    case "$arg" in
      --api-group=*) requested_group="${arg#--api-group=}" ;;
    esac
  done
  for resource in ${MOCK_API_RESOURCES}; do
    if [[ -z "$requested_group" || "$resource" == *."$requested_group" ]]; then
      printf '%s\n' "$resource"
    fi
  done
  exit 0
fi

echo "mock kubectl: unexpected command: $flags" >&2
exit 1
KUBECTL_EOF
  chmod +x "${TEST_TMPDIR}/bin/kubectl"

  # shellcheck source=/dev/null
  source "${LIB_DIR}/mariadb-operator-profile.sh"
}

@test "group: tier-1 internal config wins without any kubectl call" {
  export MARIADB_OPERATOR_GROUP_DEFAULT="mariadb.mmontes.io"
  export MOCK_API_RESOURCES="mariadbs.k8s.mariadb.com"   # detection would say otherwise
  run mdb_operator_group
  [ "$status" -eq 0 ]
  [ "$output" = "mariadb.mmontes.io" ]
}

@test "group: tier-2 detects the single group serving mariadbs" {
  export MOCK_API_RESOURCES="mariadbs.mariadb.mmontes.io"
  run mdb_operator_group
  [ "$status" -eq 0 ]
  [ "$output" = "mariadb.mmontes.io" ]
}

@test "group: tier-2 detects the current generation group" {
  export MOCK_API_RESOURCES="mariadbs.k8s.mariadb.com"
  run mdb_operator_group
  [ "$output" = "k8s.mariadb.com" ]
}

@test "group: ambiguous detection (2 groups) falls through to fallback" {
  export MOCK_API_RESOURCES="mariadbs.k8s.mariadb.com mariadbs.mariadb.mmontes.io"
  run mdb_operator_group
  [ "$output" = "k8s.mariadb.com" ]   # tier-3 hardcoded fallback
}

@test "group: no detection signal falls through to fallback" {
  export MOCK_API_RESOURCES=""
  run mdb_operator_group
  [ "$output" = "k8s.mariadb.com" ]
}

@test "apiversion: is <resolved-group>/v1alpha1" {
  export MARIADB_OPERATOR_GROUP_DEFAULT="mariadb.mmontes.io"
  run mdb_operator_apiversion
  [ "$output" = "mariadb.mmontes.io/v1alpha1" ]
}

@test "has_crd: true when the CRD exists under the resolved group" {
  export MARIADB_OPERATOR_GROUP_DEFAULT="k8s.mariadb.com"
  export MOCK_API_RESOURCES="physicalbackups.k8s.mariadb.com mariadbs.k8s.mariadb.com"
  run mdb_has_crd physicalbackups
  [ "$status" -eq 0 ]
}

@test "has_crd: false when the CRD is absent (legacy operator, no PhysicalBackup)" {
  export MARIADB_OPERATOR_GROUP_DEFAULT="mariadb.mmontes.io"
  export MOCK_API_RESOURCES="backups.mariadb.mmontes.io mariadbs.mariadb.mmontes.io"
  run mdb_has_crd physicalbackups
  [ "$status" -ne 0 ]
}

@test "has_crd: queries the CRD under the *resolved* (legacy) group name" {
  # backups exists only under the legacy group; a hardcoded k8s.mariadb.com
  # query would miss it. Proves has_crd uses the resolved group.
  export MARIADB_OPERATOR_GROUP_DEFAULT="mariadb.mmontes.io"
  export MOCK_API_RESOURCES="backups.mariadb.mmontes.io"
  run mdb_has_crd backups
  [ "$status" -eq 0 ]
}
