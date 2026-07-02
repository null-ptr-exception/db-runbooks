#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# backup/delete-backup-mariadb.sh
# Delete a named backup for a namespace under the shared convention
# (s3://<bucket>/mariadb/<namespace>/<backup>). The AWS-RDS analogue of
# DeleteDBSnapshot.
#
# Mutating: dry_run (default true) renders the plan; applying requires
# dry_run=false and confirm=true. The backup name is a single path segment
# (validated) so a deletion can never escape the namespace's own prefix.
# =============================================================================

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi

# shellcheck source=../../lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"  # logging, response, k8s + generic helpers
# shellcheck source=../../lib/minio-client.sh
source "${LIB_DIR}/minio-client.sh"         # setup_minio_client, mc

mdbt_load_config

OP="delete-backup"

NAMESPACE="${DB_NAMESPACE:-}"          # the database identity
BACKUP_NAME="${BACKUP_NAME:-}"         # the backup to delete (single path segment)
CONFIRM="${CONFIRM:-false}"
DRY_RUN="${DRY_RUN:-true}"

# Confirm is required to apply; a dry run renders the plan without it.
if [[ "$(mdbt_bool_json "$DRY_RUN")" != "true" ]]; then
  mdbt_require_confirm "$OP" "$CONFIRM"
fi

mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"
mdbt_required "backup" "$BACKUP_NAME" "$OP"
# A single path segment only — no slashes, no traversal — so the delete stays
# confined to this namespace's prefix.
if [[ ! "$BACKUP_NAME" =~ ^[A-Za-z0-9._-]+$ || "$BACKUP_NAME" == "." || "$BACKUP_NAME" == ".." ]]; then
  mdbt_fail "$OP" "backup must be a single name segment (^[A-Za-z0-9._-]+$), not a path" \
    "$(jq -n --arg v "$BACKUP_NAME" '{field: "backup", value: $v}')" 2
fi

mdbt_resolve_backup_location "$NAMESPACE"
TARGET="minio/${BACKUP_BUCKET}/${BACKUP_PREFIX}/${BACKUP_NAME}"

delete_result() {
  jq -n \
    --arg namespace "$NAMESPACE" \
    --arg backup "$BACKUP_NAME" \
    --arg bucket "$BACKUP_BUCKET" \
    --arg prefix "$BACKUP_PREFIX" \
    --arg path "${BACKUP_PREFIX}/${BACKUP_NAME}" \
    --argjson dry "$1" \
    --argjson deleted "$2" \
    '{
      namespace: $namespace,
      backup: $backup,
      location: {bucket: $bucket, prefix: $prefix, path: $path},
      dryRun: $dry,
      deleted: $deleted
    }'
}

if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" "dry run: would delete backup '${BACKUP_NAME}' from ${NAMESPACE}" "$(delete_result true false)")"
  exit 0
fi

if ! setup_minio_client >/dev/null 2>&1; then
  mdbt_fail "$OP" "failed to configure the MinIO client (check MINIO_ENDPOINT / credentials)" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1
fi

# Refuse if the backup does not exist, so a typo reports clearly instead of a
# silent no-op.
if ! mc stat "$TARGET" >/dev/null 2>&1; then
  mdbt_fail "$OP" "backup '${BACKUP_NAME}' not found for namespace '${NAMESPACE}'" \
    "$(jq -n --arg ns "$NAMESPACE" --arg b "$BACKUP_NAME" '{namespace: $ns, backup: $b}')" 2
fi

# --recursive handles both a single object and a physical-backup directory; the
# validated single-segment name keeps this scoped to the namespace prefix.
if ! mc rm --recursive --force "$TARGET" >/dev/null 2>&1; then
  mdbt_fail "$OP" "failed to delete backup '${BACKUP_NAME}' from ${NAMESPACE}" \
    "$(delete_result false false)" 1
fi

mdbt_write_result "$(response_ok "$OP" "deleted backup '${BACKUP_NAME}' from ${NAMESPACE}" "$(delete_result false true)")"
