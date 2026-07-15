#!/usr/bin/env bash
# =============================================================================
# scripts/lib/logging.sh
# Logging library – levels: DEBUG < INFO < WARN < ERROR < CRIT
#
# Usage:
#   source scripts/lib/logging.sh
#   log_set_level "DEBUG"            # set minimum level (default: INFO)
#   log_info  "operation" "message"
#   log_debug "operation" "message"
#   log_warn  "operation" "message"
#   log_error "operation" "message"
#   log_crit  "operation" "message"
#
# Output format (to stderr):
#   [YYYY-MM-DDTHH:MM:SSZ] [LEVEL] [OPERATION] message
# =============================================================================

# Guard against double-sourcing (readonly vars would error on second source)
[[ -n "${_LOGGING_LIB_LOADED:-}" ]] && return 0
_LOGGING_LIB_LOADED=1

# Numeric levels
readonly _LOG_LEVEL_DEBUG=0
readonly _LOG_LEVEL_INFO=1
readonly _LOG_LEVEL_WARN=2
readonly _LOG_LEVEL_ERROR=3
readonly _LOG_LEVEL_CRIT=4

# Current minimum level (default: INFO)
_LOG_CURRENT_LEVEL=${_LOG_CURRENT_LEVEL:-$_LOG_LEVEL_INFO}

# Optional: path to write logs. Empty = stderr only.
_LOG_FILE=${_LOG_FILE:-""}

# ---------------------------------------------------------------------------
# log_set_level <LEVEL_NAME>
# Set the minimum log level. Messages below this level are suppressed.
# ---------------------------------------------------------------------------
log_set_level() {
  local level="${1^^}"
  case "$level" in
    DEBUG) _LOG_CURRENT_LEVEL=$_LOG_LEVEL_DEBUG ;;
    INFO)  _LOG_CURRENT_LEVEL=$_LOG_LEVEL_INFO  ;;
    WARN)  _LOG_CURRENT_LEVEL=$_LOG_LEVEL_WARN  ;;
    ERROR) _LOG_CURRENT_LEVEL=$_LOG_LEVEL_ERROR ;;
    CRIT)  _LOG_CURRENT_LEVEL=$_LOG_LEVEL_CRIT  ;;
    *)
      echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [WARN] [logging] Unknown log level '$1', keeping current level." >&2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _log_write <numeric_level> <LABEL> <COLOR_CODE> <operation> <message>
# Internal writer – formats and emits a log line.
# ---------------------------------------------------------------------------
_log_write() {
  local num_level="$1"
  local label="$2"
  local color="$3"
  local operation="$4"
  local message="$5"

  # Suppress messages below current level
  if (( num_level < _LOG_CURRENT_LEVEL )); then
    return 0
  fi

  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Terminal color codes (reset = \033[0m)
  local reset="\033[0m"
  local line
  line="[${ts}] [${label}] [${operation}] ${message}"

  # Colored output to stderr
  printf "${color}%s${reset}\n" "$line" >&2

  # Plain text to log file (no colors)
  if [[ -n "$_LOG_FILE" ]]; then
    printf "%s\n" "$line" >> "$_LOG_FILE"
  fi
}

# ---------------------------------------------------------------------------
# Public log functions
# ---------------------------------------------------------------------------

# log_debug <operation> <message>
log_debug() {
  _log_write "$_LOG_LEVEL_DEBUG" "DEBUG" "\033[0;36m" "${1:-unknown}" "${2:-}"
}

# log_info <operation> <message>
log_info() {
  _log_write "$_LOG_LEVEL_INFO" "INFO " "\033[0;32m" "${1:-unknown}" "${2:-}"
}

# log_warn <operation> <message>
log_warn() {
  _log_write "$_LOG_LEVEL_WARN" "WARN " "\033[0;35m" "${1:-unknown}" "${2:-}"
}

# log_error <operation> <message>
log_error() {
  _log_write "$_LOG_LEVEL_ERROR" "ERROR" "\033[0;33m" "${1:-unknown}" "${2:-}"
}

# log_crit <operation> <message>
log_crit() {
  _log_write "$_LOG_LEVEL_CRIT" "CRIT " "\033[0;31m" "${1:-unknown}" "${2:-}"
}
