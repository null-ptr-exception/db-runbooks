#!/usr/bin/env bash
# =============================================================================
# scripts/lib/response.sh
# Standard JSON response builder for all operations.
#
# Usage:
#   source scripts/lib/response.sh
#
#   resp=$(response_ok  "operation_name" "Human readable message" '{"key":"value"}')
#   resp=$(response_err "operation_name" "Error message"          '{"detail":"..."}' 1)
#   echo "$resp"
#
# JSON Schema:
# {
#   "status":    "success" | "error",
#   "code":      <integer>,          // 0 = success, non-zero = error code
#   "operation": "<string>",         // name of the operation
#   "message":   "<string>",         // human-readable result message
#   "data":      <object|null>,      // payload (may be {} or null)
#   "timestamp": "<ISO-8601-UTC>"    // UTC timestamp
# }
# =============================================================================

# Guard against double-sourcing
[[ -n "${_RESPONSE_LIB_LOADED:-}" ]] && return 0
_RESPONSE_LIB_LOADED=1

# ---------------------------------------------------------------------------
# _escape_json_string <string>
# Escape a plain string so it is safe to embed inside a JSON double-quoted
# value.  Handles: backslash, double-quote, newline, tab, carriage-return.
# ---------------------------------------------------------------------------
_escape_json_string() {
  local s="$1"
  s="${s//\\/\\\\}"   # backslash first
  s="${s//\"/\\\"}"   # double-quote
  s="${s//$'\n'/\\n}" # newline
  s="${s//$'\r'/\\r}" # carriage return
  s="${s//$'\t'/\\t}" # tab
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# _is_json <string>
# Returns 0 (true) if the string looks like a JSON object or array or
# primitive so we can embed it verbatim; returns 1 otherwise.
# We rely on a simple heuristic (first non-space char is { [ " 0-9 t f n).
# ---------------------------------------------------------------------------
_is_json() {
  local s
  s=$(printf '%s' "$1" | sed 's/^[[:space:]]*//')
  case "$s" in
    '{'*|'['*|'"'*|'true'|'false'|'null'|[0-9]*|'-'[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# _build_response <status> <code> <operation> <message> [data]
# Core builder – all public helpers delegate here.
#   status    : "success" | "error"
#   code      : integer exit/error code
#   operation : operation identifier string
#   message   : human-readable message
#   data      : (optional) JSON value; if omitted or empty → null
# ---------------------------------------------------------------------------
_build_response() {
  local status="$1"
  local code="$2"
  local operation="$3"
  local message="$4"
  local data="${5:-}"

  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local escaped_op
  local escaped_msg
  escaped_op=$(_escape_json_string "$operation")
  escaped_msg=$(_escape_json_string "$message")

  # Determine data payload
  local json_data
  if [[ -z "$data" ]]; then
    json_data="null"
  elif _is_json "$data"; then
    json_data="$data"
  else
    local escaped_data
    escaped_data=$(_escape_json_string "$data")
    json_data="\"${escaped_data}\""
  fi

  printf '{"status":"%s","code":%d,"operation":"%s","message":"%s","data":%s,"timestamp":"%s"}\n' \
    "$status" \
    "$code" \
    "$escaped_op" \
    "$escaped_msg" \
    "$json_data" \
    "$ts"
}

# ---------------------------------------------------------------------------
# response_ok <operation> <message> [data]
# Build a success response (status=success, code=0).
# ---------------------------------------------------------------------------
response_ok() {
  local operation="$1"
  local message="$2"
  local data="${3:-}"
  _build_response "success" 0 "$operation" "$message" "$data"
}

# ---------------------------------------------------------------------------
# response_err <operation> <message> [data] [code]
# Build an error response (status=error, code defaults to 1).
# ---------------------------------------------------------------------------
response_err() {
  local operation="$1"
  local message="$2"
  local data="${3:-}"
  local code="${4:-1}"
  _build_response "error" "$code" "$operation" "$message" "$data"
}

# ---------------------------------------------------------------------------
# _json_status <json_string>
# Extract the "status" field from a response_ok / response_err JSON string.
# ---------------------------------------------------------------------------
_json_status() { echo "$1" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4; }

# ---------------------------------------------------------------------------
# _json_field <json_string> <field_name>
# Extract an arbitrary scalar field from a JSON string (string or number).
# ---------------------------------------------------------------------------
_json_field()  {
  echo "$1" | grep -o "\"${2}\":[^,}]*" | head -1 | sed "s/\"${2}\"://" | tr -d '"' | tr -d ' '
}
