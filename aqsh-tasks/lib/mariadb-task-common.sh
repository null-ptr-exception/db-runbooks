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
# shellcheck source=aqsh-tasks/lib/mariadb-operator-profile.sh
source "${LIB_DIR}/mariadb-operator-profile.sh"  # operator generation / apiGroup detection
# shellcheck source=aqsh-tasks/lib/mariadb-s3-resolver.sh
source "${LIB_DIR}/mariadb-s3-resolver.sh"

# Deploy-time config mounted by the aqsh ConfigMap (MINIO_ENDPOINT, MINIO_BUCKET,
# ...). Overridable so tests / out-of-cluster callers can point elsewhere.
MDBT_CONFIG_FILE="${MDBT_CONFIG_FILE:-/etc/aqsh/config/mariadb.env}"

# mdbt_load_config
# Load the deploy-time MariaDB config if present (no-op when absent, e.g. unit
# tests) so MINIO_* settings become available to the resolvers below. Values are
# applied as DEFAULTS: a variable already set in the environment (a caller
# override) is kept, never clobbered by the file. The file is a simple KEY=value
# env file (comments / blank lines ignored).
mdbt_load_config() {
  [[ -f "$MDBT_CONFIG_FILE" ]] || return 0
  local _key _val
  while IFS='=' read -r _key _val; do
    [[ "$_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue   # skip comments / blanks
    [[ -n "${!_key:-}" ]] && continue                       # keep a pre-set override
    printf -v "$_key" '%s' "$_val"
    export "${_key?}"
    _MDBT_CONFIG_LOADED_KEYS="${_MDBT_CONFIG_LOADED_KEYS:-}${_key}"$'\n'
  done < "$MDBT_CONFIG_FILE"
  export _MDBT_CONFIG_LOADED_KEYS
  return 0
}

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

# Build the public error envelope used by MariaDB tasks. `reason` is a stable,
# machine-readable contract; the human message may evolve without forcing API
# clients to parse prose. Keep implementation diagnostics in task logs only.
mdbt_error_response() {
  local op="$1" message="$2" data="${3:-}" code="${4:-1}" reason="${5:-OPERATION_FAILED}"
  [[ -n "$data" ]] || data="{}"
  response_err "$op" "$message" "$data" "$code" |
    jq -c --arg reason "$reason" '. + {reason: $reason}'
}

mdbt_fail() {
  # NB: default via a second statement, not "${3:-{}}" — that brace-in-default
  # form appends a stray "}" when $3 is set, corrupting a non-empty data payload.
  local op="$1" message="$2" data="${3:-}" code="${4:-1}" reason="${5:-}"
  [[ -n "$data" ]] || data="{}"
  if [[ -z "$reason" ]]; then
    if [[ "$code" == "2" ]]; then
      reason="INVALID_REQUEST"
    else
      reason="OPERATION_FAILED"
    fi
  fi
  mdbt_write_result "$(mdbt_error_response "$op" "$message" "$data" "$code" "$reason")"
  exit "$code"
}

# Run a validator for platform-owned values without exposing its field names or
# values through the public response. Validators call `exit`, hence the
# subshell. The caller supplies the user-safe category/message.
mdbt_validate_internal_or_fail() {
  local op="$1" reason="$2" message="$3"
  shift 3
  if ! (MDBT_RESULT_FILE=/dev/null; "$@") >/dev/null 2>&1; then
    mdbt_fail "$op" "$message" "{}" 1 "$reason"
  fi
}

# mdbt_require_confirm <op> <confirm_value>
# Gate a mutating task behind confirm=true.
mdbt_require_confirm() {
  local op="$1" confirm="$2"
  case "$confirm" in
    true | TRUE | yes | YES | 1) ;;
    *) mdbt_fail "$op" "confirm=true is required for this mutating task" "{\"confirm\":\"$confirm\"}" 2 "INVALID_REQUEST" ;;
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
    mdbt_fail "$op" "${name} must be an S3 bucket-style token" "$(jq -n --arg field "$name" '{field: $field}')" 2
  fi
}

