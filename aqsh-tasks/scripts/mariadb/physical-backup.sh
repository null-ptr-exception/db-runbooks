#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/physical-backup.sh
# Take a physical (mariabackup) backup of a namespace's MariaDB to S3/MinIO,
# driving the mariadb-operator `PhysicalBackup` path. This is the user-facing
# producer of the backups that `restore` consumes.
#
# The NAMESPACE is the database identity. The caller says only which namespace
# to back up; source selection, format and destination are platform policy.
#
# A PhysicalBackup with no schedule runs exactly once, immediately. The logical
# `backup` task (mariadb-dump) is a different artifact and is NOT restorable via
# `restore`; this task is the physical counterpart.
# =============================================================================

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi

# Capture an optional platform override before mariadb.sh defaults MARIADB_NAME.
# It is not a task input; empty means auto-detect the namespace's instance.
MDB_INPUT="${MARIADB_NAME:-}"

# shellcheck source=../../lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"  # logging, response, k8s + generic helpers
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"              # for mariadb_autodetect_target (source auto-detect)
# shellcheck source=../../lib/minio-client.sh
source "${LIB_DIR}/minio-client.sh"         # s5cmd helpers for the hand-rolled path
# shellcheck source=../../lib/mariadb-physical-backup.sh
source "${LIB_DIR}/mariadb-physical-backup.sh"  # hand-rolled mariabackup (legacy operator)

# Deploy-time S3/MinIO settings (MINIO_ENDPOINT, MINIO_BUCKET, ...).
mdbt_load_config

OP="physical-backup"

# --- User-facing inputs ------------------------------------------------------
NAMESPACE="${DB_NAMESPACE:-}"          # the database identity — the only required input
CONFIRM="${CONFIRM:-false}"
DRY_RUN="${DRY_RUN:-true}"
# wait_timeout doubles as the wait switch: "0" → return without waiting; any
# positive duration (e.g. 10m) → wait up to that long for the backup to Complete.
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"
K8S_CONTEXT="${K8S_CONTEXT:-}"         # reachability hook (empty → in-cluster)

# --- Platform internals (NOT task inputs) ------------------------------------
# The S3 location is resolved by the shared helper (bucket/prefix/endpoint), and
# the credentials follow the platform convention; none is a task input.
BACKUP_NAME="${BACKUP_NAME:-}"         # auto-named below
BACKUP_REGION="${BACKUP_REGION:-}"
BACKUP_ACCESS_SECRET="${BACKUP_ACCESS_SECRET:-}"
BACKUP_ACCESS_KEY="${BACKUP_ACCESS_KEY:-}"
BACKUP_SECRET_ACCESS_SECRET="${BACKUP_SECRET_ACCESS_SECRET:-}"
BACKUP_SECRET_KEY="${BACKUP_SECRET_KEY:-}"
TARGET="${BACKUP_TARGET:-PreferReplica}"
COMPRESSION="${BACKUP_COMPRESSION:-bzip2}"
# Re-export resolved location for the shared manifest builder.
BACKUP_TARGET="$TARGET"
BACKUP_COMPRESSION="$COMPRESSION"

# Confirm is required to apply; a dry run renders the plan without it.
if [[ "$(mdbt_bool_json "$DRY_RUN")" != "true" ]]; then
  mdbt_require_confirm "$OP" "$CONFIRM"
fi

# Namespace is the one input the caller must provide.
mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"

# Validate context before any kubectl call (empty → in-cluster, see restore.sh).
if [[ -n "$K8S_CONTEXT" ]]; then
  mdbt_validate_internal_or_fail "$OP" "INTERNAL_ERROR" "database service is unavailable" \
    mdbt_validate_context "context" "$K8S_CONTEXT" "$OP"
fi

# Wire the cluster/namespace target through the canonical entry point.
mariadb_set_target "$K8S_CONTEXT" "$NAMESPACE" "$MARIADB_RESOURCE" "$MDB_INPUT"

# Resolve which instance to back up: platform override, else the namespace's
# single instance. Never guess across several.
_on_ambiguous() {
  mdbt_fail "$OP" "database configuration is ambiguous" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2 "DATABASE_CONFIGURATION_AMBIGUOUS"
}
_on_none() {
  mdbt_fail "$OP" "database not found" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2 "DATABASE_NOT_FOUND"
}
if [[ -z "$MDB_INPUT" ]]; then
  mariadb_autodetect_target false _on_ambiguous _on_none   # sets MARIADB_NAME or exits
else
  MARIADB_NAME="$MDB_INPUT"
fi

