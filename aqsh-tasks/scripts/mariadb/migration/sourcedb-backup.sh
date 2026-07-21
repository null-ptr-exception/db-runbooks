#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/migration/sourcedb-backup.sh
# Take a physical (mariabackup) backup of a migration source MariaDB to a
# caller-specified external MinIO endpoint.
#
# Unlike physical-backup.sh — which resolves S3 credentials from platform
# deploy-time config — this task accepts MinIO credentials as explicit task
# inputs. This is the intended path for cross-cluster migrations where the
# backup destination is outside the platform's own MinIO.
#
# Secure credential handling:
#   The minio_secret_key arrives as the env var MINIO_SECRET_KEY. It is
#   written immediately to a temporary Kubernetes Secret in the target
#   namespace, then the env var is unset. The PhysicalBackup CR references
#   that Secret directly; the raw value never appears in logs or result JSON.
#   The temporary Secret is deleted on task exit (EXIT trap).
#
# The backup name defaults to <mariadb>-migration-<timestamp>. The S3 prefix
# defaults to mariadb/<namespace> (compatible with the platform restore task).
# =============================================================================

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi

# Capture the raw 'mariadb' input before mariadb.sh defaults MARIADB_NAME.
MDB_INPUT="${MARIADB_NAME:-}"

# shellcheck source=../../../lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"
# shellcheck source=../../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"

OP="migration/sourcedb-backup"

# --- Task inputs (all MinIO params are required for migration) ---------------
NAMESPACE="${DB_NAMESPACE:-}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-}"
MINIO_BUCKET="${MINIO_BUCKET:-}"
TARGET="${BACKUP_TARGET:-PreferReplica}"
COMPRESSION="${BACKUP_COMPRESSION:-bzip2}"
CONFIRM="${CONFIRM:-false}"
DRY_RUN="${DRY_RUN:-true}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"
K8S_CONTEXT="${K8S_CONTEXT:-}"
BACKUP_NAME="${BACKUP_NAME:-}"

# S3 internals not exposed as task inputs (env-overridable for advanced ops).
BACKUP_REGION="${BACKUP_REGION:-us-east-1}"
# Key names inside the temp secret — follow the same convention as the platform.
_CRED_ACCESS_KEY_NAME="access-key-id"
_CRED_SECRET_KEY_NAME="secret-access-key"

# Re-export for the shared manifest builder.
BACKUP_TARGET="$TARGET"
BACKUP_COMPRESSION="$COMPRESSION"

# --- Input validation --------------------------------------------------------
if [[ "$(mdbt_bool_json "$DRY_RUN")" != "true" ]]; then
  mdbt_require_confirm "$OP" "$CONFIRM"
fi

mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"
mdbt_required "minio_endpoint" "$MINIO_ENDPOINT" "$OP"
mdbt_required "minio_access_key" "$MINIO_ACCESS_KEY" "$OP"
mdbt_required "minio_secret_key" "$MINIO_SECRET_KEY" "$OP"
mdbt_required "minio_bucket" "$MINIO_BUCKET" "$OP"
mdbt_validate_s3_bucket "minio_bucket" "$MINIO_BUCKET" "$OP"
mdbt_validate_endpoint "minio_endpoint" "$MINIO_ENDPOINT" "$OP"

if [[ -n "$K8S_CONTEXT" ]]; then
  mdbt_validate_context "context" "$K8S_CONTEXT" "$OP"
fi

# Wire the cluster/namespace target through the canonical entry point.
mariadb_set_target "$K8S_CONTEXT" "$NAMESPACE" "${MARIADB_RESOURCE:-mariadb}" "$MDB_INPUT"

# --- MariaDB auto-detect -----------------------------------------------------
_on_ambiguous() {
  mdbt_fail "$OP" "several MariaDB instances in '${NAMESPACE}'; set 'mariadb' to choose which one to back up" \
    "$(jq -n --arg c "$1" '{candidates: ($c | split(","))}')" 2
}
_on_none() {
  mdbt_fail "$OP" "no MariaDB instance found in '${NAMESPACE}' to back up" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2
}

if [[ -z "$MDB_INPUT" ]]; then
  mariadb_autodetect_target false _on_ambiguous _on_none
