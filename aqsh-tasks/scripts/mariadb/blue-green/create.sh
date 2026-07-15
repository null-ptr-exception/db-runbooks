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
BG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERNAL_STEP="${INTERNAL_STEP:-}"

BLUE_NAME="${BLUE_NAME:-}"
GREEN_NAME="${GREEN_NAME:-}"
GREEN_NAMESPACE="${GREEN_NAMESPACE:-$BG_NAMESPACE}"
GREEN_IMAGE="${GREEN_IMAGE:-}"
TARGET_IMAGE="${TARGET_IMAGE:-}"
PEER_AQSH_URL="${PEER_AQSH_URL:-}"
PEER_TOKEN="${PEER_TOKEN:-}"

BACKUP_NAME="${BACKUP_NAME:-physicalbackup-blue}"
# S3 backup location (bucket / prefix / endpoint) is resolved from deploy-time
# config + the per-namespace convention shared with restore — not passed by the
# caller — so a blue-green backup is restore-discoverable by namespace alone.
mdbt_load_config
BACKUP_REGION="${BACKUP_REGION:-}"
BACKUP_ACCESS_SECRET="${BACKUP_ACCESS_SECRET:-}"
BACKUP_ACCESS_KEY="${BACKUP_ACCESS_KEY:-}"
BACKUP_SECRET_ACCESS_SECRET="${BACKUP_SECRET_ACCESS_SECRET:-}"
BACKUP_SECRET_KEY="${BACKUP_SECRET_KEY:-}"
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
# Allowed replica lag for the final replication validation (AWS create
# completes with green replicating and in sync with blue).
LAG_THRESHOLD="${LAG_THRESHOLD:-0}"

case "$INTERNAL_STEP" in
  bootstrap)
    # Resolve again on Green from its local representation of Blue. Secret refs
    # are namespace/cluster-local, so this validates an independently provisioned
    # destination reference without transporting credential values from Blue.
    if ! _kubectl get mariadb "$BLUE_NAME" -o name >/dev/null 2>&1; then
      bg_fail "$OP" "destination has no local MariaDB storage policy for the selected Blue identity" \
        "$(jq -n --arg ns "$BG_NAMESPACE" --arg mdb "$BLUE_NAME" '{namespace:$ns,mariadb:$mdb}')" 2
    fi
    mdbt_resolve_backup_location "$BG_NAMESPACE" "$BLUE_NAME" \
      || bg_fail "$OP" "internal bootstrap storage resolution failed" \
        "$(jq -n '{storagePolicy:"unresolved"}')" 2
    result="$(bg_local_step "$BG_DIR/bootstrap-green.sh" \
      "DB_NAMESPACE=$BG_NAMESPACE" "MARIADB_NAME=$GREEN_NAME" \
      "BLUE_NAME=$BLUE_NAME" "GREEN_IMAGE=$GREEN_IMAGE" \
      "ROOT_SECRET_NAME=$ROOT_SECRET_NAME" "ROOT_SECRET_KEY=$ROOT_SECRET_KEY" \
      "STORAGE_SIZE=$STORAGE_SIZE" "REPLICAS=$REPLICAS" \
      "BACKUP_BUCKET=$BACKUP_BUCKET" "BACKUP_PREFIX=$BACKUP_PREFIX" \
      "BACKUP_ENDPOINT=$BACKUP_ENDPOINT" "BACKUP_REGION=$BACKUP_REGION" \
      "BACKUP_ACCESS_SECRET=$BACKUP_ACCESS_SECRET" \
      "BACKUP_ACCESS_KEY=$BACKUP_ACCESS_KEY" \
      "BACKUP_SECRET_ACCESS_SECRET=$BACKUP_SECRET_ACCESS_SECRET" "BACKUP_SECRET_KEY=$BACKUP_SECRET_KEY" \
      "GTID_DOMAIN_ID=$GTID_DOMAIN_ID" "SERVER_ID_START_INDEX=$SERVER_ID_START_INDEX" \
      "BLUE_HOST=$BLUE_HOST" "GREEN_HOST=$GREEN_HOST" \
      "WAIT_READY=true" "WAIT_TIMEOUT=$WAIT_TIMEOUT" "CONFIRM=true")" \
      || bg_fail "$OP" "internal bootstrap failed" "$BG_LOCAL_ERR"
    bg_write_result "$(response_ok "$OP" "internal bootstrap completed" "$result")"
    exit 0
    ;;
  upgrade)
    result="$(bg_local_step "$BG_DIR/upgrade-green.sh" \
      "DB_NAMESPACE=$BG_NAMESPACE" "MARIADB_NAME=$GREEN_NAME" \
      "TARGET_IMAGE=$TARGET_IMAGE" "WAIT_READY=true" "WAIT_TIMEOUT=$WAIT_TIMEOUT" "CONFIRM=true")" \
      || bg_fail "$OP" "internal upgrade failed" "$BG_LOCAL_ERR"
    bg_write_result "$(response_ok "$OP" "internal upgrade completed" "$result")"
    exit 0
    ;;
  "")
    ;;
  *)
    bg_fail "$OP" "internal_step is not supported" "$(jq -n --arg internalStep "$INTERNAL_STEP" '{internalStep: $internalStep}')" 2
    ;;
