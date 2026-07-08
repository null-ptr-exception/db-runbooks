#!/usr/bin/env bats
# =============================================================================
# Unit tests for lib/mariadb-operator-profile.sh — the operator-generation /
# apiGroup detection layer. Uses a mock kubectl in $TEST_TMPDIR/bin; no cluster.
#
# Mock control env vars:
#   MOCK_MARIADBS_GROUPS  newline/space-separated CRD groups that serve the
#                         `mariadbs` kind (the tier-2 detection signal)
#   MOCK_PRESENT_CRDS     space-separated full CRD names (<plural>.<group>) that
#                         `kubectl get crd <name>` should find (0); others → 1
# =============================================================================

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export _LOG_CURRENT_LEVEL=3
  LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export LIB_DIR

  # Clean slate: no config-tier override, no memoized value.
  unset MARIADB_OPERATOR_GROUP_DEFAULT _MDB_OPERATOR_GROUP
  export MOCK_MARIADBS_GROUPS=""
  export MOCK_PRESENT_CRDS=""

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

# `get crd -o jsonpath=...mariadbs...` → the tier-2 group-detection query
if [[ "$flags" == *"get crd"* && "$flags" == *jsonpath* && "$flags" == *mariadbs* ]]; then
  for g in ${MOCK_MARIADBS_GROUPS}; do printf '%s\n' "$g"; done
  exit 0
fi

# `get crd <plural>.<group>` (no jsonpath) → CRD existence probe
if [[ "${args[0]:-}" == "get" && "${args[1]:-}" == "crd" && -n "${args[2]:-}" && "$flags" != *jsonpath* ]]; then
  name="${args[2]}"
  for c in ${MOCK_PRESENT_CRDS}; do
    [[ "$c" == "$name" ]] && exit 0
  done
  echo "Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io \"${name}\" not found" >&2
  exit 1
fi
exit 0
KUBECTL_EOF
  chmod +x "${TEST_TMPDIR}/bin/kubectl"

  # shellcheck source=/dev/null
  source "${LIB_DIR}/mariadb-operator-profile.sh"
}

@test "group: tier-1 internal config wins without any kubectl call" {
  export MARIADB_OPERATOR_GROUP_DEFAULT="mariadb.mmontes.io"
  export MOCK_MARIADBS_GROUPS="k8s.mariadb.com"   # detection would say otherwise
  run mdb_operator_group
  [ "$status" -eq 0 ]
  [ "$output" = "mariadb.mmontes.io" ]
}

@test "group: tier-2 detects the single group serving mariadbs" {
  export MOCK_MARIADBS_GROUPS="mariadb.mmontes.io"
  run mdb_operator_group
  [ "$status" -eq 0 ]
  [ "$output" = "mariadb.mmontes.io" ]
}

@test "group: tier-2 detects the current generation group" {
  export MOCK_MARIADBS_GROUPS="k8s.mariadb.com"
  run mdb_operator_group
  [ "$output" = "k8s.mariadb.com" ]
}

@test "group: ambiguous detection (2 groups) falls through to fallback" {
  export MOCK_MARIADBS_GROUPS="k8s.mariadb.com mariadb.mmontes.io"
  run mdb_operator_group
  [ "$output" = "k8s.mariadb.com" ]   # tier-3 hardcoded fallback
}

@test "group: no detection signal falls through to fallback" {
  export MOCK_MARIADBS_GROUPS=""
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
  export MOCK_PRESENT_CRDS="physicalbackups.k8s.mariadb.com mariadbs.k8s.mariadb.com"
  run mdb_has_crd physicalbackups
  [ "$status" -eq 0 ]
}

@test "has_crd: false when the CRD is absent (legacy operator, no PhysicalBackup)" {
  export MARIADB_OPERATOR_GROUP_DEFAULT="mariadb.mmontes.io"
  export MOCK_PRESENT_CRDS="backups.mariadb.mmontes.io mariadbs.mariadb.mmontes.io"
  run mdb_has_crd physicalbackups
  [ "$status" -ne 0 ]
}

@test "has_crd: queries the CRD under the *resolved* (legacy) group name" {
  # backups exists only under the legacy group; a hardcoded k8s.mariadb.com
  # query would miss it. Proves has_crd uses the resolved group.
  export MARIADB_OPERATOR_GROUP_DEFAULT="mariadb.mmontes.io"
  export MOCK_PRESENT_CRDS="backups.mariadb.mmontes.io"
  run mdb_has_crd backups
  [ "$status" -eq 0 ]
}
