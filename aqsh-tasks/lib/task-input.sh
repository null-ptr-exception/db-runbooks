#!/usr/bin/env bash
# =============================================================================
# lib/task-input.sh
# Small helpers shared by task entrypoints for CLI validation and JSON values.
# =============================================================================

[[ -n "${_TASK_INPUT_LIB_LOADED:-}" ]] && return 0
_TASK_INPUT_LIB_LOADED=1

task_require_value() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo "error: $1 requires a value" >&2
    exit 2
  fi
}

task_is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

task_bool_enabled() {
  case "${1:-true}" in
    1 | true | TRUE | yes | YES | on | ON) return 0 ;;
    *) return 1 ;;
  esac
}

task_json_bool() {
  case "${1:-false}" in
    1 | true | TRUE | yes | YES | on | ON) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

task_json_num_or_null() {
  case "${1:-}" in
    '' | *[!0-9]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}
