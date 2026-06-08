#!/usr/bin/env bash
set -euo pipefail

# blue-green/create orchestrator
#
# Runs on the BLUE cluster's AQSH and provisions Green in one task:
#   create-physical-backup (local Blue) -> bootstrap-green (peer) ->
#   upgrade-green (peer, only if target_image differs from green_image).
#
# The Blue backup runs locally; Green provisioning runs over HTTP against the
# peer AQSH (PEER_AQSH_URL). This task never runs kubectl against Green.

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi

# shellcheck source=aqsh-tasks/lib/mariadb-blue-green.sh
source "${LIB_DIR}/mariadb-blue-green.sh"

OP="blue-green/create"

BLUE_NAME="${BLUE_NAME:?BLUE_NAME is required}"
GREEN_NAME="${GREEN_NAME:?GREEN_NAME is required}"
GREEN_NAMESPACE="${GREEN_NAMESPACE:-$BG_NAMESPACE}"
GREEN_IMAGE="${GREEN_IMAGE:?GREEN_IMAGE is required}"
TARGET_IMAGE="${TARGET_IMAGE:-}"
PEER_AQSH_URL="${PEER_AQSH_URL:?PEER_AQSH_URL is required}"
PEER_TOKEN="${PEER_TOKEN:?PEER_TOKEN is required}"

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

ROOT_SECRET_NAME="${ROOT_SECRET_NAME:-mariadb}"
ROOT_SECRET_KEY="${ROOT_SECRET_KEY:-password}"
STORAGE_SIZE="${STORAGE_SIZE:-1Gi}"
REPLICAS="${REPLICAS:-2}"
GTID_DOMAIN_ID="${GTID_DOMAIN_ID:-1}"
SERVER_ID_START_INDEX="${SERVER_ID_START_INDEX:-20}"
BLUE_HOST="${BLUE_HOST:-peer-db-proxy.db-ops.svc.cluster.local}"
GREEN_HOST="${GREEN_HOST:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"
PEER_TIMEOUT="${PEER_TIMEOUT:-900}"

BG_MDB="$BLUE_NAME"
bg_init_target
bg_require_confirm "$OP"

bg_validate_dns_label "blue_name" "$BLUE_NAME" "$OP"
bg_validate_dns_label "green_name" "$GREEN_NAME" "$OP"
bg_validate_dns_label "green_namespace" "$GREEN_NAMESPACE" "$OP"
bg_validate_image "green_image" "$GREEN_IMAGE" "$OP"
[[ -n "$TARGET_IMAGE" ]] && bg_validate_image "target_image" "$TARGET_IMAGE" "$OP"
bg_validate_url "peer_aqsh_url" "$PEER_AQSH_URL" "$OP"

# Step 1: physical backup of Blue (local cluster). Sets BG_BACKUP_DATA.
bg_create_physical_backup "$OP"
backup="$BG_BACKUP_DATA"

# Step 2: bootstrap Green from that backup (peer cluster).
bootstrap_payload="$(jq -n \
  --arg ns "$GREEN_NAMESPACE" --arg mdb "$GREEN_NAME" --arg blue "$BLUE_NAME" \
  --arg image "$GREEN_IMAGE" \
  --arg rootSecret "$ROOT_SECRET_NAME" --arg rootKey "$ROOT_SECRET_KEY" \
  --arg storage "$STORAGE_SIZE" --arg replicas "$REPLICAS" \
  --arg bucket "$BACKUP_BUCKET" --arg prefix "$BACKUP_PREFIX" --arg endpoint "$BACKUP_ENDPOINT" \
  --arg region "$BACKUP_REGION" --arg accessSecret "$BACKUP_ACCESS_SECRET" \
  --arg accessKey "$BACKUP_ACCESS_KEY" --arg secretKey "$BACKUP_SECRET_KEY" \
  --arg gtid "$GTID_DOMAIN_ID" --arg serverIdx "$SERVER_ID_START_INDEX" \
  --arg blueHost "$BLUE_HOST" --arg greenHost "$GREEN_HOST" --arg timeout "$WAIT_TIMEOUT" \
  '{
    namespace: $ns, mdb: $mdb, blue_name: $blue, green_image: $image,
    root_secret_name: $rootSecret, root_secret_key: $rootKey,
    storage_size: $storage, replicas: $replicas,
    backup_bucket: $bucket, backup_prefix: $prefix, backup_endpoint: $endpoint,
    backup_region: $region, backup_access_secret: $accessSecret,
    backup_access_key: $accessKey, backup_secret_key: $secretKey,
    gtid_domain_id: $gtid, server_id_start_index: $serverIdx,
    blue_host: $blueHost, green_host: $greenHost,
    wait_ready: "true", wait_timeout: $timeout, confirm: "true"
  } | with_entries(select(.value != ""))')"

bootstrap="$(bg_peer_call_task "$OP" "$PEER_AQSH_URL" "$PEER_TOKEN" "blue-green/bootstrap-green" \
  "$bootstrap_payload" "$PEER_TIMEOUT")" \
  || bg_fail "$OP" "bootstrap of green failed" "$BG_PEER_ERR"

# Step 3: upgrade Green to the target image (peer cluster), only if requested
# and different from the bootstrap image.
upgrade="{}"
if [[ -n "$TARGET_IMAGE" && "$TARGET_IMAGE" != "$GREEN_IMAGE" ]]; then
  upgrade="$(bg_peer_call_task "$OP" "$PEER_AQSH_URL" "$PEER_TOKEN" "blue-green/upgrade-green" \
    "$(jq -n --arg ns "$GREEN_NAMESPACE" --arg mdb "$GREEN_NAME" --arg image "$TARGET_IMAGE" \
      --arg timeout "$WAIT_TIMEOUT" \
      '{namespace: $ns, mdb: $mdb, target_image: $image, wait_ready: "true", wait_timeout: $timeout, confirm: "true"}')" \
    "$PEER_TIMEOUT")" \
    || bg_fail "$OP" "upgrade of green failed" "$BG_PEER_ERR"
fi

data="$(jq -n \
  --arg blue "$BLUE_NAME" --arg green "$GREEN_NAME" \
  --arg blueNamespace "$BG_NAMESPACE" --arg greenNamespace "$GREEN_NAMESPACE" \
  --argjson backup "$backup" --argjson bootstrap "$bootstrap" --argjson upgrade "$upgrade" \
  '{
    blue: $blue, green: $green,
    blueNamespace: $blueNamespace, greenNamespace: $greenNamespace,
    backup: $backup, bootstrap: $bootstrap, upgrade: $upgrade
  }')"

bg_write_result "$(response_ok "$OP" "green provisioned from blue physical backup" "$data")"
