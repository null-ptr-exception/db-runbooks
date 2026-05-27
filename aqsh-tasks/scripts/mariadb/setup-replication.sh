#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/setup-replication.sh
# aqsh task: Configure GTID-based MariaDB replication across clusters.
#
# Runs on the PRIMARY cluster (cluster-a). Sets up replication from:
#   - mariadb-0 (cluster-a) as PRIMARY
#   - mariadb-1 (cluster-a) as in-cluster REPLICA via headless DNS
#   - mariadb-0 (cluster-b) as cross-cluster REPLICA via NodePort
#
# Topology values (REPL_TOPOLOGY):
#   "2+1" — cluster-a: 2 pods, cluster-b: 1 pod
#   "1+2" — cluster-a: 1 pod, cluster-b: 2 pods
#   "3+0" — cluster-a: 3 pods, cluster-b: 0
#
# NodePort layout (must match k8s/cluster-dbs/mariadb/nodeport-*.yaml):
#   pod-0: 30091   pod-1: 30095   pod-2: 30097
#
# Idempotent: replicas with an already-running Slave_IO_Thread are skipped.
#
# Inputs (injected by aqsh from tasks.yaml):
#   DB_NAMESPACE    — target namespace, e.g. "mariadb-1"
#   REPL_TOPOLOGY   — "2+1" | "1+2" | "3+0"
#   CLUSTER_A_IP    — Node IP of cluster-dbs-a (or cluster-dbs for 3+0)
#   CLUSTER_B_IP    — Node IP of cluster-dbs-b (required for 2+1 / 1+2)
#
# Writes JSON result to $AQSH_RESULT_FILE.
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"

CRED_SECRET="${MARIADB_CRED_SECRET:-mariadb}"
CRED_PASS_KEY="${MARIADB_CRED_PASS_KEY:-password}"
REPL_USER="repl"
REPL_PASS_LEN=24

log_info "setup-replication" "Starting MariaDB replication setup: namespace=${DB_NAMESPACE} topology=${REPL_TOPOLOGY}"

# ── Helpers ───────────────────────────────────────────────────────────────────
_preflight_critical() {
  local reason="${1:-preflight failed}"
  log_error "setup-replication" "Preflight failed: ${reason}"
  jq -n \
    --arg status    "critical" \
    --arg reason    "${reason}" \
    --arg namespace "${DB_NAMESPACE}" \
    '{status: $status, namespace: $namespace, reason: $reason}' \
    > "$AQSH_RESULT_FILE"
  exit 1
}

# Run a SQL query on a specific pod via kubectl exec.
# Usage: _mariadb_exec <pod> <namespace> <root_pass> <sql>
_mariadb_exec() {
  local pod="$1" ns="$2" pass="$3" sql="$4"
  kubectl -n "$ns" exec "$pod" -- \
    sh -c "MARIADB_PWD='${pass}' mariadb -u root --protocol=tcp -s -N -e '${sql}' 2>/dev/null"
}

# Check if Slave_IO_Running is already active on a replica pod.
_slave_running() {
  local pod="$1" ns="$2" pass="$3"
  local status
  status=$(_mariadb_exec "$pod" "$ns" "$pass" "SHOW SLAVE STATUS\G" 2>/dev/null || true)
  echo "$status" | grep -q "Slave_IO_Running: Yes"
}

# ── Read credentials ──────────────────────────────────────────────────────────
export K8S_NAMESPACE="${DB_NAMESPACE}"

ROOT_PASS=$(kubectl -n "${DB_NAMESPACE}" get secret "${CRED_SECRET}" \
  -o jsonpath="{.data.${CRED_PASS_KEY}}" 2>/dev/null | base64 -d) || \
  _preflight_critical "cannot read '${CRED_PASS_KEY}' from secret '${CRED_SECRET}' in ${DB_NAMESPACE}"

# ── Validate topology and build replica list ──────────────────────────────────
# Format: "pod_name:primary_host:primary_port"
# in-cluster replicas use headless DNS; cross-cluster replicas use NodePort IP
declare -a REPLICAS=()

case "${REPL_TOPOLOGY}" in
  2+1)
    [[ -z "${CLUSTER_A_IP:-}" ]] && _preflight_critical "CLUSTER_A_IP required for topology ${REPL_TOPOLOGY}"
    [[ -z "${CLUSTER_B_IP:-}" ]] && _preflight_critical "CLUSTER_B_IP required for topology ${REPL_TOPOLOGY}"
    # cluster-a pod-1 replicates from pod-0 via headless DNS (same cluster)
    REPLICAS+=("mariadb-1:mariadb-0.mariadb.${DB_NAMESPACE}.svc.cluster.local:3306")
    # cluster-b pod-0 replicates from cluster-a pod-0 via NodePort
    REPLICAS+=("cross-cluster-b:${CLUSTER_A_IP}:30091")
    ;;
  1+2)
    [[ -z "${CLUSTER_A_IP:-}" ]] && _preflight_critical "CLUSTER_A_IP required for topology ${REPL_TOPOLOGY}"
    [[ -z "${CLUSTER_B_IP:-}" ]] && _preflight_critical "CLUSTER_B_IP required for topology ${REPL_TOPOLOGY}"
    # cluster-b pod-0 and pod-1 replicate from cluster-a pod-0 via NodePort
    REPLICAS+=("cross-cluster-b0:${CLUSTER_A_IP}:30091")
    REPLICAS+=("cross-cluster-b1:${CLUSTER_A_IP}:30091")
    ;;
  3+0)
    [[ -z "${CLUSTER_A_IP:-}" ]] && _preflight_critical "CLUSTER_A_IP required for topology ${REPL_TOPOLOGY}"
    # pod-1 and pod-2 replicate from pod-0 via headless DNS
    REPLICAS+=("mariadb-1:mariadb-0.mariadb.${DB_NAMESPACE}.svc.cluster.local:3306")
    REPLICAS+=("mariadb-2:mariadb-0.mariadb.${DB_NAMESPACE}.svc.cluster.local:3306")
    ;;
  *)
    _preflight_critical "Unknown REPL_TOPOLOGY '${REPL_TOPOLOGY}'; supported: 2+1, 1+2, 3+0"
    ;;
