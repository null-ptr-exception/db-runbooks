#!/usr/bin/env bash

BG_NAMESPACE="${BG_NAMESPACE:-mariadb-bg}"
BLUE_CONTEXT="${BLUE_CONTEXT:-kind-cluster-dbs-a}"
GREEN_CONTEXT="${GREEN_CONTEXT:-kind-cluster-dbs-b}"
MINIO_CONTEXT="${MINIO_CONTEXT:-kind-cluster-minio}"
MINIO_BUCKET="${MINIO_BUCKET:-multi-cluster}"
MINIO_PREFIX="${MINIO_PREFIX:-${BG_NAMESPACE}/blue}"
BG_NODEPORT="${BG_NODEPORT:-30091}"
PEER_DB_PROXY_HOST="${PEER_DB_PROXY_HOST:-peer-db-proxy.db-ops.svc.cluster.local}"
MINIO_ACCESS_KEY_ID="${MINIO_ACCESS_KEY_ID:-minioadmin}"
MINIO_SECRET_ACCESS_KEY="${MINIO_SECRET_ACCESS_KEY:-minioadmin-changeme-prod}"
MARIADB_ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD:-mariadb-bg-root-pass}"
BLUE_IMAGE="${BLUE_IMAGE:-mariadb:10.6.27}"
GREEN_BOOTSTRAP_IMAGE="${GREEN_BOOTSTRAP_IMAGE:-mariadb:10.6.27}"
GREEN_UPGRADE_IMAGE="${GREEN_UPGRADE_IMAGE:-mariadb:10.11.18}"

load_demo_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Missing ${ENV_FILE}; run setup-clusters.sh first." >&2
    exit 1
  fi

  # shellcheck source=/dev/null
  source "$ENV_FILE"

  if [[ "${DB_MODE:-}" != "dual" ]]; then
    echo "DB_MODE must be dual for this demo; current: ${DB_MODE:-unset}" >&2
    exit 1
  fi
  if [[ "${ENABLE_MINIO:-}" != "true" ]]; then
    echo "ENABLE_MINIO must be true for this demo; current: ${ENABLE_MINIO:-unset}" >&2
    exit 1
  fi
  if [[ "${USE_MARIADB_OPERATOR:-}" != "true" ]]; then
    echo "USE_MARIADB_OPERATOR must be true for this demo; current: ${USE_MARIADB_OPERATOR:-unset} in ${ENV_FILE}" >&2
    exit 1
  fi
  if [[ -z "${CLUSTER_MINIO_IP:-}" ]]; then
    echo "CLUSTER_MINIO_IP is missing from ${ENV_FILE}" >&2
    exit 1
  fi

  MINIO_ENDPOINT="${MINIO_ENDPOINT:-${CLUSTER_MINIO_IP}:30092}"
  export BG_NAMESPACE MINIO_BUCKET MINIO_PREFIX BG_NODEPORT PEER_DB_PROXY_HOST
  export MINIO_ACCESS_KEY_ID MINIO_SECRET_ACCESS_KEY
  export MARIADB_ROOT_PASSWORD MINIO_ENDPOINT
  export BLUE_IMAGE GREEN_BOOTSTRAP_IMAGE GREEN_UPGRADE_IMAGE
}

render_apply() {
  local ctx="$1" template="$2"
  envsubst < "${TEMPLATE_DIR}/${template}" | kubectl --context "$ctx" apply -f -
}

apply_nodeport() {
  local ctx="$1" member="$2"
  BG_MEMBER="$member" envsubst < "${TEMPLATE_DIR}/primary-nodeport.yaml.tpl" \
    | kubectl --context "$ctx" apply -f -
}

wait_mariadb_ready() {
  local ctx="$1" name="$2" timeout="${3:-10m}"
  kubectl --context "$ctx" -n "$BG_NAMESPACE" wait \
    --for=condition=Ready "mariadb/${name}" --timeout="$timeout"
}

wait_backup_complete() {
  kubectl --context "$BLUE_CONTEXT" -n "$BG_NAMESPACE" wait \
    --for=condition=Complete physicalbackup/physicalbackup-blue --timeout=10m
}

ensure_minio_bucket() {
  kubectl --context "$MINIO_CONTEXT" -n minio wait pod \
    -l app=minio --for=condition=Ready --timeout=120s

  # shellcheck disable=SC2016
  kubectl --context "$BLUE_CONTEXT" -n db-ops exec deploy/aqsh-mariadb -c aqsh -- \
    sh -ceu 'mc alias set demo "$1" "$2" "$3" --api S3v4 >/dev/null && (mc ls "demo/$4" >/dev/null 2>&1 || mc mb "demo/$4" >/dev/null)' \
    sh "http://${MINIO_ENDPOINT}" "$MINIO_ACCESS_KEY_ID" "$MINIO_SECRET_ACCESS_KEY" "$MINIO_BUCKET"
}

sql_exec() {
  local ctx="$1" pod="$2" sql="$3"
  kubectl --context "$ctx" -n "$BG_NAMESPACE" exec "$pod" -c mariadb -- \
    mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -N -B -e "$sql"
}

