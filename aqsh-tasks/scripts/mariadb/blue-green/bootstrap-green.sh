#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi

# shellcheck source=aqsh-tasks/lib/mariadb-blue-green.sh
source "${LIB_DIR}/mariadb-blue-green.sh"

BLUE_NAME="${BLUE_NAME:-}"
GREEN_IMAGE="${GREEN_IMAGE:-}"
ROOT_SECRET_NAME="${ROOT_SECRET_NAME:-mariadb}"
ROOT_SECRET_KEY="${ROOT_SECRET_KEY:-password}"
STORAGE_SIZE="${STORAGE_SIZE:-1Gi}"
REPLICAS="${REPLICAS:-2}"
BACKUP_BUCKET="${BACKUP_BUCKET:-}"
BACKUP_PREFIX="${BACKUP_PREFIX:-}"
BACKUP_ENDPOINT="${BACKUP_ENDPOINT:-}"
BACKUP_REGION="${BACKUP_REGION:-us-east-1}"
BACKUP_ACCESS_SECRET="${BACKUP_ACCESS_SECRET:-minio}"
BACKUP_ACCESS_KEY="${BACKUP_ACCESS_KEY:-access-key-id}"
BACKUP_SECRET_ACCESS_SECRET="${BACKUP_SECRET_ACCESS_SECRET:-$BACKUP_ACCESS_SECRET}"
BACKUP_SECRET_KEY="${BACKUP_SECRET_KEY:-secret-access-key}"
GTID_DOMAIN_ID="${GTID_DOMAIN_ID:-1}"
SERVER_ID_START_INDEX="${SERVER_ID_START_INDEX:-20}"
BLUE_HOST="${BLUE_HOST:-peer-db-proxy.db-ops.svc.cluster.local}"
GREEN_HOST="${GREEN_HOST:-}"
WAIT_READY="${WAIT_READY:-true}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"

bg_init_target
bg_require_confirm "blue-green/bootstrap-green"

GREEN_HOST="${GREEN_HOST:-${BG_MDB}-primary.${BG_NAMESPACE}.svc.cluster.local}"

bg_required "blue" "$BLUE_NAME" "blue-green/bootstrap-green"
bg_required "green_image" "$GREEN_IMAGE" "blue-green/bootstrap-green"
bg_validate_dns_label "namespace" "$BG_NAMESPACE" "blue-green/bootstrap-green"
bg_validate_dns_label "green" "$BG_MDB" "blue-green/bootstrap-green"
bg_validate_dns_label "blue" "$BLUE_NAME" "blue-green/bootstrap-green"
bg_validate_image "green_image" "$GREEN_IMAGE" "blue-green/bootstrap-green"
bg_validate_storage_size "storage_size" "$STORAGE_SIZE" "blue-green/bootstrap-green"
bg_validate_uint "replicas" "$REPLICAS" "blue-green/bootstrap-green"
bg_validate_uint "gtid_domain_id" "$GTID_DOMAIN_ID" "blue-green/bootstrap-green"
bg_validate_uint "server_id_start_index" "$SERVER_ID_START_INDEX" "blue-green/bootstrap-green"
bg_validate_endpoint "blue_host" "$BLUE_HOST" "blue-green/bootstrap-green"
bg_validate_endpoint "green_host" "$GREEN_HOST" "blue-green/bootstrap-green"

if ! (
  MDBT_RESULT_FILE=/dev/null
  bg_validate_dns_label "root_secret_name" "$ROOT_SECRET_NAME" "blue-green/bootstrap-green"
  bg_validate_secret_key "root_secret_key" "$ROOT_SECRET_KEY" "blue-green/bootstrap-green"
  bg_validate_s3_bucket "backup_bucket" "$BACKUP_BUCKET" "blue-green/bootstrap-green"
  bg_validate_s3_prefix "backup_prefix" "$BACKUP_PREFIX" "blue-green/bootstrap-green"
  bg_validate_endpoint "backup_endpoint" "$BACKUP_ENDPOINT" "blue-green/bootstrap-green"
  bg_validate_region "backup_region" "$BACKUP_REGION" "blue-green/bootstrap-green"
  bg_validate_dns_label "backup_access_secret" "$BACKUP_ACCESS_SECRET" "blue-green/bootstrap-green"
  bg_validate_secret_key "backup_access_key" "$BACKUP_ACCESS_KEY" "blue-green/bootstrap-green"
  bg_validate_dns_label "backup_secret_access_secret" "$BACKUP_SECRET_ACCESS_SECRET" "blue-green/bootstrap-green"
  bg_validate_secret_key "backup_secret_key" "$BACKUP_SECRET_KEY" "blue-green/bootstrap-green"
); then
  bg_fail "blue-green/bootstrap-green" "database configuration is unavailable" \
    '{"stage":"bootstrap","completed":false}' 1 BACKUP_CONFIGURATION_UNAVAILABLE
fi

if ! _kubectl apply -f - >/dev/null 2>&1 <<EOF
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
        name: ${BACKUP_SECRET_ACCESS_SECRET}
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
then
  bg_fail "blue-green/bootstrap-green" "database bootstrap could not be started" \
    '{"stage":"bootstrap","completed":false}' 1 INTERNAL_ERROR
fi

if [[ "$WAIT_READY" != "false" ]]; then
  if ! bg_wait_mariadb_ready "$BG_MDB" "$WAIT_TIMEOUT" >/dev/null 2>&1; then
    bg_fail "blue-green/bootstrap-green" "database bootstrap did not complete in time" \
      '{"stage":"bootstrap","completed":false}' 1 DATABASE_NOT_READY
  fi
fi

data="$(jq -n \
  --arg namespace "$BG_NAMESPACE" \
  --arg blue "$BLUE_NAME" \
  --arg green "$BG_MDB" \
  --arg version "$GREEN_IMAGE" \
  '{
    namespace: $namespace,
    blue: $blue,
    green: $green,
    stage: "bootstrap",
    completed: true,
    version: $version,
    replicationConfigured: true
  }')"

bg_write_result "$(response_ok "blue-green/bootstrap-green" "green MariaDB bootstrapped" "$data")"
