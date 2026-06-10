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
_PRIMARY_RESOLVE_MAX_WAIT="${MONGO_PRIMARY_RESOLVE_MAX_WAIT_SECONDS:-90}"
_PRIMARY_RESOLVE_INTERVAL="${MONGO_PRIMARY_RESOLVE_INTERVAL_SECONDS:-3}"

# ── Preflight failure writer ──────────────────────────────────────────────────
# Called when a pre-check step fails before the main check loop runs.
# Writes a structured critical result to $AQSH_RESULT_FILE so aqsh always
# receives a valid task result rather than a raw execution failure.
_preflight_critical() {
  local reason="${1:-preflight check failed}"
  log_error "mongo-sanity-check" "Preflight failed: ${reason}"
  jq -n \
    --arg  status    "critical" \
    --arg  reason    "${reason}" \
    --arg  namespace "${DB_NAMESPACE}" \
    '{status: $status, namespace: $namespace, reason: $reason, pass: 0, warn: 0, fail: 1, total: 1}' \
    > "$AQSH_RESULT_FILE"
  exit 1
}

_resolve_primary_with_retry() {
  local seed_host="$1"
  local seed_port="$2"
  local user="$3"
  local pass="$4"
  local auth_db="$5"

  local elapsed=0 out
  while (( elapsed < _PRIMARY_RESOLVE_MAX_WAIT )); do
    if out=$(mongo_resolve_primary "$seed_host" "$seed_port" "$user" "$pass" "$auth_db" 2>/dev/null); then
      printf '%s\n' "$out"
      return 0
    fi

    log_warn "mongo-sanity-check" \
      "primary not ready yet via ${seed_host}:${seed_port}; retrying in ${_PRIMARY_RESOLVE_INTERVAL}s (${elapsed}/${_PRIMARY_RESOLVE_MAX_WAIT}s elapsed)"
    sleep "${_PRIMARY_RESOLVE_INTERVAL}"
    elapsed=$((elapsed + _PRIMARY_RESOLVE_INTERVAL))
  done

  return 1
}

# ── Read credentials from K8s Secret ─────────────────────────────────────────
MONGO_USER=$(kubectl -n "${DB_NAMESPACE}" get secret "${_CRED_SECRET}" \
  -o jsonpath="{.data.${_CRED_USER_KEY}}" 2>/dev/null | base64 -d) || \
  _preflight_critical "cannot read '${_CRED_USER_KEY}' from secret '${_CRED_SECRET}' in namespace '${DB_NAMESPACE}' — check RBAC and secret name"
MONGO_PASS=$(kubectl -n "${DB_NAMESPACE}" get secret "${_CRED_SECRET}" \
  -o jsonpath="{.data.${_CRED_PASS_KEY}}" 2>/dev/null | base64 -d) || \
  _preflight_critical "cannot read '${_CRED_PASS_KEY}' from secret '${_CRED_SECRET}' in namespace '${DB_NAMESPACE}' — check RBAC and secret name"

# ── Resolve primary via headless FQDN ────────────────────────────────────────
# Seed = first pod of the StatefulSet: <sts>-0.<svc>.<ns>.svc.cluster.local
_SEED_HOST="${_STS_NAME}-0.${_STS_NAME}.${DB_NAMESPACE}.svc.cluster.local"
_SEED_PORT="27017"

_PRIMARY_OUTPUT=$(_resolve_primary_with_retry "$_SEED_HOST" "$_SEED_PORT" "$MONGO_USER" "$MONGO_PASS" "admin") || \
  _preflight_critical "cannot resolve MongoDB primary via seed ${_SEED_HOST}:${_SEED_PORT} within ${_PRIMARY_RESOLVE_MAX_WAIT}s — check that the StatefulSet pods are running and credentials are correct"
MONGO_HOST=$(echo "$_PRIMARY_OUTPUT" | sed -n '1p')
_RESOLVED_PORT=$(echo "$_PRIMARY_OUTPUT" | sed -n '2p')
MONGO_PORT="${_RESOLVED_PORT:-27017}"

[[ -z "$MONGO_HOST" ]] && \
  _preflight_critical "mongo_resolve_primary returned empty host for seed ${_SEED_HOST}:${_SEED_PORT} — no primary elected or seed unreachable"

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
