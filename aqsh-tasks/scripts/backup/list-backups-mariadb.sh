#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# backup/list-backups-mariadb.sh
# List the backups stored for a namespace under the shared convention
# (s3://<bucket>/mariadb/<namespace>/), read-only. The AWS-RDS analogue of
# DescribeDBSnapshots — pairs with `backup` / `physical-backup` (producers) and
# `restore` (consumer).
#
# The NAMESPACE is the database identity — the only input. The bucket and MinIO
# endpoint are resolved internally from deploy-time config; the caller never
# spells out where backups live.
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

# Deploy-time S3/MinIO settings (MINIO_ENDPOINT, MINIO_BUCKET, ...).
mdbt_load_config

OP="list-backups"

NAMESPACE="${DB_NAMESPACE:-}"          # the database identity — the only required input

mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"

# Resolve the S3 backup location for this namespace (bucket / prefix / endpoint),
# the same convention the backup producers write and restore reads.
mdbt_resolve_backup_location "$NAMESPACE"

if ! setup_minio_client >/dev/null 2>&1; then
  mdbt_fail "$OP" "failed to configure the MinIO client (check MINIO_ENDPOINT / credentials)" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1
fi

# `mc ls --json` emits one JSON object per entry; slurp them into an array of
# {name, size, lastModified}. An empty/absent prefix yields an empty list, not
# an error (a namespace may simply have no backups yet).
LISTING="$(mc ls --json "minio/${BACKUP_BUCKET}/${BACKUP_PREFIX}/" 2>/dev/null || true)"
BACKUPS="$(printf '%s' "$LISTING" | jq -sc '[.[] | select(.key != null) | {
  name: (.key | sub("/$"; "")),
  size: (.size // 0),
  lastModified: (.lastModified // null)
}]')"
COUNT="$(jq -n --argjson b "$BACKUPS" '$b | length')"

mdbt_write_result "$(response_ok "$OP" "found ${COUNT} backup(s) for ${NAMESPACE}" "$(jq -n \
  --arg namespace "$NAMESPACE" \
  --arg bucket "$BACKUP_BUCKET" \
  --arg prefix "$BACKUP_PREFIX" \
  --arg endpoint "$BACKUP_ENDPOINT" \
  --argjson count "$COUNT" \
  --argjson backups "$BACKUPS" \
  '{
    namespace: $namespace,
    location: {bucket: $bucket, prefix: $prefix, endpoint: $endpoint},
    count: $count,
    backups: $backups
  }')")"
