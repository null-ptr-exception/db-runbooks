#!/usr/bin/env bash
set -euo pipefail

# MongoDB backup task - Backup database to MinIO
#
# Environment variables (injected by aqsh from task input):
#   DB_NAMESPACE - Target MongoDB namespace (required)
#   MINIO_BUCKET - MinIO bucket name (optional, default: db-backups)

source /tasks/lib/logging.sh
source /tasks/lib/response.sh
source /tasks/lib/k8s.sh
source /tasks/lib/minio-client.sh

DB_NAMESPACE="${DB_NAMESPACE:?DB_NAMESPACE is required}"
MINIO_BUCKET="${MINIO_BUCKET:-db-backups}"

log_info "Starting MongoDB backup for namespace: ${DB_NAMESPACE}"

POD_NAME="mongodb-0"
log_info "Using pod: ${POD_NAME}"

# Check if pod exists and is ready
if ! kubectl -n "${DB_NAMESPACE}" get pod "${POD_NAME}" &>/dev/null; then
  log_error "Pod ${POD_NAME} not found in namespace ${DB_NAMESPACE}"
  response_err "backup" "Pod ${POD_NAME} not found in namespace ${DB_NAMESPACE}" > "$AQSH_RESULT_FILE"
  exit 1
fi

if ! kubectl -n "${DB_NAMESPACE}" wait pod "${POD_NAME}" --for=condition=Ready --timeout=30s; then
  log_error "Pod ${POD_NAME} is not ready"
  response_err "backup" "Pod ${POD_NAME} is not ready" > "$AQSH_RESULT_FILE"
  exit 1
fi

# Generate backup filename with timestamp
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="mongodb-${DB_NAMESPACE}-${TIMESTAMP}"
BACKUP_ARCHIVE="${BACKUP_NAME}.tar.gz"
LOCAL_PATH="/tmp/${BACKUP_ARCHIVE}"

log_info "Backup filename: ${BACKUP_ARCHIVE}"

# Get MongoDB credentials from secret
MONGO_USER=$(kubectl -n "${DB_NAMESPACE}" get secret mongodb-credentials -o jsonpath='{.data.MONGO_ROOT_USER}' 2>/dev/null | base64 -d || echo "")
MONGO_PASS=$(kubectl -n "${DB_NAMESPACE}" get secret mongodb-credentials -o jsonpath='{.data.MONGO_ROOT_PASS}' 2>/dev/null | base64 -d || echo "")

if [[ -z "$MONGO_USER" ]] || [[ -z "$MONGO_PASS" ]]; then
  log_error "Could not retrieve MongoDB credentials from secret"
  response_err "backup" "Could not retrieve MongoDB credentials from secret" > "$AQSH_RESULT_FILE"
  exit 1
fi

# Perform backup using mongodump
log_info "Running mongodump..."
if kubectl -n "${DB_NAMESPACE}" exec "${POD_NAME}" -- \
  mongodump \
    --username="${MONGO_USER}" \
    --password="${MONGO_PASS}" \
    --authenticationDatabase=admin \
    --out="/tmp/${BACKUP_NAME}" \
    --gzip; then
  log_info "mongodump completed"
else
  log_error "mongodump failed"
  response_err "backup" "mongodump failed for ${DB_NAMESPACE}" > "$AQSH_RESULT_FILE"
  exit 1
fi

# Create tar archive
log_info "Creating archive..."
if kubectl -n "${DB_NAMESPACE}" exec "${POD_NAME}" -- \
  tar -czf "/tmp/${BACKUP_ARCHIVE}" -C /tmp "${BACKUP_NAME}"; then
  log_info "Archive created"
else
  log_error "Failed to create archive"
  kubectl -n "${DB_NAMESPACE}" exec "${POD_NAME}" -- rm -rf "/tmp/${BACKUP_NAME}"
  response_err "backup" "Archive creation failed" > "$AQSH_RESULT_FILE"
  exit 1
fi

# Copy archive from pod to local
log_info "Copying archive from pod..."
if kubectl -n "${DB_NAMESPACE}" cp "${POD_NAME}:/tmp/${BACKUP_ARCHIVE}" "${LOCAL_PATH}"; then
  log_info "Archive copied successfully"
else
  log_error "Failed to copy archive from pod"
  kubectl -n "${DB_NAMESPACE}" exec "${POD_NAME}" -- rm -f "/tmp/${BACKUP_ARCHIVE}"
  kubectl -n "${DB_NAMESPACE}" exec "${POD_NAME}" -- rm -rf "/tmp/${BACKUP_NAME}"
  response_err "backup" "Failed to copy backup from pod" > "$AQSH_RESULT_FILE"
  exit 1
fi

# Cleanup pod files
kubectl -n "${DB_NAMESPACE}" exec "${POD_NAME}" -- rm -f "/tmp/${BACKUP_ARCHIVE}"
kubectl -n "${DB_NAMESPACE}" exec "${POD_NAME}" -- rm -rf "/tmp/${BACKUP_NAME}"

# Get backup file size
BACKUP_SIZE=$(stat -c%s "${LOCAL_PATH}" 2>/dev/null || echo "0")
BACKUP_SIZE_MB=$(( BACKUP_SIZE / 1024 / 1024 ))
log_info "Backup size: ${BACKUP_SIZE_MB} MB"

# Setup MinIO client
if ! setup_minio_client; then
  log_error "Failed to setup MinIO client"
  rm -f "${LOCAL_PATH}"
  response_err "backup" "Failed to configure MinIO client" > "$AQSH_RESULT_FILE"
  exit 1
fi

# Ensure bucket exists
ensure_bucket "${MINIO_BUCKET}"

# Upload to MinIO
REMOTE_PATH="${MINIO_BUCKET}/mongodb/${DB_NAMESPACE}/${BACKUP_ARCHIVE}"
log_info "Uploading to MinIO: ${REMOTE_PATH}"

if upload_to_minio "${LOCAL_PATH}" "${REMOTE_PATH}"; then
  log_info "Backup uploaded successfully"
else
  log_error "Failed to upload backup to MinIO"
  rm -f "${LOCAL_PATH}"
  response_err "backup" "Failed to upload backup to MinIO" > "$AQSH_RESULT_FILE"
  exit 1
fi

# Cleanup local file
rm -f "${LOCAL_PATH}"
log_info "Local backup file removed"

# Return success result
response_ok "backup" "Backup completed for ${DB_NAMESPACE}" "$(jq -n \
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
    timestamp: $timestamp
  }')" > "$AQSH_RESULT_FILE"

log_info "Backup task completed successfully"
