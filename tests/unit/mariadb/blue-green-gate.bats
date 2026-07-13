#!/usr/bin/env bats
#
# Contract test for the blue/green capability gate (bg_require_bluegreen_capable,
# invoked from bg_init_target). Blue/green needs the current-generation operator
# (ExternalMariaDB + multiCluster + physical bootstrapFrom); on a legacy
# mmontes-era operator it must fail fast with an actionable "upgrade" message
# instead of a cryptic `no matches for kind` partway through bootstrap.
#
# Mock control:
#   MOCK_HAS_EXT=1  the ExternalMariaDB CRD exists (current generation)
#   MOCK_HAS_EXT=0  it does not (legacy operator)

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"
  MOCK_DIR="$(mktemp -d)"
  RESULT="${MOCK_DIR}/result.json"

  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *api-resources*)
    if [[ "${MOCK_HAS_EXT:-1}" == "1" ]]; then
      printf '%s\n' mariadbs.k8s.mariadb.com externalmariadbs.k8s.mariadb.com physicalbackups.k8s.mariadb.com
    else
      printf '%s\n' mariadbs.mariadb.mmontes.io backups.mariadb.mmontes.io restores.mariadb.mmontes.io
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/kubectl"
}

teardown() { rm -rf "${MOCK_DIR}"; }

# Run bg_init_target (which invokes the gate) in a fresh shell.
run_gate() {
  run env "PATH=${MOCK_DIR}:${PATH}" \
    "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" \
    "DB_NAMESPACE=mariadb-1" \
    "_LOG_CURRENT_LEVEL=3" \
    "$@" \
    bash -c 'source "${LIB_DIR}/mariadb-blue-green.sh"; bg_init_target; echo GATE_PASSED'
}

result_field() { jq -r "$1" "${RESULT}"; }

@test "gate passes on a current-generation operator (ExternalMariaDB present)" {
  run_gate MOCK_HAS_EXT=1
  [ "$status" -eq 0 ]
  [[ "$output" == *GATE_PASSED* ]]
}

@test "gate fails fast on a legacy operator (no ExternalMariaDB CRD)" {
  run_gate MOCK_HAS_EXT=0
  [ "$status" -ne 0 ]
  [[ "$output" != *GATE_PASSED* ]]
  [ "$(result_field '.status')" = "error" ]
  [[ "$(result_field '.message')" == *"requires the k8s.mariadb.com generation"* ]]
  [[ "$(result_field '.message')" == *"no ExternalMariaDB CRD"* ]]
  [ "$(result_field '.data.required | index("multiCluster") != null')" = "true" ]
}
