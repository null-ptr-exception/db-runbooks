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

# `mc ls --json` emits one JSON object per entry. A real failure (auth / network
# / missing bucket) must NOT be collapsed into an empty list: mc signals it either
# by a non-zero exit or by an in-band {"status":"error",...} line. Only a truly
# empty successful listing means "no backups yet".
if ! LISTING="$(mc ls --json "minio/${BACKUP_BUCKET}/${BACKUP_PREFIX}/" 2>&1)"; then
  mdbt_fail "$OP" "failed to list backups for '${NAMESPACE}': ${LISTING}" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1
fi
if ! BACKUPS="$(printf '%s' "$LISTING" | jq -sc '
    if any(.[]?; .status? == "error") then error("mc reported an error")
    else [ .[] | select(.key != null) | {
      name: (.key | sub("/$"; "")),
      size: (.size // 0),
      lastModified: (.lastModified // null)
    } ] end' 2>/dev/null)"; then
  mdbt_fail "$OP" "failed to list backups for '${NAMESPACE}' (mc reported an error)" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1
fi
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
