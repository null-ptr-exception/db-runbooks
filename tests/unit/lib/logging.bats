#!/usr/bin/env bats
# =============================================================================
# Unit tests for lib/logging.sh — pins the public surface so a script calling
# a log function that doesn't exist (the log_warn regression: sanity-check's
# primary-resolve retry path sprayed "log_warn: command not found") can't
# come back silently.
# =============================================================================

setup() {
  LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../../../aqsh-tasks/lib" && pwd)"
  # shellcheck disable=SC1091
  source "$LIB_DIR/logging.sh"
}

@test "every log level function used by task scripts is defined" {
  for fn in log_debug log_info log_warn log_error log_crit log_set_level; do
    declare -F "$fn" >/dev/null || {
      echo "missing function: $fn" >&2
      return 1
    }
  done
}

@test "log_warn emits a WARN line to stderr at default level" {
  run --separate-stderr log_warn "unit-test" "warn message"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"[WARN ]"* ]]
  [[ "$stderr" == *"[unit-test]"* ]]
  [[ "$stderr" == *"warn message"* ]]
}

@test "log_set_level WARN suppresses INFO but keeps WARN and ERROR" {
  log_set_level "WARN"
  run --separate-stderr log_info "unit-test" "info message"
  [ -z "$stderr" ]
  run --separate-stderr log_warn "unit-test" "warn message"
  [[ "$stderr" == *"warn message"* ]]
  run --separate-stderr log_error "unit-test" "error message"
  [[ "$stderr" == *"error message"* ]]
}

@test "level ordering: CRIT-only threshold (used by other unit suites) silences WARN" {
  # other unit suites export _LOG_CURRENT_LEVEL=4 meaning "CRIT only" —
  # keep that contract honest after the WARN renumbering
  log_set_level "CRIT"
  run --separate-stderr log_warn "unit-test" "warn message"
  [ -z "$stderr" ]
  run --separate-stderr log_error "unit-test" "error message"
  [ -z "$stderr" ]
  run --separate-stderr log_crit "unit-test" "crit message"
  [[ "$stderr" == *"crit message"* ]]
}
