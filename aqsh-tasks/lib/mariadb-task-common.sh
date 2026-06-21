#!/usr/bin/env bash
# =============================================================================
# lib/mariadb-task-common.sh
# Generic, task-agnostic helpers shared by the MariaDB runbook tasks.
#
# These were originally defined inside mariadb-blue-green.sh; they are factored
# out here so non-blue/green tasks (e.g. restore) can reuse the same input
# validation, confirm gating, and result-writing contract without depending on
# the blue/green orchestration lib. mariadb-blue-green.sh sources this file and
# keeps thin bg_* aliases for backward compatibility.
#
# Every helper is pure (operates on its arguments) except mdbt_write_result /
# mdbt_fail, which honour MDBT_RESULT_FILE, and mdbt_wait_mariadb_ready, which
# shells out via _kubectl.
# =============================================================================

[[ -n "${_MARIADB_TASK_COMMON_LOADED:-}" ]] && return 0
_MARIADB_TASK_COMMON_LOADED=1

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$SCRIPT_DIR"
fi

# shellcheck source=aqsh-tasks/lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=aqsh-tasks/lib/response.sh
source "${LIB_DIR}/response.sh"
# shellcheck source=aqsh-tasks/lib/k8s.sh
source "${LIB_DIR}/k8s.sh"

# Where a task writes its single-line JSON result. Empty → stdout.
MDBT_RESULT_FILE="${AQSH_RESULT_FILE:-}"

mdbt_write_result() {
  local payload="$1"
  if [[ -n "$MDBT_RESULT_FILE" ]]; then
    printf '%s\n' "$payload" > "$MDBT_RESULT_FILE"
  else
    printf '%s\n' "$payload"
  fi
}

mdbt_fail() {
  local op="$1" message="$2" data="${3:-{}}" code="${4:-1}"
  mdbt_write_result "$(response_err "$op" "$message" "$data" "$code")"
  exit "$code"
}

# mdbt_require_confirm <op> <confirm_value>
# Gate a mutating task behind confirm=true.
mdbt_require_confirm() {
  local op="$1" confirm="$2"
  case "$confirm" in
    true | TRUE | yes | YES | 1) ;;
    *) mdbt_fail "$op" "confirm=true is required for this mutating task" "{\"confirm\":\"$confirm\"}" 2 ;;
  esac
}

mdbt_bool_json() {
  case "$1" in
    true | TRUE | yes | YES | 1) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

mdbt_json_string() {
  jq -Rn --arg value "$1" '$value'
}

mdbt_required() {
  local name="$1" value="$2" op="$3"
  if [[ -z "$value" ]]; then
    mdbt_fail "$op" "${name} is required" "{}" 2
  fi
}

mdbt_validate_dns_label() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    mdbt_fail "$op" "${name} must be a DNS label" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

mdbt_validate_secret_key() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
    mdbt_fail "$op" "${name} must match ^[A-Za-z0-9._-]+$" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

mdbt_validate_s3_bucket() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    mdbt_fail "$op" "${name} must be an S3 bucket-style token" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

mdbt_validate_s3_prefix() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    mdbt_fail "$op" "${name} must match ^[A-Za-z0-9._/-]+$" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

mdbt_validate_endpoint() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    mdbt_fail "$op" "${name} must match ^[A-Za-z0-9._:-]+$" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

mdbt_validate_region() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[A-Za-z0-9-]+$ ]]; then
    mdbt_fail "$op" "${name} must match ^[A-Za-z0-9-]+$" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

# mdbt_validate_context <name> <value> <op>
# A kubectl context name (e.g. kind-cluster-dbs). Empty is handled by the
# caller (empty → current/in-cluster config); this only guards a non-empty
# value so a malformed context can't silently select the wrong cluster.
mdbt_validate_context() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
    mdbt_fail "$op" "${name} must match ^[A-Za-z0-9._-]+$" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

mdbt_validate_image() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[A-Za-z0-9._:/@-]+$ ]]; then
    mdbt_fail "$op" "${name} must be a container image reference token" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

mdbt_validate_storage_size() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[0-9]+(Mi|Gi|Ti)$ ]]; then
    mdbt_fail "$op" "${name} must match ^[0-9]+(Mi|Gi|Ti)$" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

mdbt_validate_uint() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    mdbt_fail "$op" "${name} must be an unsigned integer" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

# mdbt_validate_rfc3339 <name> <value> <op>
# An RFC3339 / ISO-8601 instant, e.g. 2026-06-14T03:21:00Z or
# 2026-06-14T11:21:00+08:00. Used for point-in-time recovery targets.
# Range-checked (rejects month 13, day 32, hour 24, minute/second 60, bad
# offsets); calendar edge cases like 2026-02-30 are left to the operator.
mdbt_validate_rfc3339() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$ ]]; then
    mdbt_fail "$op" "${name} must be an RFC3339 timestamp (e.g. 2026-06-14T03:21:00Z)" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

mdbt_validate_enum() {
  local name="$1" value="$2" op="$3"
  shift 3
  local allowed
  for allowed in "$@"; do
    if [[ "$value" == "$allowed" ]]; then
      return 0
    fi
  done
  mdbt_fail "$op" "${name} is not an allowed value" "$(jq -n --arg field "$name" --arg value "$value" --arg allowed "$*" '{field: $field, value: $value, allowed: $allowed}')" 2
}

mdbt_wait_mariadb_ready() {
  local name="$1" timeout="${2:-10m}" resource="${3:-${MARIADB_RESOURCE:-mariadb}}"
  _kubectl wait --for=condition=Ready "${resource}/${name}" --timeout="$timeout"
}