mdbt_validate_s3_prefix() {
  local name="$1" value="$2" op="$3"
  if [[ -z "$value" || ! "$value" =~ ^[A-Za-z0-9._/-]+$ || "$value" == /* || "$value" == */ || "$value" == *//* ]]; then
    mdbt_fail "$op" "${name} must be a non-empty relative S3 prefix" "$(jq -n --arg field "$name" '{field: $field}')" 2
  fi
  local segment
  while IFS= read -r segment; do
    if [[ "$segment" == "." || "$segment" == ".." || -z "$segment" ]]; then
      mdbt_fail "$op" "${name} contains a traversal-like or ambiguous path segment" "$(jq -n --arg field "$name" '{field: $field}')" 2
    fi
  done < <(tr '/' '\n' <<<"$value")
  if [[ "$value" == *"\\"* ]]; then
    mdbt_fail "$op" "${name} contains an unsupported path separator" "$(jq -n --arg field "$name" '{field: $field}')" 2
  fi
}

mdbt_validate_endpoint() {
  local name="$1" value="$2" op="$3"
  # Accept either a scheme URL (as carried in MINIO_ENDPOINT), e.g.
  # http://minio.kind-b.test:30080, or a bare host:port (operator-style) e.g.
  # minio.svc:9000. A bare host with no port (and no scheme) is rejected.
  if [[ ! "$value" =~ ^([A-Za-z][A-Za-z0-9+.-]*://[A-Za-z0-9._-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?|[A-Za-z0-9._-]+:[0-9]+)$ ]]; then
    mdbt_fail "$op" "${name} must be a host:port or scheme URL endpoint" "$(jq -n --arg field "$name" '{field: $field}')" 2
  fi
}

mdbt_operator_s3_endpoint() {
  local endpoint="$1"
  endpoint="${endpoint#*://}"
  endpoint="${endpoint%%/*}"
  printf '%s' "$endpoint"
}

# mdbt_operator_s3_tls_enabled <endpoint>
# The operator endpoint is a bare host:port, so TLS can't be inferred from it.
# Derive it from the original endpoint's scheme: https:// -> true, else false.
# So a real https S3 endpoint keeps TLS while the plain-HTTP MinIO lab does not.
mdbt_operator_s3_tls_enabled() {
  case "$1" in
    https://*) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

mdbt_validate_region() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[A-Za-z0-9-]+$ ]]; then
    mdbt_fail "$op" "${name} must match ^[A-Za-z0-9-]+$" "$(jq -n --arg field "$name" '{field: $field}')" 2
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

# Operator bootstrap is asynchronous and Ready may briefly reflect the newly
# created instance before backup reconciliation starts. Wait for the explicit
# restore condition first so callers cannot report success during that window.
mdbt_wait_mariadb_backup_restored() {
  local name="$1" timeout="${2:-10m}" resource="${3:-${MARIADB_RESOURCE:-mariadb}}"
  _kubectl wait --for=condition=BackupRestored "${resource}/${name}" --timeout="$timeout"
}

# mdbt_physical_backup_manifest <name> <namespace> <mariadb_ref>
# Emit a mariadb-operator PhysicalBackup CR as JSON (kubectl apply accepts JSON,
# so there is no YAML-interpolation surface). The single source of truth for the
# PhysicalBackup shape, shared by blue-green and the physical-backup task so they
# can never diverge. The S3 location and credentials are read from the BACKUP_*
# environment (populated by mdbt_resolve_backup_location + task defaults):
#   BACKUP_TARGET (Primary|Replica|PreferReplica), BACKUP_COMPRESSION,
#   BACKUP_BUCKET, BACKUP_PREFIX, BACKUP_ENDPOINT, BACKUP_REGION,
#   BACKUP_ACCESS_SECRET, BACKUP_ACCESS_KEY,
#   BACKUP_SECRET_ACCESS_SECRET, BACKUP_SECRET_KEY.
# A PhysicalBackup with no schedule runs exactly once, immediately.
mdbt_physical_backup_manifest() {
  local name="$1" namespace="$2" mariadb="$3"
  local operator_endpoint operator_tls
  operator_endpoint="$(mdbt_operator_s3_endpoint "$BACKUP_ENDPOINT")"
  operator_tls="$(mdbt_operator_s3_tls_enabled "$BACKUP_ENDPOINT")"
  jq -n \
    --arg apiVersion "$(mdb_operator_apiversion)" \
    --arg name "$name" \
    --arg namespace "$namespace" \
    --arg mariadb "$mariadb" \
    --arg target "${BACKUP_TARGET}" \
    --arg compression "${BACKUP_COMPRESSION}" \
    --arg bucket "$BACKUP_BUCKET" \
    --arg prefix "$BACKUP_PREFIX" \
    --arg endpoint "$operator_endpoint" \
    --argjson tls "$operator_tls" \
    --arg region "$BACKUP_REGION" \
    --arg accessSecret "$BACKUP_ACCESS_SECRET" \
    --arg accessKey "$BACKUP_ACCESS_KEY" \
    --arg secretAccessSecret "${BACKUP_SECRET_ACCESS_SECRET:-$BACKUP_ACCESS_SECRET}" \
    --arg secretKey "$BACKUP_SECRET_KEY" \
    '{
      apiVersion: $apiVersion,
      kind: "PhysicalBackup",
      metadata: {name: $name, namespace: $namespace},
      spec: {
        mariaDbRef: {name: $mariadb},
        target: $target,
        compression: $compression,
        storage: {
          s3: {
            bucket: $bucket,
            prefix: $prefix,
            endpoint: $endpoint,
            region: $region,
            tls: {enabled: $tls},
            accessKeyIdSecretKeyRef: {name: $accessSecret, key: $accessKey},
            secretAccessKeySecretKeyRef: {name: $secretAccessSecret, key: $secretKey}
          }
        }
      }
    }'
}

# mdbt_logical_backup_manifest <name> <namespace> <mariadb_ref> <include_prefix>
# Emit a mariadb-operator `Backup` CR as JSON (logical / mariadb-dump backup).
# The single source of truth for the Backup shape, sibling to the PhysicalBackup
# builder above. The legacy mmontes-era S3 schema has no `prefix` field, so the
# caller must pass include_prefix=false for that generation. Neither
# `compression` nor `databases` is emitted because those fields are also absent
# from the legacy CRD.
# S3 location/credentials come from the BACKUP_* environment, identically to the
# physical builder. A Backup with no schedule runs exactly once, immediately.
mdbt_logical_backup_manifest() {
  local name="$1" namespace="$2" mariadb="$3" include_prefix="${4:-true}"
  local operator_endpoint operator_tls
  operator_endpoint="$(mdbt_operator_s3_endpoint "$BACKUP_ENDPOINT")"
  operator_tls="$(mdbt_operator_s3_tls_enabled "$BACKUP_ENDPOINT")"
  jq -n \
    --arg apiVersion "$(mdb_operator_apiversion)" \
    --arg name "$name" \
    --arg namespace "$namespace" \
    --arg mariadb "$mariadb" \
    --arg bucket "$BACKUP_BUCKET" \
    --arg prefix "$BACKUP_PREFIX" \
    --arg endpoint "$operator_endpoint" \
    --argjson tls "$operator_tls" \
    --arg region "$BACKUP_REGION" \
    --arg accessSecret "$BACKUP_ACCESS_SECRET" \
    --arg accessKey "$BACKUP_ACCESS_KEY" \
    --arg secretAccessSecret "${BACKUP_SECRET_ACCESS_SECRET:-$BACKUP_ACCESS_SECRET}" \
    --arg secretKey "$BACKUP_SECRET_KEY" \
    --argjson includePrefix "$include_prefix" \
    '{
      apiVersion: $apiVersion,
      kind: "Backup",
      metadata: {name: $name, namespace: $namespace},
      spec: {
        mariaDbRef: {name: $mariadb},
        storage: {
          s3: ({
            bucket: $bucket,
            endpoint: $endpoint,
            region: $region,
            tls: {enabled: $tls},
            accessKeyIdSecretKeyRef: {name: $accessSecret, key: $accessKey},
            secretAccessKeySecretKeyRef: {name: $secretAccessSecret, key: $secretKey}
          } + (if $includePrefix then {prefix: $prefix} else {} end))
        }
      }
    }'
}