esac

bg_required "blue_name" "$BLUE_NAME" "$OP"
bg_required "green_name" "$GREEN_NAME" "$OP"
bg_required "green_image" "$GREEN_IMAGE" "$OP"
bg_required "peer_aqsh_url" "$PEER_AQSH_URL" "$OP"
bg_required "peer_token" "$PEER_TOKEN" "$OP"

BG_MDB="$BLUE_NAME"
bg_init_target
if ! mdbt_resolve_backup_location "$BG_NAMESPACE" "$BLUE_NAME"; then
  bg_fail "$OP" "failed to resolve object storage for the selected Blue MariaDB: ${MDBT_S3_ERROR}" \
    "$(jq -n --arg ns "$BG_NAMESPACE" --arg mdb "$BLUE_NAME" '{namespace:$ns,mariadb:$mdb}')" 2
fi
bg_require_confirm "$OP"

bg_validate_dns_label "blue_name" "$BLUE_NAME" "$OP"
bg_validate_dns_label "green_name" "$GREEN_NAME" "$OP"
bg_validate_dns_label "green_namespace" "$GREEN_NAMESPACE" "$OP"
bg_validate_image "green_image" "$GREEN_IMAGE" "$OP"
[[ -n "$TARGET_IMAGE" ]] && bg_validate_image "target_image" "$TARGET_IMAGE" "$OP"
bg_validate_url "peer_aqsh_url" "$PEER_AQSH_URL" "$OP"

# The backup location is resolved per-namespace and Green re-resolves it from its
# own namespace, so a cross-namespace Green would look under a different prefix
# than the one Blue wrote and find no backup. Reject it up front rather than fail
# obscurely at bootstrap time.
if [[ "$GREEN_NAMESPACE" != "$BG_NAMESPACE" ]]; then
  bg_fail "$OP" "green_namespace ('${GREEN_NAMESPACE}') must match the source namespace ('${BG_NAMESPACE}'): the backup location is resolved per-namespace, so a cross-namespace green cannot find blue's backup" \
    "$(jq -n --arg s "$BG_NAMESPACE" --arg g "$GREEN_NAMESPACE" '{source_namespace: $s, green_namespace: $g}')" 2
fi

# Step 1: physical backup of Blue (local cluster). Sets BG_BACKUP_DATA.
bg_create_physical_backup "$OP"
backup="$BG_BACKUP_DATA"

