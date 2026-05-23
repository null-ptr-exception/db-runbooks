#!/usr/bin/env bash
# setup-replication.sh — Configure cross-region DB replication (multi mode only)
#
# MariaDB: Prefer mariadb-operator native replication via MariaDB CR spec.replication
# MongoDB: Adds region-b members to each replica set initiated in region-a
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

# shellcheck source=/dev/null
source "$ENV_FILE"

echo "=== Setting up cross-region replication ==="
MONGO_REPLICATION_MODE="${MONGO_REPLICATION_MODE:-3+3}"

mariadb_supports_external_primary() {
  kubectl --context kind-cluster-region-b explain mariadbs.spec.replication.replica.externalPrimary >/dev/null 2>&1
}

patch_mariadb_primary_mode() {
  local context="$1"
  local ns="$2"
  kubectl --context "$context" -n "$ns" patch mariadb mariadb --type merge -p \
    '{"spec":{"replication":{"enabled":true,"primary":{"podIndex":0,"automaticFailover":false}}}}'
}

setup_mariadb_replication_fallback() {
  local ns="$1"
  local port="$2"

  echo "--- MariaDB replication fallback (CHANGE MASTER TO only): ${ns} ---"

  patch_mariadb_primary_mode kind-cluster-region-a "$ns"
  patch_mariadb_primary_mode kind-cluster-region-b "$ns"

  local ROOT_PASS_B REPL_USER REPL_PASS
  ROOT_PASS_B=$(kubectl --context kind-cluster-region-b -n "$ns" \
    get secret mariadb -o jsonpath='{.data.password}' | base64 -d)
  REPL_USER=$(kubectl --context kind-cluster-region-b -n db-ops \
    get secret mariadb-replication-user -o jsonpath='{.data.REPLICATION_USER}' | base64 -d)
  REPL_PASS=$(kubectl --context kind-cluster-region-b -n db-ops \
    get secret mariadb-replication-user -o jsonpath='{.data.REPLICATION_PASSWORD}' | base64 -d)

  kubectl --context kind-cluster-region-b -n "$ns" exec mariadb-0 -- \
    mariadb -uroot -p"${ROOT_PASS_B}" -e "
      STOP SLAVE;
      CHANGE MASTER TO
        MASTER_HOST='${REGION_A_IP}',
        MASTER_PORT=${port},
        MASTER_USER='${REPL_USER}',
        MASTER_PASSWORD='${REPL_PASS}',
        MASTER_USE_GTID=current_pos;
      START SLAVE;
    "
}

wait_mariadb_replication() {
  local ns="$1"
  for _ in $(seq 1 30); do
    if kubectl --context kind-cluster-region-b -n "$ns" exec mariadb-0 -- \
      mariadb -N -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -q "Slave_IO_Running: Yes"; then
      echo "  MariaDB replication healthy for ${ns}"
      return 0
    fi
    sleep 2
  done
  echo "  WARN: MariaDB replication not ready yet for ${ns}"
}

# ─────────────────────────────────────────────
# MongoDB RS: add region-b member to each RS
# region-a already has rs.initiate() with 1 member
# ─────────────────────────────────────────────
setup_mongo_replication() {
  local ns="$1"
  local stream_port="$2"
  local port="$3"

  echo "--- MongoDB RS expansion: ${ns} ---"

  local ROOT_USER ROOT_PASS

  ROOT_USER=$(kubectl --context kind-cluster-region-a -n "$ns" \
    get secret mongodb-credentials -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  ROOT_PASS=$(kubectl --context kind-cluster-region-a -n "$ns" \
    get secret mongodb-credentials -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)

  local is_primary="false"
  for _ in $(seq 1 30); do
    is_primary=$(kubectl --context kind-cluster-region-a -n "$ns" exec mongodb-0 -- \
      mongosh --quiet --norc \
      -u "$ROOT_USER" -p "$ROOT_PASS" --authenticationDatabase admin \
      --eval "db.hello().isWritablePrimary ? 'true' : 'false'" 2>/dev/null | tail -n 1 | tr -d '\r')
    [[ "$is_primary" == "true" ]] && break
    sleep 2
  done
  [[ "$is_primary" == "true" ]] || {
    echo "  WARN: mongodb-0 is not primary for ${ns}, skipping"
    return 0
  }

  # Step 1: reconfig region-a primary member host from internal DNS to NodePort endpoint
  kubectl --context kind-cluster-region-a -n "$ns" exec mongodb-0 -- \
    mongosh --quiet --norc \
    -u "$ROOT_USER" -p "$ROOT_PASS" --authenticationDatabase admin \
    --eval "cfg = rs.conf(); cfg.members[0].host = '${REGION_A_IP}:${stream_port}'; rs.reconfig(cfg, {force: true});" \
    2>/dev/null || true

  sleep 3

  # Step 2: add region-b secondary through nginx TCP proxy
  kubectl --context kind-cluster-region-a -n "$ns" exec mongodb-0 -- \
    mongosh --quiet --norc \
    -u "$ROOT_USER" -p "$ROOT_PASS" --authenticationDatabase admin \
    --eval "cfg = rs.conf(); if (!cfg.members.some((m) => m.host === '${REGION_B_IP}:${port}')) { rs.add({host: '${REGION_B_IP}:${port}', priority: 1, votes: 1}); }" \
    2>/dev/null || echo "  rs.add already applied or not primary, skipping"

  echo "  RS member added: ${REGION_B_IP}:${port}"
}

if mariadb_supports_external_primary; then
  echo "MariaDB operator supports replica.externalPrimary; using operator-native replication CR"
else
  echo "MariaDB operator does not support replica.externalPrimary; using fallback script for CHANGE MASTER TO"
  setup_mariadb_replication_fallback mariadb-1 30093
  setup_mariadb_replication_fallback mariadb-2 30095
  setup_mariadb_replication_fallback mariadb-3 30097
fi

wait_mariadb_replication mariadb-1
wait_mariadb_replication mariadb-2
wait_mariadb_replication mariadb-3

if [[ "$MONGO_REPLICATION_MODE" == "3+1" ]]; then
  setup_mongo_replication mongo-1 30092 30092
else
  setup_mongo_replication mongo-1 30092 30092
  setup_mongo_replication mongo-2 30094 30094
  setup_mongo_replication mongo-3 30096 30096
fi

echo "=== Cross-region replication setup complete ==="
