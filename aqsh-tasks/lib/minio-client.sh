#!/usr/bin/env bash
# MinIO client configuration library

# setup_minio_client - Configure mc alias for MinIO
#
# Environment variables:
#   MINIO_ENDPOINT - MinIO server URL (default: http://minio.minio.svc.cluster.local:9000)
#   MINIO_ROOT_USER - MinIO access key (default: minioadmin)
#   MINIO_ROOT_PASSWORD - MinIO secret key (default: minioadmin-changeme-prod)
#
# Usage:
#   source /tasks/lib/minio-client.sh
#   setup_minio_client
#   mc ls minio/  # Now 'minio' alias is configured
setup_minio_client() {
  local minio_endpoint="${MINIO_ENDPOINT:-http://minio.minio.svc.cluster.local:9000}"
  local minio_user="${MINIO_ROOT_USER:-minioadmin}"
  local minio_pass="${MINIO_ROOT_PASSWORD:-minioadmin-changeme-prod}"

  # Configure mc alias
  mc alias set minio "${minio_endpoint}" "${minio_user}" "${minio_pass}" --api S3v4

  if [[ $? -eq 0 ]]; then
    log_info "MinIO client configured: ${minio_endpoint}"
  else
    log_error "Failed to configure MinIO client"
    return 1
  fi
}

# ensure_bucket - Create bucket if it doesn't exist
#
# Args:
#   $1 - bucket name
#
# Usage:
#   ensure_bucket "db-backups"
ensure_bucket() {
  local bucket="$1"

  if mc ls "minio/${bucket}" &>/dev/null; then
    log_info "Bucket 'minio/${bucket}' already exists"
  else
    log_info "Creating bucket 'minio/${bucket}'"
    mc mb "minio/${bucket}"
  fi
}

# upload_to_minio - Upload file to MinIO with retry
#
# Args:
#   $1 - local file path
#   $2 - remote path (e.g., "bucket/path/file.sql.gz")
#
# Usage:
#   upload_to_minio "/tmp/backup.sql.gz" "db-backups/mariadb-1/backup-20230101.sql.gz"
upload_to_minio() {
  local local_file="$1"
  local remote_path="$2"
  local max_retries=3
  local retry=0

  while (( retry < max_retries )); do
    if mc cp "${local_file}" "minio/${remote_path}"; then
      log_info "Upload successful: minio/${remote_path}"
      return 0
    else
      retry=$((retry + 1))
      if (( retry < max_retries )); then
        log_warn "Upload failed (attempt ${retry}/${max_retries}), retrying in 5s..."
        sleep 5
      fi
    fi
  done

  log_error "Upload failed after ${max_retries} attempts"
  return 1
}