# Step 2: bootstrap Green from that backup (peer cluster).
bootstrap_payload="$(jq -n \
  --arg ns "$GREEN_NAMESPACE" --arg mdb "$GREEN_NAME" --arg blue "$BLUE_NAME" \
  --arg image "$GREEN_IMAGE" \
  --arg storage "$STORAGE_SIZE" --arg replicas "$REPLICAS" \
  --arg gtid "$GTID_DOMAIN_ID" --arg serverIdx "$SERVER_ID_START_INDEX" \
  --arg blueHost "$BLUE_HOST" --arg greenHost "$GREEN_HOST" --arg timeout "$WAIT_TIMEOUT" \
  '{
    namespace: $ns, green_name: $mdb, blue_name: $blue, green_image: $image,
    storage_size: $storage, replicas: $replicas,
    gtid_domain_id: $gtid, server_id_start_index: $serverIdx,
    blue_host: $blueHost, green_host: $greenHost,
    internal_step: "bootstrap",
    wait_ready: "true", wait_timeout: $timeout, confirm: "true"
  } | with_entries(select(.value != ""))')"
  # Managed-DB internals are NOT forwarded. Green resolves the same selected
  # Blue identity locally, allowing cluster-local endpoint and Secret refs while
  # requiring its bucket/prefix policy to point at the shared backup objects.

bootstrap="$(bg_peer_call_task "$OP" "$PEER_AQSH_URL" "$PEER_TOKEN" "blue-green/create" \
  "$bootstrap_payload" "$PEER_TIMEOUT")" \
  || bg_fail "$OP" "bootstrap of green failed" "$BG_PEER_ERR"

# Step 3: upgrade Green to the target image (peer cluster), only if requested
# and different from the bootstrap image.
upgrade="{}"
if [[ -n "$TARGET_IMAGE" && "$TARGET_IMAGE" != "$GREEN_IMAGE" ]]; then
  upgrade="$(bg_peer_call_task "$OP" "$PEER_AQSH_URL" "$PEER_TOKEN" "blue-green/create" \
    "$(jq -n \
      --arg ns "$GREEN_NAMESPACE" --arg mdb "$GREEN_NAME" --arg blue "$BLUE_NAME" \
      --arg greenImage "$GREEN_IMAGE" --arg image "$TARGET_IMAGE" \
      --arg timeout "$WAIT_TIMEOUT" \
      '{
        namespace: $ns, green_name: $mdb, blue_name: $blue, green_image: $greenImage,
        target_image: $image, internal_step: "upgrade",
        wait_ready: "true", wait_timeout: $timeout, confirm: "true"
      }')" \
    "$PEER_TIMEOUT")" \
    || bg_fail "$OP" "upgrade of green failed" "$BG_PEER_ERR"
fi

# Step 4: final validation — create only succeeds when Green is a healthy
# replica of Blue caught up within lag_threshold (AWS create completes with
# green replicating and in sync). The validate internal step is hosted by the
# blue-green/switchover task on the peer.
final_validate="$(bg_peer_call_task "$OP" "$PEER_AQSH_URL" "$PEER_TOKEN" "blue-green/switchover" \
  "$(jq -n --arg ns "$GREEN_NAMESPACE" --arg mdb "$GREEN_NAME" --arg blue "$BLUE_NAME" \
    --arg lag "$LAG_THRESHOLD" \
    '{namespace: $ns, green_name: $mdb, blue_name: $blue, expected_primary: $blue, check_replication: "true", lag_threshold: $lag, internal_step: "validate"}')" \
  "$PEER_TIMEOUT")" \
  || bg_fail "$OP" "green was provisioned but did not validate as a caught-up replica of blue" "$BG_PEER_ERR"

data="$(jq -n \
  --arg blue "$BLUE_NAME" --arg green "$GREEN_NAME" \
  --arg blueNamespace "$BG_NAMESPACE" --arg greenNamespace "$GREEN_NAMESPACE" \
  --argjson backup "$backup" --argjson bootstrap "$bootstrap" --argjson upgrade "$upgrade" \
  --argjson finalValidate "$final_validate" \
  '{
    blue: $blue, green: $green,
    blueNamespace: $blueNamespace, greenNamespace: $greenNamespace,
    backup: $backup, bootstrap: $bootstrap, upgrade: $upgrade,
    replicationValidate: $finalValidate
  }')"

bg_write_result "$(response_ok "$OP" "green provisioned from blue physical backup" "$data")"