replication_caught_up() {
  kubectl --context "$GREEN_CONTEXT" -n "$BG_NAMESPACE" get mariadb mariadb-green -o json \
    | jq -e '
      .status.replication.replicas
      | to_entries
      | map(select(.value.slaveIORunning == true and .value.slaveSQLRunning == true and (.value.secondsBehindMaster // 0) == 0))
      | length > 0
    ' >/dev/null
}

apply_demo() {
  load_demo_env
  echo "== Prepare namespace and shared secrets =="
  render_apply "$BLUE_CONTEXT" secrets.yaml.tpl
  render_apply "$GREEN_CONTEXT" secrets.yaml.tpl
  render_apply "$BLUE_CONTEXT" rbac.yaml.tpl
  render_apply "$GREEN_CONTEXT" rbac.yaml.tpl
  ensure_minio_bucket

  echo "== Deploy Blue (MariaDB 10.6) =="
  render_apply "$BLUE_CONTEXT" blue.yaml.tpl
  apply_nodeport "$BLUE_CONTEXT" mariadb-blue
  wait_mariadb_ready "$BLUE_CONTEXT" mariadb-blue

  echo "== Create Blue physical backup =="
  render_apply "$BLUE_CONTEXT" blue-backup.yaml.tpl
  wait_backup_complete

  echo "== Bootstrap Green from Blue backup (MariaDB 10.6) =="
  render_apply "$GREEN_CONTEXT" green-bootstrap.yaml.tpl
  apply_nodeport "$GREEN_CONTEXT" mariadb-green
  wait_mariadb_ready "$GREEN_CONTEXT" mariadb-green

  echo "== Upgrade Green to MariaDB 10.11 =="
  render_apply "$GREEN_CONTEXT" green-upgrade-10.11.yaml.tpl
  wait_mariadb_ready "$GREEN_CONTEXT" mariadb-green
}

validate_demo() {
  load_demo_env
  wait_mariadb_ready "$BLUE_CONTEXT" mariadb-blue 2m
  wait_mariadb_ready "$GREEN_CONTEXT" mariadb-green 2m

  local blue_version green_version replicated_count
  blue_version="$(sql_exec "$BLUE_CONTEXT" mariadb-blue-0 'SELECT @@version;')"
  green_version="$(sql_exec "$GREEN_CONTEXT" mariadb-green-0 'SELECT @@version;')"

  case "$blue_version" in
    10.6*) ;;
    *) echo "Expected Blue 10.6.x, got: ${blue_version}" >&2; exit 1 ;;
  esac
  case "$green_version" in
    10.11*) ;;
    *) echo "Expected Green 10.11.x, got: ${green_version}" >&2; exit 1 ;;
  esac

  sql_exec "$BLUE_CONTEXT" mariadb-blue-0 '
CREATE DATABASE IF NOT EXISTS bgtest;
CREATE TABLE IF NOT EXISTS bgtest.events (id INT PRIMARY KEY, note VARCHAR(64));
INSERT INTO bgtest.events VALUES (1, "from-blue")
  ON DUPLICATE KEY UPDATE note = VALUES(note);
' >/dev/null

  # This demo uses a short propagation wait before checking the Green replica.
  sleep 5
  replicated_count="$(sql_exec "$GREEN_CONTEXT" mariadb-green-0 'SELECT COUNT(*) FROM bgtest.events WHERE id = 1 AND note = "from-blue";')"
  if [[ "$replicated_count" != "1" ]]; then
    echo "Expected Blue write to replicate to Green; count=${replicated_count}" >&2
    exit 1
  fi

  if ! replication_caught_up; then
    echo "Green replication is not caught up." >&2
    kubectl --context "$GREEN_CONTEXT" -n "$BG_NAMESPACE" get mariadb mariadb-green -o jsonpath='{.status.replication}' | jq .
    exit 1
  fi

  echo "Blue version:  ${blue_version}"
  echo "Green version: ${green_version}"
  echo "Replication:   caught up"
}

cutover_demo() {
  load_demo_env
  validate_demo

  echo "== Put Blue into maintenance/read-only mode =="
  kubectl --context "$BLUE_CONTEXT" -n "$BG_NAMESPACE" patch mariadb mariadb-blue --type merge -p '{
    "spec": {
      "maintenance": {
        "enabled": true,
        "cordon": true,
        "drainConnections": true,
        "drainGracePeriodSeconds": 30,
        "readOnly": true
      }
    }
  }'

  if ! replication_caught_up; then
    echo "Green replication is not caught up before promotion." >&2
    exit 1
  fi

  echo "== Promote Green =="
  kubectl --context "$GREEN_CONTEXT" -n "$BG_NAMESPACE" patch mariadb mariadb-green --type merge \
    -p '{"spec":{"multiCluster":{"primary":"mariadb-green"}}}'
  wait_mariadb_ready "$GREEN_CONTEXT" mariadb-green 10m

  echo "== Demote Blue to follow Green =="
  kubectl --context "$BLUE_CONTEXT" -n "$BG_NAMESPACE" patch mariadb mariadb-blue --type merge \
    -p '{"spec":{"multiCluster":{"primary":"mariadb-green"}}}'

  sql_exec "$GREEN_CONTEXT" mariadb-green-0 '
INSERT INTO bgtest.events VALUES (2, "written-after-cutover")
  ON DUPLICATE KEY UPDATE note = VALUES(note);
' >/dev/null

  echo "Cutover complete; Green accepts writes."
}

status_demo() {
  load_demo_env
  for item in "$BLUE_CONTEXT:mariadb-blue" "$GREEN_CONTEXT:mariadb-green"; do
    local ctx="${item%%:*}" name="${item##*:}"
    echo "== ${ctx}/${name} =="
    kubectl --context "$ctx" -n "$BG_NAMESPACE" get mariadb "$name" -o wide || true
    kubectl --context "$ctx" -n "$BG_NAMESPACE" get mariadb "$name" \
      -o jsonpath='{.status.currentPrimary}{" primaryCluster="}{.status.currentMultiClusterPrimary}{"\n"}' 2>/dev/null || true
  done
}

cleanup_demo() {
  load_demo_env
  kubectl --context "$BLUE_CONTEXT" delete namespace "$BG_NAMESPACE" --ignore-not-found
  kubectl --context "$GREEN_CONTEXT" delete namespace "$BG_NAMESPACE" --ignore-not-found
}
