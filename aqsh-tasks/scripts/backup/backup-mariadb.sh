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

DB_NAMESPACE="${DB_NAMESPACE:?DB_NAMESPACE is required}"
BACKUP_DATABASES="${BACKUP_DATABASES:---all-databases}"

mdbt_validate_dns_label "namespace" "$DB_NAMESPACE" "backup"
mariadb_set_target "${K8S_CONTEXT:-}" "$DB_NAMESPACE" "$MARIADB_RESOURCE" "$MDB_INPUT"
if [[ -z "$MDB_INPUT" ]]; then
  _on_ambiguous() {
    mdbt_fail "backup" "several MariaDB instances exist; set 'mariadb' to select one" \
      "$(jq -n --arg c "$1" '{candidateCount:($c|split(",")|length)}')" 2
  }
  _on_none() { mdbt_fail "backup" "no MariaDB instance found in the selected namespace" "{}" 2; }
  mariadb_autodetect_target false _on_ambiguous _on_none
else
  MARIADB_NAME="$MDB_INPUT"
fi

if ! mdbt_resolve_backup_location "$DB_NAMESPACE" "$MARIADB_NAME"; then
  mdbt_fail "backup" "failed to resolve object storage for the selected MariaDB: ${MDBT_S3_ERROR}" \
    "$(jq -n --arg ns "$DB_NAMESPACE" '{namespace:$ns}')" 2
fi

log_info "Starting MariaDB backup for namespace: ${DB_NAMESPACE}"

POD_NAME="$(mariadb_list_pods | head -1)"

if [[ -z "$POD_NAME" ]]; then
  mdbt_fail "backup" "no Pod found for the selected MariaDB" \
    "$(jq -n --arg ns "$DB_NAMESPACE" --arg mdb "$MARIADB_NAME" '{namespace:$ns,mariadb:$mdb}')" 2
fi

log_info "Using pod: ${POD_NAME}"

# Check if pod exists and is ready
if ! _kubectl get pod "${POD_NAME}" &>/dev/null; then
  log_error "Pod ${POD_NAME} not found in namespace ${DB_NAMESPACE}"
  response_err "backup" "Pod ${POD_NAME} not found in namespace ${DB_NAMESPACE}" > "$AQSH_RESULT_FILE"
  exit 1
fi

if ! _kubectl wait pod "${POD_NAME}" --for=condition=Ready --timeout=30s; then
  log_error "Pod ${POD_NAME} is not ready"
  response_err "backup" "Pod ${POD_NAME} is not ready" > "$AQSH_RESULT_FILE"
  exit 1
fi

# Generate backup filename with timestamp
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="mariadb-${DB_NAMESPACE}-${TIMESTAMP}.sql.gz"
LOCAL_PATH="/tmp/${BACKUP_NAME}"

log_info "Backup filename: ${BACKUP_NAME}"

# Get root password from secret
ROOT_PASSWORD=$(_kubectl get secret mariadb -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")

if [[ -z "$ROOT_PASSWORD" ]]; then
  log_warn "Could not retrieve root password from secret, trying without password"
  PASSWORD_ARG=""
else
  PASSWORD_ARG="-p${ROOT_PASSWORD}"
fi

# Perform backup
log_info "Dumping database(s): ${BACKUP_DATABASES}"
if _kubectl exec "${POD_NAME}" -- \
  mariadb-dump ${BACKUP_DATABASES} \
    --single-transaction \
    --quick \
    --lock-tables=false \
    -u root ${PASSWORD_ARG} \
  | gzip > "${LOCAL_PATH}"; then
  log_info "Database dump completed"
else
  log_error "Database dump failed"
  response_err "backup" "Database dump failed for ${DB_NAMESPACE}" > "$AQSH_RESULT_FILE"
  exit 1
fi

# Get backup file size
BACKUP_SIZE=$(stat -c%s "${LOCAL_PATH}" 2>/dev/null || echo "0")
BACKUP_SIZE_MB=$(( BACKUP_SIZE / 1024 / 1024 ))
log_info "Backup size: ${BACKUP_SIZE_MB} MB"

# Setup the direct S3 client without rendering credential values.
if ! mdbt_s3_prepare_direct_client; then
  log_error "Failed to resolve S3 credentials"
  rm -f "${LOCAL_PATH}"
  response_err "backup" "Failed to resolve S3 credentials" > "$AQSH_RESULT_FILE"
  exit 1
fi

# Setup MinIO client
if ! setup_minio_client; then
  log_error "Failed to setup MinIO client"
  rm -f "${LOCAL_PATH}"
  response_err "backup" "Failed to configure MinIO client" > "$AQSH_RESULT_FILE"
  exit 1
fi

# Ensure bucket exists
ensure_bucket "${BACKUP_BUCKET}"

# Upload to MinIO
REMOTE_PATH="${BACKUP_BUCKET}/${BACKUP_PREFIX}/${BACKUP_NAME}"
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
  --arg bucket "$BACKUP_BUCKET" \
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
