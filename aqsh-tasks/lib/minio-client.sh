#!/usr/bin/env bash
# S3/MinIO client library — s5cmd-backed (issue #57; replaced mc, whose
# dl.min.io distribution broke the image build in #70 and whose AGPL license is
# awkward to ship). s5cmd is a vendor-neutral S3 client: credentials come from
# AWS_* env vars and the endpoint from a flag, so there is no stateful `alias`
# step and the same calls work against MinIO or real S3.
#
# The function API is unchanged from the mc era (setup_minio_client,
# ensure_bucket, upload_to_minio) so callers did not have to change. Remote
# paths stay "bucket/path/..." — the s3:// scheme is added here.
#
# Empirically-verified s5cmd behaviors this lib relies on (v2.3.0 vs MinIO):
#   - `ls` on an empty/missing prefix exits 1 with 'no object found' (NOT an
#     empty success like mc) — callers listing must special-case that text.
#   - `rm` on a directory-style name WITHOUT a wildcard is a SILENT NO-OP that
#     still exits 0 — deletions must pick exact-key vs "name/*" by entry type.

# setup_minio_client - Export s5cmd credentials/endpoint for the s5 wrapper
#
# Environment variables:
#   MINIO_ENDPOINT - S3 endpoint URL (default: http://minio.minio.svc.cluster.local:9000)
#   MINIO_ROOT_USER - access key (default: minioadmin)
#   MINIO_ROOT_PASSWORD - secret key (default: minioadmin-changeme-prod)
#
# Usage:
#   source /tasks/lib/minio-client.sh
#   setup_minio_client
#   s5 ls s3://db-backups/
setup_minio_client() {
  S5_ENDPOINT="${MINIO_ENDPOINT:-http://minio.minio.svc.cluster.local:9000}"
  export AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER:-minioadmin}"
  export AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD:-minioadmin-changeme-prod}"

  if ! command -v s5cmd >/dev/null 2>&1; then
    log_error "s5cmd not found in PATH"
    return 1
  fi
  log_info "S3 client configured (s5cmd): ${S5_ENDPOINT}"
}

# s5 - run s5cmd against the configured endpoint (global flags allowed first,
# e.g. `s5 --json ls s3://...`)
s5() {
  local pre=()
  while [[ "${1:-}" == --* ]]; do pre+=("$1"); shift; done
  s5cmd "${pre[@]}" --endpoint-url "${S5_ENDPOINT}" "$@"
}

# ensure_bucket - Create bucket if it doesn't exist
#
# Args:
#   $1 - bucket name
ensure_bucket() {
  local bucket="$1" out
  # `ls` exits 1 both for a MISSING bucket (NotFound) and an EMPTY one
  # (no object found) — only the former needs an mb.
  if out="$(s5 ls "s3://${bucket}" 2>&1)" || grep -q "no object found" <<<"$out"; then
    log_info "Bucket '${bucket}' already exists"
    return 0
  fi
  log_info "Creating bucket '${bucket}'"
  if out="$(s5 mb "s3://${bucket}" 2>&1)"; then
    return 0
  fi
  # a concurrent creator is fine
  if grep -qiE "already (exists|owned)" <<<"$out"; then
    log_info "Bucket '${bucket}' already exists"
    return 0
  fi
  log_error "Failed to create bucket '${bucket}': ${out}"
  return 1
}

# upload_to_minio - Upload file to S3/MinIO with retry
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
    if s5 cp "${local_file}" "s3://${remote_path}"; then
      log_info "Upload successful: s3://${remote_path}"
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
