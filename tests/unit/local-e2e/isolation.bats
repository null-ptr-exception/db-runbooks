#!/usr/bin/env bats

setup() {
  RUNNER="$BATS_TEST_DIRNAME/../../../scripts/local-e2e/run.sh"
  export MOCK_DOCKER_LOG="$BATS_TEST_TMPDIR/docker.calls"
  export TMPDIR="$BATS_TEST_TMPDIR"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"
case "$1" in
  ps) ;;
  build)
    shift
    while (($#)); do
      if [[ "$1" == --iidfile ]]; then printf 'sha256:test-tools' > "$2"; break; fi
      shift
    done
    ;;
  run)
    [[ "${MOCK_CREATE_FAIL:-0}" == 0 ]] || exit 17
    printf 'test-container-id\n'
    ;;
  exec)
    if [[ "$*" == *'timeout 5 docker info' ]]; then exit "${MOCK_DAEMON_FAIL:-0}"; fi
    if [[ "$2" == -i ]]; then cat >/dev/null; else exit "${MOCK_E2E_EXIT:-0}"; fi
    ;;
  inspect)
    if [[ "${MOCK_DAEMON_FAIL:-0}" == 0 ]]; then printf 'true\n'; else printf 'false\n'; fi
    ;;
  logs) printf 'test daemon log\n' ;;
  cp) printf '1..1\nok 1 fake lifecycle\n' > "${@: -1}" ;;
  rm) [[ "${MOCK_REMOVE_FAIL:-0}" == 0 ]] || exit 19 ;;
  *) echo "unexpected Docker command: $*" >&2; exit 99 ;;
esac
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
}

@test "local E2E gives each invocation a different daemon and cleans only that daemon" {
  run bash "$RUNNER"
  [ "$status" -eq 0 ]
  run bash "$RUNNER"
  [ "$status" -eq 0 ]
  local names
  names="$(awk '/^run / {for(i=1;i<=NF;i++) if($i=="--name") print $(i+1)}' "$MOCK_DOCKER_LOG")"
  [ "$(printf '%s\n' "$names" | sort -u | wc -l | tr -d ' ')" -eq 2 ]
  while IFS= read -r name; do
    grep -Fx "rm -f -v $name" "$MOCK_DOCKER_LOG"
  done <<<"$names"
  # No host mounts, published ports, host network, or broad prune operation.
  ! grep -E -- '(^| )(--volume|-v|--mount|--publish|-p|--network=host|prune)( |$)' <(grep '^run ' "$MOCK_DOCKER_LOG")
  grep -F -- 'dockerd --host=unix:///var/run/docker.sock' "$MOCK_DOCKER_LOG"
}

@test "local E2E propagates the Bats failure through tee and still cleans its daemon" {
  run env MOCK_E2E_EXIT=23 bash "$RUNNER"
  [ "$status" -eq 23 ]
  grep -E '^rm -f -v db-runbooks-e2e-' "$MOCK_DOCKER_LOG"
  [[ "$output" == *'Local E2E exit=23; artifacts:'* ]]
}

@test "local E2E never removes a container if its creation failed" {
  run env MOCK_CREATE_FAIL=1 bash "$RUNNER"
  [ "$status" -eq 17 ]
  ! grep -q '^rm ' "$MOCK_DOCKER_LOG"
}

@test "local E2E does not report success when its daemon cannot be removed" {
  run env MOCK_REMOVE_FAIL=1 bash "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *'Failed to remove isolated E2E container:'* ]]
}

@test "local E2E stops before copying the fixture when the daemon fails startup" {
  run env MOCK_DAEMON_FAIL=1 bash "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *'Isolated Docker daemon failed to become ready'* ]]
  ! grep -q '^exec -i ' "$MOCK_DOCKER_LOG"
  grep -E '^rm -f -v db-runbooks-e2e-' "$MOCK_DOCKER_LOG"
}