else
  MARIADB_NAME="$MDB_INPUT"
fi

mdbt_validate_dns_label "mariadb" "$MARIADB_NAME" "$OP"

# Auto-name with a migration marker so these are distinguishable in the bucket.
if [[ -z "$BACKUP_NAME" ]]; then
  BACKUP_NAME="${MARIADB_NAME}-migration-$(date +%Y%m%d%H%M%S)"
fi
mdbt_validate_dns_label "backup_name" "$BACKUP_NAME" "$OP"

mdbt_validate_enum "target" "$TARGET" "$OP" Primary Replica PreferReplica
mdbt_validate_enum "compression" "$COMPRESSION" "$OP" bzip2 gzip none

# --- Resolve backup location from task inputs --------------------------------
BACKUP_BUCKET="$MINIO_BUCKET"
BACKUP_PREFIX="${BACKUP_PREFIX:-mariadb/${NAMESPACE}}"
BACKUP_ENDPOINT="$MINIO_ENDPOINT"

mdbt_validate_s3_prefix "backup_prefix" "$BACKUP_PREFIX" "$OP"

# --- Result helpers ----------------------------------------------------------
_backup_result() {
  local created="$1" dry="$2"
  jq -n \
    --arg namespace "$NAMESPACE" \
    --arg mariadb "$MARIADB_NAME" \
    --arg backupName "$BACKUP_NAME" \
    --arg endpoint "$BACKUP_ENDPOINT" \
    --arg bucket "$BACKUP_BUCKET" \
    --arg prefix "$BACKUP_PREFIX" \
    --arg target "$TARGET" \
    --arg compression "$COMPRESSION" \
    --argjson created "$created" \
    --argjson dry "$dry" \
    '{
      namespace: $namespace,
      mariadb: $mariadb,
      backupName: $backupName,
      backup: {endpoint: $endpoint, bucket: $bucket, prefix: $prefix, contentType: "Physical"},
      target: $target,
      compression: $compression,
      dryRun: $dry,
      created: $created
    }'
}

# --- Dry run: render manifest without creating any resources -----------------
if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  # Use a placeholder secret name for the dry-run manifest preview.
  BACKUP_ACCESS_SECRET="migration-backup-creds-preview"
  BACKUP_ACCESS_KEY="$_CRED_ACCESS_KEY_NAME"
  BACKUP_SECRET_KEY="$_CRED_SECRET_KEY_NAME"
  MANIFEST="$(mdbt_physical_backup_manifest "$BACKUP_NAME" "$NAMESPACE" "$MARIADB_NAME")"

  mdbt_write_result "$(response_ok "$OP" \
    "dry run: PhysicalBackup manifest rendered for ${MARIADB_NAME}" \
    "$(_backup_result false true | jq --arg m "$MANIFEST" '. + {manifest: $m}')")"
  exit 0
fi

# --- Check source MariaDB is Ready -------------------------------------------
if ! SOURCE_JSON="$(_kubectl get mariadb "$MARIADB_NAME" -o json 2>&1)"; then
  if [[ "$SOURCE_JSON" == *NotFound* || "$SOURCE_JSON" == *"not found"* ]]; then
    mdbt_fail "$OP" "source MariaDB '${MARIADB_NAME}' not found in '${NAMESPACE}'" \
      "$(jq -n --arg ns "$NAMESPACE" --arg mdb "$MARIADB_NAME" '{namespace: $ns, mariadb: $mdb}')" 2
  fi
  mdbt_fail "$OP" "failed to query source MariaDB '${MARIADB_NAME}': ${SOURCE_JSON}" \
    "$(jq -n --arg ns "$NAMESPACE" --arg mdb "$MARIADB_NAME" '{namespace: $ns, mariadb: $mdb}')" 1
fi
READY="$(jq -r '.status.conditions[]? | select(.type == "Ready") | .status' <<<"$SOURCE_JSON" | tail -1)"
if [[ "$READY" != "True" ]]; then
  mdbt_fail "$OP" "source MariaDB '${MARIADB_NAME}' must be Ready before a physical backup" \
    "$(jq -n --arg mdb "$MARIADB_NAME" --arg r "${READY:-Unknown}" '{mariadb: $mdb, ready: $r}')" 2
