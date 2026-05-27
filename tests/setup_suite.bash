#!/usr/bin/env bash

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  export ROOT_DIR
  "${ROOT_DIR}/scripts/setup-clusters.sh"
  "${ROOT_DIR}/scripts/deploy-infra.sh"

  # shellcheck source=/dev/null
  source "${ROOT_DIR}/.env"

  export DB_MODE="${DB_MODE:-single}"
  export USE_MARIADB_OPERATOR="${USE_MARIADB_OPERATOR:-true}"
  export CLUSTER_DBS_CONTEXT="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
  export MONGO_TOPOLOGY="${MONGO_TOPOLOGY:-standalone}"
  export MARIADB_TOPOLOGY="${MARIADB_TOPOLOGY:-standalone}"

  # Load helpers (provides deploy_*_with_topology functions)
  load 'test_helper/common_setup'

  echo "=== setup_suite: deploying DB with MONGO_TOPOLOGY=${MONGO_TOPOLOGY} ==="
  deploy_mongodb_with_topology "mongo-1" "$MONGO_TOPOLOGY"

  echo "=== setup_suite: deploying MariaDB with MARIADB_TOPOLOGY=${MARIADB_TOPOLOGY} ==="
  deploy_mariadb_with_topology "mariadb-1" "$MARIADB_TOPOLOGY"
}

teardown_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  "${ROOT_DIR}/scripts/teardown.sh"
}