# Resolve the S3 backup location (bucket / prefix / endpoint) — the same helper
# restore reads, so this backup lands where restore later looks.
if ! mdbt_resolve_backup_location "$NAMESPACE" "$MARIADB_NAME"; then
  mdbt_fail "$OP" "backup configuration is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_CONFIGURATION_UNAVAILABLE"
fi

# Auto-name the backup for the caller when they didn't.
if [[ -z "$BACKUP_NAME" ]]; then
  BACKUP_NAME="physical-$(date +%Y%m%d%H%M%S)"
fi

# Validate platform-owned values without reflecting their names or values.
_validate_internal() {
  mdbt_validate_internal_or_fail "$OP" "BACKUP_CONFIGURATION_UNAVAILABLE" \
    "backup configuration is unavailable" "$@"
}
_validate_internal mdbt_validate_dns_label "mariadb" "$MARIADB_NAME" "$OP"
_validate_internal mdbt_validate_dns_label "backup_name" "$BACKUP_NAME" "$OP"
_validate_internal mdbt_validate_enum "target" "$TARGET" "$OP" Primary Replica PreferReplica
_validate_internal mdbt_validate_enum "compression" "$COMPRESSION" "$OP" bzip2 gzip none
_validate_internal mdbt_validate_s3_bucket "backup_bucket" "$BACKUP_BUCKET" "$OP"
_validate_internal mdbt_validate_s3_prefix "backup_prefix" "$BACKUP_PREFIX" "$OP"
_validate_internal mdbt_validate_endpoint "backup_endpoint" "$BACKUP_ENDPOINT" "$OP"
_validate_internal mdbt_validate_region "backup_region" "$BACKUP_REGION" "$OP"
_validate_internal mdbt_validate_dns_label "backup_access_secret" "$BACKUP_ACCESS_SECRET" "$OP"
_validate_internal mdbt_validate_secret_key "backup_access_key" "$BACKUP_ACCESS_KEY" "$OP"
_validate_internal mdbt_validate_dns_label "backup_secret_access_secret" "$BACKUP_SECRET_ACCESS_SECRET" "$OP"
_validate_internal mdbt_validate_secret_key "backup_secret_key" "$BACKUP_SECRET_KEY" "$OP"

if ! MANIFEST="$(mdbt_physical_backup_manifest "$BACKUP_NAME" "$NAMESPACE" "$MARIADB_NAME" 2>/dev/null)"; then
  mdbt_fail "$OP" "physical backup could not be prepared" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns,created:false,state:"FAILED"}')" 1 "INTERNAL_ERROR"
fi

# backup_result <created:bool> <dryRun:bool> <state>
backup_result() {
  jq -n \
    --arg namespace "$NAMESPACE" \
    --arg backupName "$BACKUP_NAME" \
    --arg state "$3" \
    --argjson created "$1" \
    --argjson dry "$2" \
    '{
      namespace: $namespace,
      backupName: $backupName,
      contentType: "Physical",
      state: $state,
      dryRun: $dry,
      created: $created
    }'
}

# --- Route by operator capability --------------------------------------------
# The current operator drives a PhysicalBackup CR (the path below). A legacy
# operator without that CRD takes the hand-rolled mariabackup path, which streams
# from the source pod straight to S3 via s5cmd. Unknown or inconsistent discovery
# is always a hard error; it must never turn into a mutating fallback.
PHYSICAL_MODE=""
mode_rc=0
PHYSICAL_MODE="$(mdb_physical_backup_mode)" || mode_rc=$?
if [[ "$mode_rc" -ne 0 ]]; then
  if [[ "$mode_rc" -eq 2 ]]; then
    mdbt_fail "$OP" "physical backup capability is unavailable" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_CAPABILITY_UNAVAILABLE"
  fi
  mdbt_fail "$OP" "physical backup capability is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_CAPABILITY_UNAVAILABLE"
fi

