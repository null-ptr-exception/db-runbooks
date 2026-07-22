#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/logical-backup.sh
# Take a logical (mariadb-dump) backup of a namespace's MariaDB to S3/MinIO,
# driving the mariadb-operator `Backup` CR. This is the operator-managed logical
# counterpart of `physical-backup`, and — unlike `physical-backup` — it works on
# BOTH operator generations: the `Backup` CRD exists on the legacy mmontes-era
# operator as well as the current k8s.mariadb.com one.
#
# The NAMESPACE is the database identity. The caller says only which namespace
# to back up; source selection and destination are platform policy.
#
# A Backup with no schedule runs exactly once, immediately. This artifact is
# restored by the logical restore path (operator `Restore` CR), not by the
# physical `restore` task.
#
# NOTE: the exec-based `backup` task (backup/backup-mariadb.sh) is a separate,
# operator-INDEPENDENT logical backup (mariadb-dump piped straight to MinIO). It
# stays as the zero-dependency fallback; this task is the operator-managed one.
# =============================================================================

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi

# Capture an optional platform override before mariadb.sh defaults MARIADB_NAME.
MDB_INPUT="${MARIADB_NAME:-}"

# shellcheck source=../../lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"  # logging, response, k8s, operator-profile + helpers
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"              # for mariadb_autodetect_target (source auto-detect)

# Deploy-time S3/MinIO settings (MINIO_ENDPOINT, MINIO_BUCKET, ...).
mdbt_load_config

OP="logical-backup"

# --- User-facing inputs ------------------------------------------------------
NAMESPACE="${DB_NAMESPACE:-}"          # the database identity — the only required input
CONFIRM="${CONFIRM:-false}"
DRY_RUN="${DRY_RUN:-true}"
# wait_timeout doubles as the wait switch: "0" → return without waiting; any
# positive duration (e.g. 10m) → wait up to that long for the backup to Complete.
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"
K8S_CONTEXT="${K8S_CONTEXT:-}"         # reachability hook (empty → in-cluster)

# --- Platform internals (NOT task inputs) ------------------------------------
BACKUP_NAME="${BACKUP_NAME:-}"         # auto-named below
BACKUP_REGION="${BACKUP_REGION:-}"
BACKUP_ACCESS_SECRET="${BACKUP_ACCESS_SECRET:-}"
BACKUP_ACCESS_KEY="${BACKUP_ACCESS_KEY:-}"
BACKUP_SECRET_ACCESS_SECRET="${BACKUP_SECRET_ACCESS_SECRET:-}"
BACKUP_SECRET_KEY="${BACKUP_SECRET_KEY:-}"

# Confirm is required to apply; a dry run renders the plan without it.
if [[ "$(mdbt_bool_json "$DRY_RUN")" != "true" ]]; then
  mdbt_require_confirm "$OP" "$CONFIRM"
fi

# Namespace is the one input the caller must provide.
mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"

# Validate context before any kubectl call (empty → in-cluster).
if [[ -n "$K8S_CONTEXT" ]]; then
  mdbt_validate_internal_or_fail "$OP" "INTERNAL_ERROR" "database service is unavailable" \
    mdbt_validate_context "context" "$K8S_CONTEXT" "$OP"
fi

# Wire the cluster/namespace target through the canonical entry point.
mariadb_set_target "$K8S_CONTEXT" "$NAMESPACE" "$MARIADB_RESOURCE" "$MDB_INPUT"

# Manifest shape differs by operator generation: the legacy v0.0.24 S3 type
# rejects the current-generation `prefix` field during strict decoding. Never
# guess a shape when discovery is unavailable or ambiguous, including dry-run.
operator_confidence_rc=0
mdb_operator_group_is_confident || operator_confidence_rc=$?
if [[ "$operator_confidence_rc" -ne 0 ]]; then
  mdbt_fail "$OP" "logical backup capability is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_CAPABILITY_UNAVAILABLE"
fi
OPERATOR_GROUP="$(mdb_operator_group)"
case "$OPERATOR_GROUP" in
  k8s.mariadb.com) LOGICAL_PREFIX_SUPPORTED=true ;;
  mariadb*.mmontes.io) LOGICAL_PREFIX_SUPPORTED=false ;;
  *)
    mdbt_fail "$OP" "logical backup capability is unavailable" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_CAPABILITY_UNAVAILABLE"
    ;;
esac

