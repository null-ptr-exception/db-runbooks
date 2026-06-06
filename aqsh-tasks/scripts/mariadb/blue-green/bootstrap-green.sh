#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi

# shellcheck source=aqsh-tasks/lib/mariadb-blue-green.sh
source "${LIB_DIR}/mariadb-blue-green.sh"

BLUE_NAME="${BLUE_NAME:?BLUE_NAME is required}"
GREEN_IMAGE="${GREEN_IMAGE:-mariadb:10.6}"
ROOT_SECRET_NAME="${ROOT_SECRET_NAME:-mariadb}"
ROOT_SECRET_KEY="${ROOT_SECRET_KEY:-password}"
STORAGE_SIZE="${STORAGE_SIZE:-1Gi}"
REPLICAS="${REPLICAS:-2}"
BACKUP_BUCKET="${BACKUP_BUCKET:?BACKUP_BUCKET is required}"
BACKUP_PREFIX="${BACKUP_PREFIX:?BACKUP_PREFIX is required}"
BACKUP_ENDPOINT="${BACKUP_ENDPOINT:?BACKUP_ENDPOINT is required}"
BACKUP_REGION="${BACKUP_REGION:-us-east-1}"
BACKUP_ACCESS_SECRET="${BACKUP_ACCESS_SECRET:-minio}"
BACKUP_ACCESS_KEY="${BACKUP_ACCESS_KEY:-access-key-id}"
BACKUP_SECRET_KEY="${BACKUP_SECRET_KEY:-secret-access-key}"
GTID_DOMAIN_ID="${GTID_DOMAIN_ID:-1}"
SERVER_ID_START_INDEX="${SERVER_ID_START_INDEX:-20}"
BLUE_HOST="${BLUE_HOST:-peer-db-proxy.db-ops.svc.cluster.local}"
GREEN_HOST="${GREEN_HOST:-${BG_MDB}-primary.${BG_NAMESPACE}.svc.cluster.local}"
WAIT_READY="${WAIT_READY:-true}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"

bg_init_target
bg_require_confirm "blue-green/bootstrap-green"

_kubectl apply -f - <<EOF
apiVersion: k8s.mariadb.com/v1alpha1
kind: MariaDB
metadata:
  name: ${BG_MDB}
  namespace: ${BG_NAMESPACE}
spec:
  image: ${GREEN_IMAGE}
  rootPasswordSecretKeyRef:
    name: ${ROOT_SECRET_NAME}
    key: ${ROOT_SECRET_KEY}
  storage:
    size: ${STORAGE_SIZE}
  replicas: ${REPLICAS}
  bootstrapFrom:
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
    backupContentType: Physical
  replication:
    enabled: true
    gtidDomainId: ${GTID_DOMAIN_ID}
    gtidStrictMode: false
    serverIdStartIndex: ${SERVER_ID_START_INDEX}
    semiSyncEnabled: false
    replica:
      replPasswordSecretKeyRef:
        name: ${ROOT_SECRET_NAME}
        key: ${ROOT_SECRET_KEY}
  multiCluster:
    enabled: true
    primary: ${BLUE_NAME}
    members:
      - name: ${BLUE_NAME}
        externalMariaDbRef:
          name: ${BLUE_NAME}
      - name: ${BG_MDB}
        externalMariaDbRef:
          name: ${BG_MDB}
---
apiVersion: k8s.mariadb.com/v1alpha1
kind: ExternalMariaDB
metadata:
  name: ${BLUE_NAME}
  namespace: ${BG_NAMESPACE}
spec:
  host: ${BLUE_HOST}
  port: 3306
  username: root
  passwordSecretKeyRef:
    name: ${ROOT_SECRET_NAME}
    key: ${ROOT_SECRET_KEY}
---
apiVersion: k8s.mariadb.com/v1alpha1
kind: ExternalMariaDB
metadata:
  name: ${BG_MDB}
  namespace: ${BG_NAMESPACE}
spec:
  host: ${GREEN_HOST}
  port: 3306
  username: root
  passwordSecretKeyRef:
    name: ${ROOT_SECRET_NAME}
    key: ${ROOT_SECRET_KEY}
EOF

if [[ "$WAIT_READY" != "false" ]]; then
  bg_wait_mariadb_ready "$BG_MDB" "$WAIT_TIMEOUT"
fi

data="$(jq -n \
  --arg namespace "$BG_NAMESPACE" \
  --arg blue "$BLUE_NAME" \
  --arg green "$BG_MDB" \
  --arg image "$GREEN_IMAGE" \
  --arg bucket "$BACKUP_BUCKET" \
  --arg prefix "$BACKUP_PREFIX" \
  --arg endpoint "$BACKUP_ENDPOINT" \
  --arg primary "$BLUE_NAME" \
  '{
    namespace: $namespace,
    blue: $blue,
    green: $green,
    image: $image,
    backup: {bucket: $bucket, prefix: $prefix, endpoint: $endpoint, contentType: "Physical"},
    desiredMultiClusterPrimary: $primary
  }')"

bg_write_result "$(response_ok "blue-green/bootstrap-green" "green MariaDB bootstrapped" "$data")"
