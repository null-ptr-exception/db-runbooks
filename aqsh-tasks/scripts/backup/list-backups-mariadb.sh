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

MDB_INPUT="${MARIADB_NAME:-}"

# shellcheck source=../../lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"  # logging, response, k8s + generic helpers
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"
# shellcheck source=../../lib/minio-client.sh
source "${LIB_DIR}/minio-client.sh"         # setup_minio_client, s5 (s5cmd)

# Deploy-time S3/MinIO settings (MINIO_ENDPOINT, MINIO_BUCKET, ...).
mdbt_load_config

OP="list-backups"

NAMESPACE="${DB_NAMESPACE:-}"          # the database identity — the only required input

mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"

mariadb_set_target "${K8S_CONTEXT:-}" "$NAMESPACE" "$MARIADB_RESOURCE" "$MDB_INPUT"
if [[ -z "$MDB_INPUT" ]]; then
  resolve_rc=0
  resolved="$(mariadb_resolve_name)" || resolve_rc=$?
  case "$resolve_rc" in
    0) MARIADB_NAME="$resolved" ;;
    1) MARIADB_NAME="" ;; # retain namespace-only fallback after full loss
    2) mdbt_fail "$OP" "several MariaDB instances exist; set 'mariadb' to select the storage policy" \
         "$(jq -n --arg c "$resolved" '{candidateCount:($c|split(",")|length)}')" 2 ;;
  esac
else
  MARIADB_NAME="$MDB_INPUT"
fi

# Resolve the S3 backup location for this namespace (bucket / prefix / endpoint),
# the same convention the backup producers write and restore reads.
if ! mdbt_resolve_backup_location "$NAMESPACE" "$MARIADB_NAME"; then
  mdbt_fail "$OP" "failed to resolve object storage for the selected MariaDB: ${MDBT_S3_ERROR}" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 2
fi

if ! mdbt_s3_prepare_direct_client; then
  mdbt_fail "$OP" "failed to resolve S3 credentials: ${MDBT_S3_ERROR}" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1
fi

if ! setup_minio_client >/dev/null 2>&1; then
  mdbt_fail "$OP" "failed to configure the S3 client (check MINIO_ENDPOINT / credentials / s5cmd)" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1
fi

# `s5cmd --json ls` emits one JSON object per entry (key = full s3:// URL,
# type = file|directory, last_modified). Two failure semantics matter:
#   - an EMPTY prefix is exit 1 + 'no object found' — that is "no backups yet",
#     NOT an error (unlike mc, which returned an empty success);
#   - any other non-zero exit (auth / network / missing bucket) must NOT be
#     collapsed into an empty list.
S3_PREFIX="s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/"
if ! LISTING="$(s5 --json ls "$S3_PREFIX" 2>&1)"; then
  if grep -q "no object found" <<<"$LISTING"; then
    LISTING=""
  else
    # Do not reflect client stderr: SDK/client errors can include request
    # headers or other deployment details. The actionable category is enough.
    mdbt_fail "$OP" "failed to list backups (object-storage request failed)" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns, reason: "object-storage-request-failed"}')" 1
  fi
fi
if ! BACKUPS="$(printf '%s' "$LISTING" | jq -sc --arg pfx "$S3_PREFIX" '
    [ .[] | select(.key != null) | {
      name: (.key | ltrimstr($pfx) | sub("/$"; "")),
      size: (.size // 0),
      lastModified: (.last_modified // null)
    } ]' 2>/dev/null)"; then
  mdbt_fail "$OP" "failed to list backups for '${NAMESPACE}' (unparseable listing)" \
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
