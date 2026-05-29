#!/usr/bin/env bash
set -euo pipefail

# MariaDB backup task - Backup database to MinIO
#
# Environment variables (injected by aqsh from task input):
#   DB_NAMESPACE - Target MariaDB namespace (required)
#   MINIO_BUCKET - MinIO bucket name (optional, default: db-backups)
#   BACKUP_DATABASES - Databases to backup (optional, default: --all-databases)

source /tasks/lib/logging.sh
source /tasks/lib/response.sh
source /tasks/lib/k8s.sh
source /tasks/lib/minio-client.sh

DB_NAMESPACE="${DB_NAMESPACE:?DB_NAMESPACE is required}"
MINIO_BUCKET="${MINIO_BUCKET:-db-backups}"
BACKUP_DATABASES="${BACKUP_DATABASES:---all-databases}"

log_info "Starting MariaDB backup for namespace: ${DB_NAMESPACE}"

POD_NAME="mariadb-0"

log_info "Using pod: ${POD_NAME}"

# Check if pod exists and is ready
if ! kubectl -n "${DB_NAMESPACE}" get pod "${POD_NAME}" &>/dev/null; then
  log_error "Pod ${POD_NAME} not found in namespace ${DB_NAMESPACE}"
  response_err "backup" "Pod not found" > "$AQSH_RESULT_FILE"
  exit 1
fi

if ! kubectl -n "${DB_NAMESPACE}" wait pod "${POD_NAME}" --for=condition=Ready --timeout=30s; then
  log_error "Pod ${POD_NAME} is not ready"
  response_err "backup" "Pod not ready" > "$AQSH_RESULT_FILE"
  exit 1
fi

# Generate backup filename with timestamp
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="mariadb-${DB_NAMESPACE}-${TIMESTAMP}.sql.gz"
LOCAL_PATH="/tmp/${BACKUP_NAME}"

log_info "Backup filename: ${BACKUP_NAME}"

# Get root password from secret
ROOT_PASSWORD=$(kubectl -n "${DB_NAMESPACE}" get secret mariadb -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")

if [[ -z "$ROOT_PASSWORD" ]]; then
  log_info "Could not retrieve root password from secret, trying without password"
  PASSWORD_ARG=""
else
  PASSWORD_ARG="-p${ROOT_PASSWORD}"
fi

# Perform backup
log_info "Dumping database(s): ${BACKUP_DATABASES}"
if kubectl -n "${DB_NAMESPACE}" exec "${POD_NAME}" -- \
  mariadb-dump ${BACKUP_DATABASES} \
    --single-transaction \
    --quick \
    --lock-tables=false \
    -u root ${PASSWORD_ARG} \
  | gzip > "${LOCAL_PATH}"; then
  log_info "Database dump completed"
else
  log_error "Database dump failed"
  response_err "backup" "Dump failed" > "$AQSH_RESULT_FILE"
  exit 1
fi

# Get backup file size
BACKUP_SIZE=$(stat -c%s "${LOCAL_PATH}" 2>/dev/null || echo "0")
BACKUP_SIZE_MB=$(( BACKUP_SIZE / 1024 / 1024 ))
log_info "Backup size: ${BACKUP_SIZE_MB} MB"

# Setup MinIO client
if ! setup_minio_client; then
  log_error "Failed to setup MinIO client"
  rm -f "${LOCAL_PATH}"
  response_err "backup" "MinIO setup failed" > "$AQSH_RESULT_FILE"
  exit 1
fi

# Ensure bucket exists
ensure_bucket "${MINIO_BUCKET}"

# Upload to MinIO
REMOTE_PATH="${MINIO_BUCKET}/mariadb/${DB_NAMESPACE}/${BACKUP_NAME}"
log_info "Uploading to MinIO: ${REMOTE_PATH}"

if upload_to_minio "${LOCAL_PATH}" "${REMOTE_PATH}"; then
  log_info "Backup uploaded successfully"
else
  log_error "Failed to upload backup to MinIO"
  rm -f "${LOCAL_PATH}"
  response_err "backup" "Upload failed" > "$AQSH_RESULT_FILE"
  exit 1
fi

# Cleanup local file
rm -f "${LOCAL_PATH}"
log_info "Local backup file removed"

# Return success result
response_ok "backup" "Backup completed successfully" "$(jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg bucket "$MINIO_BUCKET" \
  --arg path "$REMOTE_PATH" \
  --arg size "$BACKUP_SIZE" \
  --arg timestamp "$TIMESTAMP" \
  '{
    namespace: $namespace,
    bucket: $bucket,
    path: $path,
    size_bytes: ($size | tonumber),
    timestamp: $timestamp,
    status: "completed"
  }')" > "$AQSH_RESULT_FILE"

log_info "Backup task completed successfully"
