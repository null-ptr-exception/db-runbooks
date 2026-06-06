#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi

# shellcheck source=aqsh-tasks/lib/mariadb-blue-green.sh
source "${LIB_DIR}/mariadb-blue-green.sh"

BACKUP_NAME="${BACKUP_NAME:-physicalbackup-blue}"
BACKUP_BUCKET="${BACKUP_BUCKET:?BACKUP_BUCKET is required}"
BACKUP_PREFIX="${BACKUP_PREFIX:?BACKUP_PREFIX is required}"
BACKUP_ENDPOINT="${BACKUP_ENDPOINT:?BACKUP_ENDPOINT is required}"
BACKUP_REGION="${BACKUP_REGION:-us-east-1}"
BACKUP_ACCESS_SECRET="${BACKUP_ACCESS_SECRET:-minio}"
BACKUP_ACCESS_KEY="${BACKUP_ACCESS_KEY:-access-key-id}"
BACKUP_SECRET_KEY="${BACKUP_SECRET_KEY:-secret-access-key}"
BACKUP_TARGET="${BACKUP_TARGET:-PreferReplica}"
BACKUP_COMPRESSION="${BACKUP_COMPRESSION:-bzip2}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"

bg_init_target
bg_require_confirm "blue-green/create-physical-backup"

source_status="$(bg_status_data "$(bg_get_mariadb_json)")"
ready_status="$(jq -r '.conditions[]? | select(.type == "Ready") | .status' <<<"$source_status" | tail -1)"
if [[ "$ready_status" != "True" ]]; then
  bg_fail "blue-green/create-physical-backup" "source MariaDB must be Ready before creating a PhysicalBackup" "$source_status"
fi

_kubectl apply -f - <<EOF
apiVersion: k8s.mariadb.com/v1alpha1
kind: PhysicalBackup
metadata:
  name: ${BACKUP_NAME}
  namespace: ${BG_NAMESPACE}
spec:
  mariaDbRef:
    name: ${BG_MDB}
  schedule:
    cron: "0 * * * *"
    immediate: true
  target: ${BACKUP_TARGET}
  compression: ${BACKUP_COMPRESSION}
  storage:
    s3:
      bucket: ${BACKUP_BUCKET}
      prefix: ${BACKUP_PREFIX}
      endpoint: ${BACKUP_ENDPOINT}
      region: ${BACKUP_REGION}
      accessKeyIdSecretKeyRef:
        name: ${BACKUP_ACCESS_SECRET}
        key: ${BACKUP_ACCESS_KEY}
      secretAccessKeySecretKeyRef:
        name: ${BACKUP_ACCESS_SECRET}
        key: ${BACKUP_SECRET_KEY}
EOF

_kubectl wait --for=condition=Complete "physicalbackup/${BACKUP_NAME}" --timeout="$WAIT_TIMEOUT"

data="$(jq -n \
  --arg namespace "$BG_NAMESPACE" \
  --arg source "$BG_MDB" \
  --arg backupName "$BACKUP_NAME" \
  --arg bucket "$BACKUP_BUCKET" \
  --arg prefix "$BACKUP_PREFIX" \
  --arg endpoint "$BACKUP_ENDPOINT" \
  --arg region "$BACKUP_REGION" \
  --argjson sourceStatus "$source_status" \
  '{
    namespace: $namespace,
    source: $source,
    backupName: $backupName,
    bucket: $bucket,
    prefix: $prefix,
    endpoint: $endpoint,
    region: $region,
    backupContentType: "Physical",
    sourceStatus: $sourceStatus
  }')"

bg_write_result "$(response_ok "blue-green/create-physical-backup" "physical backup completed" "$data")"