if [[ "$PHYSICAL_MODE" == "hand-rolled" ]]; then
  # Compatibility format is a platform choice, not a caller-visible knob.
  COMPRESSION="none"
  BACKUP_COMPRESSION="$COMPRESSION"
  # Resolve the source once and require a Ready CR before any stream/upload.
  if ! SOURCE_JSON="$(_kubectl get mariadb "$MARIADB_NAME" -o json 2>&1)"; then
    mdbt_fail "$OP" "database state is unavailable" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1 "INTERNAL_ERROR"
  fi
  READY="$(jq -r '.status.conditions[]? | select(.type == "Ready") | .status' <<<"$SOURCE_JSON" | tail -1)"
  [[ "$READY" == "True" ]] || mdbt_fail "$OP" "database is not ready for backup" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1 "DATABASE_NOT_READY"
  PRIMARY_POD="$(jq -r '.status.currentPrimary // empty' <<<"$SOURCE_JSON")"
  PB_POD="$(mdbt_pb_target_pod "$MARIADB_NAME" "$TARGET" "$PRIMARY_POD")" || {
    mdbt_fail "$OP" "database is not ready for backup" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1 "DATABASE_NOT_READY"
  }
  PB_OBJECT="${BACKUP_PREFIX}/${BACKUP_NAME}.xb"

  hr_result() {  # <created:bool> <dryRun:bool> <state>
    backup_result "$1" "$2" "$3"
  }

  if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
    mdbt_write_result "$(response_ok "$OP" "physical backup dry run completed" "$(hr_result false true PLANNED)")"
    exit 0
  fi

  if ! mdbt_s3_prepare_direct_client >/dev/null 2>&1; then
    mdbt_fail "$OP" "backup configuration is unavailable" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_CONFIGURATION_UNAVAILABLE"
  fi
  rc=0
  mdbt_pb_handrolled_run "$PB_POD" "${MARIADB_CONTAINER:-mariadb}" "$BACKUP_BUCKET" "$PB_OBJECT" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    mdbt_write_result "$(response_ok "$OP" "physical backup completed" "$(hr_result true false COMPLETED)")"
    exit 0
  fi
  mdbt_fail "$OP" "physical backup failed" \
    "$(hr_result false false FAILED)" 1 "BACKUP_FAILED"
fi

if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" "physical backup dry run completed" "$(backup_result false true PLANNED)")"
  exit 0
fi

# The operator only backs up a Ready source — fail clearly rather than create a
# PhysicalBackup that can never complete.
# Fetch the source spec. Merge stderr into the capture so a real failure
# (permission/connectivity) is distinguished from a genuine NotFound instead of
# both looking like "not found".
if ! SOURCE_JSON="$(_kubectl get mariadb "$MARIADB_NAME" -o json 2>&1)"; then
  if [[ "$SOURCE_JSON" == *NotFound* || "$SOURCE_JSON" == *"not found"* ]]; then
    mdbt_fail "$OP" "database not found" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2 "DATABASE_NOT_FOUND"
  fi
  mdbt_fail "$OP" "database state is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1 "INTERNAL_ERROR"
fi
READY="$(jq -r '.status.conditions[]? | select(.type == "Ready") | .status' <<<"$SOURCE_JSON" | tail -1)"
if [[ "$READY" != "True" ]]; then
  mdbt_fail "$OP" "database is not ready for backup" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1 "DATABASE_NOT_READY"
fi

if ! printf '%s\n' "$MANIFEST" | _kubectl apply -f - >/dev/null 2>&1; then
  mdbt_fail "$OP" "physical backup could not be started" \
    "$(jq -n --arg ns "$NAMESPACE" --arg name "$BACKUP_NAME" '{namespace:$ns,backupName:$name,created:false,state:"FAILED"}')" \
    1 "BACKUP_FAILED"
fi

# wait_timeout="0" returns immediately; otherwise wait for Complete. The backup
# CR is already created at this point, so a wait timeout must NOT lose the result
# — emit a sanitized partial result then exit non-zero.
if [[ "$WAIT_TIMEOUT" != "0" ]]; then
  if ! _kubectl wait --for=condition=Complete "physicalbackup/${BACKUP_NAME}" --timeout="$WAIT_TIMEOUT" >/dev/null 2>&1; then
    mdbt_write_result "$(mdbt_error_response "$OP" "physical backup is still pending" \
      "$(backup_result true false PENDING)" 1 "BACKUP_TIMEOUT")"
    exit 1
  fi

  status_json="$(_kubectl get "physicalbackup/${BACKUP_NAME}" -o json 2>/dev/null | jq -c '.status // {}' 2>/dev/null || printf '{}')"
  if jq -e '
    (.status == "Failed") or
    any(.conditions[]?; .type == "Complete" and .status == "True" and .reason == "JobFailed")
  ' <<<"$status_json" >/dev/null; then
    mdbt_write_result "$(mdbt_error_response "$OP" "physical backup failed" \
      "$(backup_result true false FAILED)" 1 "BACKUP_FAILED")"
    exit 1
  fi
fi

if [[ "$WAIT_TIMEOUT" == "0" ]]; then
  mdbt_write_result "$(response_ok "$OP" "physical backup requested" "$(backup_result true false REQUESTED)")"
else
  mdbt_write_result "$(response_ok "$OP" "physical backup completed" "$(backup_result true false COMPLETED)")"
fi