fi

# --- Create temporary K8s Secret with MinIO credentials ----------------------
# The secret is created with --dry-run=client | apply so a concurrent collision
# on the same name is a no-op rather than an error. Exit trap cleans it up.
TEMP_SECRET_NAME="migration-backup-creds-$(date +%Y%m%d%H%M%S)"

_cleanup_temp_secret() {
  if [[ -n "${TEMP_SECRET_NAME:-}" ]]; then
    _kubectl delete secret "$TEMP_SECRET_NAME" --ignore-not-found >/dev/null 2>&1 || true
  fi
}
trap _cleanup_temp_secret EXIT

_kubectl create secret generic "$TEMP_SECRET_NAME" \
  --from-literal="${_CRED_ACCESS_KEY_NAME}=${MINIO_ACCESS_KEY}" \
  --from-literal="${_CRED_SECRET_KEY_NAME}=${MINIO_SECRET_KEY}" \
  --dry-run=client -o json | _kubectl apply -f - >/dev/null

# Clear the raw secret key from memory — the operator reads it from the Secret.
unset MINIO_SECRET_KEY

# Wire credential references for the manifest builder.
# BACKUP_ACCESS_SECRET/KEY/SECRET_KEY are read by mdbt_physical_backup_manifest
# in mariadb-task-common.sh, not referenced again in this file.
# shellcheck disable=SC2034
BACKUP_ACCESS_SECRET="$TEMP_SECRET_NAME"
# shellcheck disable=SC2034
BACKUP_ACCESS_KEY="$_CRED_ACCESS_KEY_NAME"
# shellcheck disable=SC2034
BACKUP_SECRET_KEY="$_CRED_SECRET_KEY_NAME"

# --- Build and apply PhysicalBackup CR ---------------------------------------
MANIFEST="$(mdbt_physical_backup_manifest "$BACKUP_NAME" "$NAMESPACE" "$MARIADB_NAME")"
printf '%s\n' "$MANIFEST" | _kubectl apply -f -

# --- Wait for completion -----------------------------------------------------
# wait_timeout="0" → return immediately without waiting.
if [[ "$WAIT_TIMEOUT" != "0" ]]; then
  if ! _kubectl wait --for=condition=Complete "physicalbackup/${BACKUP_NAME}" \
      --timeout="$WAIT_TIMEOUT" >/dev/null 2>&1; then
    status_json="$(_kubectl get "physicalbackup/${BACKUP_NAME}" -o json \
      | jq -c '.status // {}' 2>/dev/null || printf '{}')"
    mdbt_write_result "$(response_err "$OP" \
      "PhysicalBackup ${BACKUP_NAME} was created but did not Complete within ${WAIT_TIMEOUT}" \
      "$(_backup_result true false | jq \
        --argjson s "$status_json" \
        '. + {physicalBackupStatus: $s.status, physicalBackupConditions: ($s.conditions // [])}')" 1)"
    exit 1
  fi

  status_json="$(_kubectl get "physicalbackup/${BACKUP_NAME}" -o json \
    2>/dev/null | jq -c '.status // {}' 2>/dev/null || printf '{}')"
  if jq -e '
    (.status == "Failed") or
    any(.conditions[]?; .type == "Complete" and .status == "True" and .reason == "JobFailed")
  ' <<<"$status_json" >/dev/null; then
    reason="$(jq -r '.conditions[]? | select(.type == "Complete") | .reason // empty' \
      <<<"$status_json" | tail -1)"
    mdbt_write_result "$(response_err "$OP" \
      "PhysicalBackup ${BACKUP_NAME} failed${reason:+: ${reason}}" \
      "$(_backup_result true false | jq \
        --argjson s "$status_json" \
        '. + {physicalBackupStatus: $s.status, physicalBackupConditions: ($s.conditions // [])}')" 1)"
    exit 1
  fi
fi

mdbt_write_result "$(response_ok "$OP" \
  "migration backup ${BACKUP_NAME} completed for ${MARIADB_NAME}" \
  "$(_backup_result true false)")"
