#!/usr/bin/env bash
set -euo pipefail

# MariaDB backup task - Backup database to MinIO
#
LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi
MDB_INPUT="${MARIADB_NAME:-}"
source "${LIB_DIR}/mariadb-task-common.sh"
source "${LIB_DIR}/mariadb.sh"
source "${LIB_DIR}/minio-client.sh"

mdbt_load_config

DB_NAMESPACE="${DB_NAMESPACE:-}"
BACKUP_DATABASES="${BACKUP_DATABASES:---all-databases}"

mdbt_validate_dns_label "namespace" "$DB_NAMESPACE" "backup"
mariadb_set_target "${K8S_CONTEXT:-}" "$DB_NAMESPACE" "$MARIADB_RESOURCE" "$MDB_INPUT"
if [[ -z "$MDB_INPUT" ]]; then
  _on_ambiguous() {
    mdbt_fail "backup" "database configuration is ambiguous" \
      "$(jq -n --arg ns "$DB_NAMESPACE" '{namespace:$ns}')" 2 "DATABASE_CONFIGURATION_AMBIGUOUS"
  }
  _on_none() {
    mdbt_fail "backup" "database not found" \
      "$(jq -n --arg ns "$DB_NAMESPACE" '{namespace:$ns}')" 2 "DATABASE_NOT_FOUND"
  }
  mariadb_autodetect_target false _on_ambiguous _on_none
else
  MARIADB_NAME="$MDB_INPUT"
fi

if ! mdbt_resolve_backup_location "$DB_NAMESPACE" "$MARIADB_NAME"; then
  mdbt_fail "backup" "backup configuration is unavailable" \
    "$(jq -n --arg ns "$DB_NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_CONFIGURATION_UNAVAILABLE"
fi

log_info "Starting database backup"

POD_NAME="$(mariadb_list_pods 2>/dev/null | head -1)"

if [[ -z "$POD_NAME" ]]; then
  mdbt_fail "backup" "database is unavailable" \
    "$(jq -n --arg ns "$DB_NAMESPACE" '{namespace:$ns}')" 1 "DATABASE_NOT_READY"
fi

# Check if pod exists and is ready
if ! _kubectl get pod "${POD_NAME}" &>/dev/null; then
  mdbt_fail "backup" "database is unavailable" \
    "$(jq -n --arg ns "$DB_NAMESPACE" '{namespace:$ns}')" 1 "DATABASE_NOT_READY"
fi

if ! _kubectl wait pod "${POD_NAME}" --for=condition=Ready --timeout=30s >/dev/null 2>&1; then
  mdbt_fail "backup" "database is not ready for backup" \
    "$(jq -n --arg ns "$DB_NAMESPACE" '{namespace:$ns}')" 1 "DATABASE_NOT_READY"
fi

# Generate backup filename with timestamp
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="logical-${TIMESTAMP}.sql.gz"
LOCAL_PATH="/tmp/${BACKUP_NAME}"

log_info "Preparing logical backup"

# Get root password from secret
ROOT_PASSWORD=$(_kubectl get secret mariadb -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [[ -z "$ROOT_PASSWORD" ]]; then
  log_warn "Database authentication is unavailable; trying the configured fallback"
  PASSWORD_ARG=""
else
  PASSWORD_ARG="-p${ROOT_PASSWORD}"
fi

# Perform backup
log_info "Creating logical backup"
if _kubectl exec "${POD_NAME}" -- \
  mariadb-dump ${BACKUP_DATABASES} \
    --single-transaction \
    --quick \
    --lock-tables=false \
    -u root ${PASSWORD_ARG} 2>/dev/null \
  | gzip > "${LOCAL_PATH}"; then
  log_info "Database dump completed"
else
  mdbt_fail "backup" "logical backup failed" \
    "$(jq -n --arg ns "$DB_NAMESPACE" '{namespace:$ns,created:false,state:"FAILED"}')" 1 "BACKUP_FAILED"
fi

# Get backup file size
BACKUP_SIZE=$(stat -c%s "${LOCAL_PATH}" 2>/dev/null || echo "0")
BACKUP_SIZE_MB=$(( BACKUP_SIZE / 1024 / 1024 ))
log_info "Backup size: ${BACKUP_SIZE_MB} MB"

# Setup the direct S3 client without rendering credential values.
if ! mdbt_s3_prepare_direct_client >/dev/null 2>&1; then
  rm -f "${LOCAL_PATH}"
  mdbt_fail "backup" "backup configuration is unavailable" \
    "$(jq -n --arg ns "$DB_NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_CONFIGURATION_UNAVAILABLE"
fi

# Setup MinIO client
if ! setup_minio_client >/dev/null 2>&1; then
  rm -f "${LOCAL_PATH}"
  mdbt_fail "backup" "backup service is unavailable" \
    "$(jq -n --arg ns "$DB_NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_SERVICE_UNAVAILABLE"
fi

# Ensure bucket exists
if ! ensure_bucket "${BACKUP_BUCKET}" >/dev/null 2>&1; then
  rm -f "${LOCAL_PATH}"
  mdbt_fail "backup" "backup service is unavailable" \
    "$(jq -n --arg ns "$DB_NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_SERVICE_UNAVAILABLE"
fi

# Upload to MinIO
REMOTE_PATH="${BACKUP_BUCKET}/${BACKUP_PREFIX}/${BACKUP_NAME}"
log_info "Uploading logical backup"

if upload_to_minio "${LOCAL_PATH}" "${REMOTE_PATH}" >/dev/null 2>&1; then
  log_info "Backup uploaded successfully"
else
  rm -f "${LOCAL_PATH}"
  mdbt_fail "backup" "logical backup failed" \
    "$(jq -n --arg ns "$DB_NAMESPACE" --arg name "$BACKUP_NAME" \
      '{namespace:$ns,backupName:$name,created:false,state:"FAILED"}')" 1 "BACKUP_FAILED"
fi

# Cleanup local file
rm -f "${LOCAL_PATH}"
log_info "Local backup file removed"

# Return success result
mdbt_write_result "$(response_ok "backup" "logical backup completed" "$(jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg backupName "$BACKUP_NAME" \
  --arg size "$BACKUP_SIZE" \
  --arg createdAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  '{
    namespace: $namespace,
    backupName: $backupName,
    contentType: "Logical",
    sizeBytes: ($size | tonumber),
    createdAt: $createdAt,
    created: true,
    state: "COMPLETED"
  }')")"

log_info "Backup task completed successfully"
