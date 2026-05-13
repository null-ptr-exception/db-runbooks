#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/sanity-check.sh
# aqsh task: 3-layer MongoDB health check.
#
# Inputs (injected by aqsh from tasks.yaml):
#   DB_NAMESPACE          — target namespace, e.g. "mongo-1"
#   MONGO_STS_NAME        — StatefulSet name (default: mongodb); also used as headless Service name
#   MONGO_CRED_SECRET     — Secret name holding credentials (default: mongodb-credentials)
#   MONGO_CRED_USER_KEY   — key in Secret for username (default: MONGO_ROOT_USER)
#   MONGO_CRED_PASS_KEY   — key in Secret for password (default: MONGO_ROOT_PASS)
#
# Writes JSON result to $AQSH_RESULT_FILE:
#   {"status":"ok|warning|critical","pass":N,"warn":N,"fail":N,"total":N}
# =============================================================================

LIB_DIR="/tasks/lib"

source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"

log_info "mongo-sanity-check" "Starting sanity check for namespace: ${DB_NAMESPACE}"

# ── Configurable defaults ─────────────────────────────────────────────────────
_STS_NAME="${MONGO_STS_NAME:-mongodb}"
_CRED_SECRET="${MONGO_CRED_SECRET:-mongodb-credentials}"
_CRED_USER_KEY="${MONGO_CRED_USER_KEY:-MONGO_ROOT_USER}"
_CRED_PASS_KEY="${MONGO_CRED_PASS_KEY:-MONGO_ROOT_PASS}"

# ── Read credentials from K8s Secret ─────────────────────────────────────────
MONGO_USER=$(kubectl -n "${DB_NAMESPACE}" get secret "${_CRED_SECRET}" \
  -o jsonpath="{.data.${_CRED_USER_KEY}}" | base64 -d)
MONGO_PASS=$(kubectl -n "${DB_NAMESPACE}" get secret "${_CRED_SECRET}" \
  -o jsonpath="{.data.${_CRED_PASS_KEY}}" | base64 -d)

# ── Resolve primary via headless FQDN ────────────────────────────────────────
# Seed = first pod of the StatefulSet: <sts>-0.<svc>.<ns>.svc.cluster.local
_SEED_HOST="${_STS_NAME}-0.${_STS_NAME}.${DB_NAMESPACE}.svc.cluster.local"
_SEED_PORT="27017"

_PRIMARY_OUTPUT=$(mongo_resolve_primary "$_SEED_HOST" "$_SEED_PORT" "$MONGO_USER" "$MONGO_PASS" "admin")
MONGO_HOST=$(echo "$_PRIMARY_OUTPUT" | sed -n '1p')
_RESOLVED_PORT=$(echo "$_PRIMARY_OUTPUT" | sed -n '2p')
MONGO_PORT="${_RESOLVED_PORT:-27017}"

log_info "mongo-sanity-check" "Connecting to primary: ${MONGO_HOST}:${MONGO_PORT}"

export K8S_NAMESPACE="${DB_NAMESPACE}"
export STS_NAME="${_STS_NAME}"
export MONGO_HOST
export MONGO_PORT
export MONGO_AUTHDB="admin"
export MONGO_USER MONGO_PASS

# ── Run sanity check ──────────────────────────────────────────────────────────
source "${LIB_DIR}/mongodb_constant.sh"
source "${LIB_DIR}/custom.sh"

check_k8s_layer        || true
check_mongo_connectivity || true
check_mongo_internals    || true

_sc_summary

# ── Build result ──────────────────────────────────────────────────────────────
TOTAL=$(( SC_PASS + SC_WARN + SC_FAIL ))

if (( SC_FAIL > 0 )); then
  RESULT_STATUS="critical"
elif (( SC_WARN > 0 )); then
  RESULT_STATUS="warning"
else
  RESULT_STATUS="ok"
fi

jq -n \
  --arg  status    "$RESULT_STATUS" \
  --argjson pass   "${SC_PASS}" \
  --argjson warn   "${SC_WARN}" \
  --argjson fail   "${SC_FAIL}" \
  --argjson total  "${TOTAL}" \
  --arg  namespace "${DB_NAMESPACE}" \
  '{status: $status, namespace: $namespace, pass: $pass, warn: $warn, fail: $fail, total: $total}' \
  > "$AQSH_RESULT_FILE"

log_info "mongo-sanity-check" "Done: status=${RESULT_STATUS} pass=${SC_PASS} warn=${SC_WARN} fail=${SC_FAIL}"