# Resolve which instance to back up: platform override, else the namespace's
# single instance. Never guess across several.
_on_ambiguous() {
  mdbt_fail "$OP" "database configuration is ambiguous" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 2 "DATABASE_CONFIGURATION_AMBIGUOUS"
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

# Resolve the S3 location (bucket / endpoint), then override the prefix to the
# logical convention so logical backups land under their own prefix, separate
# from the physical ones restore/bootstrapFrom read from mariadb/<ns>.
if ! mdbt_resolve_backup_location "$NAMESPACE" "$MARIADB_NAME"; then
  mdbt_fail "$OP" "backup configuration is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_CONFIGURATION_UNAVAILABLE"
fi
# Preserve the historical logical-only fallback, but honor a workload-provided
# S3_SUBFOLDER exactly on paths whose operator schema supports a prefix.
if [[ -z "$(jq -r '.prefix.value // empty' <<<"$MDBT_S3_CONTRACT")" ]]; then
  BACKUP_PREFIX="${LOGICAL_BACKUP_PREFIX:-mariadb-logical/${NAMESPACE}}"
fi

# Auto-name the backup for the caller when they didn't.
if [[ -z "$BACKUP_NAME" ]]; then
  BACKUP_NAME="logical-$(date +%Y%m%d%H%M%S)"
fi

# Validate platform-owned values without reflecting their names or values.
_validate_internal() {
  mdbt_validate_internal_or_fail "$OP" "BACKUP_CONFIGURATION_UNAVAILABLE" \
    "backup configuration is unavailable" "$@"
}
_validate_internal mdbt_validate_dns_label "mariadb" "$MARIADB_NAME" "$OP"
_validate_internal mdbt_validate_dns_label "backup_name" "$BACKUP_NAME" "$OP"
_validate_internal mdbt_validate_s3_bucket "backup_bucket" "$BACKUP_BUCKET" "$OP"
_validate_internal mdbt_validate_s3_prefix "backup_prefix" "$BACKUP_PREFIX" "$OP"
_validate_internal mdbt_validate_endpoint "backup_endpoint" "$BACKUP_ENDPOINT" "$OP"
_validate_internal mdbt_validate_region "backup_region" "$BACKUP_REGION" "$OP"
_validate_internal mdbt_validate_dns_label "backup_access_secret" "$BACKUP_ACCESS_SECRET" "$OP"
_validate_internal mdbt_validate_secret_key "backup_access_key" "$BACKUP_ACCESS_KEY" "$OP"
_validate_internal mdbt_validate_dns_label "backup_secret_access_secret" "$BACKUP_SECRET_ACCESS_SECRET" "$OP"
_validate_internal mdbt_validate_secret_key "backup_secret_key" "$BACKUP_SECRET_KEY" "$OP"

if ! MANIFEST="$(mdbt_logical_backup_manifest "$BACKUP_NAME" "$NAMESPACE" "$MARIADB_NAME" "$LOGICAL_PREFIX_SUPPORTED" 2>/dev/null)"; then
  mdbt_fail "$OP" "logical backup could not be prepared" \
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
      contentType: "Logical",
      state: $state,
      dryRun: $dry,
      created: $created
    }'
}

if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" "logical backup dry run completed" "$(backup_result false true PLANNED)")"
  exit 0
fi

# The `Backup` CRD must exist on this cluster — turn a would-be `no matches for
# kind "Backup"` into an actionable message. (Present on both generations, but
# this guards a broken/partial install.)
if ! mdb_has_crd backups >/dev/null 2>&1; then
  mdbt_fail "$OP" "logical backup capability is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_CAPABILITY_UNAVAILABLE"
fi

# The operator only backs up a Ready source — fail clearly rather than create a
# Backup that can never complete. Merge stderr so a real failure is distinguished
# from a genuine NotFound.
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
  mdbt_fail "$OP" "logical backup could not be started" \
    "$(jq -n --arg ns "$NAMESPACE" --arg name "$BACKUP_NAME" '{namespace:$ns,backupName:$name,created:false,state:"FAILED"}')" \
    1 "BACKUP_FAILED"
fi

# wait_timeout="0" returns immediately; otherwise wait for Complete. The backup
# CR is already created at this point, so a wait timeout must NOT lose the result.
if [[ "$WAIT_TIMEOUT" != "0" ]]; then
  if ! _kubectl wait --for=condition=Complete "backup/${BACKUP_NAME}" --timeout="$WAIT_TIMEOUT" >/dev/null 2>&1; then
    mdbt_write_result "$(mdbt_error_response "$OP" "logical backup is still pending" \
      "$(backup_result true false PENDING)" 1 "BACKUP_TIMEOUT")"
    exit 1
  fi
fi

if [[ "$WAIT_TIMEOUT" == "0" ]]; then
  mdbt_write_result "$(response_ok "$OP" "logical backup requested" "$(backup_result true false REQUESTED)")"
else
  mdbt_write_result "$(response_ok "$OP" "logical backup completed" "$(backup_result true false COMPLETED)")"
fi