esac

PRIMARY_POD="mariadb-0"

# ── Ensure PRIMARY has binlog and GTID enabled ────────────────────────────────
log_info "setup-replication" "Verifying PRIMARY ${PRIMARY_POD} has binlog enabled..."
BINLOG_CHECK=$(_mariadb_exec "$PRIMARY_POD" "$DB_NAMESPACE" "$ROOT_PASS" \
  "SHOW VARIABLES LIKE 'log_bin'") || \
  _preflight_critical "cannot connect to PRIMARY pod ${PRIMARY_POD}"

if ! echo "$BINLOG_CHECK" | grep -qi "ON\b"; then
  _preflight_critical "Binlog not enabled on ${PRIMARY_POD} — ensure statefulset uses --log-bin flag"
fi

# ── Create replication user on PRIMARY (idempotent) ───────────────────────────
REPL_PASS=$(kubectl -n "${DB_NAMESPACE}" get secret "${CRED_SECRET}" \
  -o jsonpath="{.data.repl_password}" 2>/dev/null | base64 -d || true)

if [[ -z "$REPL_PASS" ]]; then
  log_info "setup-replication" "Generating replication user password and storing in secret..."
  REPL_PASS=$(openssl rand -base64 "${REPL_PASS_LEN}" | tr -d '=+/')
  # Patch secret with repl_password key
  kubectl -n "${DB_NAMESPACE}" patch secret "${CRED_SECRET}" \
    --type=merge \
    -p "{\"data\":{\"repl_password\":\"$(printf '%s' "$REPL_PASS" | base64 -w0)\"}}"
fi

log_info "setup-replication" "Creating/verifying replication user '${REPL_USER}' on PRIMARY..."
_mariadb_exec "$PRIMARY_POD" "$DB_NAMESPACE" "$ROOT_PASS" \
  "CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED BY '${REPL_PASS}'; \
   GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%'; \
   FLUSH PRIVILEGES;" || \
  _preflight_critical "failed to create replication user on ${PRIMARY_POD}"

# ── Configure in-cluster replicas ─────────────────────────────────────────────
SETUP_COUNT=0
SKIP_COUNT=0

for entry in "${REPLICAS[@]}"; do
  # Skip cross-cluster entries — those run on a different cluster's aqsh pod
  if [[ "${entry%%:*}" == cross-cluster* ]]; then
    log_info "setup-replication" "Skipping cross-cluster entry '${entry}' (configure from that cluster's aqsh)"
    (( SKIP_COUNT++ )) || true
    continue
  fi

  local_pod="${entry%%:*}"
  rest="${entry#*:}"
  primary_host="${rest%%:*}"
  primary_port="${rest##*:}"

  log_info "setup-replication" "Configuring replica: ${local_pod} → ${primary_host}:${primary_port}"

  if _slave_running "$local_pod" "$DB_NAMESPACE" "$ROOT_PASS"; then
    log_info "setup-replication" "Slave already running on ${local_pod} — skipping"
    (( SKIP_COUNT++ )) || true
    continue
  fi

  _mariadb_exec "$local_pod" "$DB_NAMESPACE" "$ROOT_PASS" \
    "STOP SLAVE; \
     CHANGE MASTER TO \
       MASTER_HOST='${primary_host}', \
       MASTER_PORT=${primary_port}, \
       MASTER_USER='${REPL_USER}', \
       MASTER_PASSWORD='${REPL_PASS}', \
       MASTER_USE_GTID=slave_pos; \
     START SLAVE;" || {
    log_error "setup-replication" "Failed to configure CHANGE MASTER on ${local_pod}"
    _preflight_critical "CHANGE MASTER TO failed on ${local_pod}"
  }

  # Verify Slave_IO_Running
  local verify_elapsed=0
  while (( verify_elapsed < 30 )); do
    if _slave_running "$local_pod" "$DB_NAMESPACE" "$ROOT_PASS"; then
      log_info "setup-replication" "Slave IO thread running on ${local_pod}"
      break
    fi
    sleep 3; verify_elapsed=$((verify_elapsed + 3))
  done

  if ! _slave_running "$local_pod" "$DB_NAMESPACE" "$ROOT_PASS"; then
    SLAVE_STATUS=$(_mariadb_exec "$local_pod" "$DB_NAMESPACE" "$ROOT_PASS" "SHOW SLAVE STATUS\G" || true)
    log_error "setup-replication" "Slave IO not running on ${local_pod}: ${SLAVE_STATUS}"
    _preflight_critical "Slave IO thread failed to start on ${local_pod}"
  fi

  (( SETUP_COUNT++ )) || true
done

log_info "setup-replication" "Replication setup complete: configured=${SETUP_COUNT} skipped=${SKIP_COUNT}"

jq -n \
  --arg  topology   "${REPL_TOPOLOGY}" \
  --arg  namespace  "${DB_NAMESPACE}" \
  --arg  primary    "${PRIMARY_POD}" \
  --argjson setup   "${SETUP_COUNT}" \
  --argjson skipped "${SKIP_COUNT}" \
  '{topology: $topology, namespace: $namespace, primary: $primary,
    replicas_configured: $setup, replicas_skipped: $skipped}' \
  > "$AQSH_RESULT_FILE"
