#!/usr/bin/env bats
setup() {
  export CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$1" in
  ps) printf 'owned-stopped-id\n' ;;
  rm) exit "${REMOVE_RC:-0}" ;;
  *) exit 99 ;;
esac
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
}
@test "orphan cleanup only selects stopped labeled containers without force removal" {
  run bash "$BATS_TEST_DIRNAME/../../../scripts/local-e2e/cleanup-stopped.sh"
  [ "$status" -eq 0 ]
  grep -Fx 'ps -aq --filter label=db-runbooks.local-e2e=true --filter status=exited --filter status=dead' "$CALLS"
  grep -Fx 'rm -v owned-stopped-id' "$CALLS"
  ! grep -q -- '-f ' "$CALLS"
}
@test "orphan cleanup reports failure if a container cannot be removed" {
  run env REMOVE_RC=1 bash "$BATS_TEST_DIRNAME/../../../scripts/local-e2e/cleanup-stopped.sh"
  [ "$status" -eq 1 ]
}
@test "watchdog rejects invalid durations before starting any timer" {
  run env LOCAL_E2E_MAX_SECONDS=invalid sh "$BATS_TEST_DIRNAME/../../../scripts/local-e2e/ttl-entrypoint.sh"
  [ "$status" -eq 2 ]
}
