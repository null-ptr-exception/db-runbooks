#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/sanity-check.sh
# aqsh task: 3-layer MongoDB health check.
#
# Inputs (injected by aqsh from tasks.yaml):
#   DB_NAMESPACE   — target namespace, e.g. "mongo-1"
#
# Infra parameters (StatefulSet name, credential secret, keys) are resolved
# via a 3-tier chain with no task-input tier — callers never need to know
# deployment naming conventions:
#   1. Internal config  (/etc/aqsh/config/mongodb.env *_DEFAULT vars)
#   2. Auto-detect      (live STS env / secretKeyRef inspection — official
#                        MONGO_INITDB_ROOT_* and Bitnami MONGODB_ROOT_*,
#                        including file-mounted-secret conventions)
#   3. Hardcoded literal (mongodb / mongodb-credentials / MONGO_ROOT_USER …)
# =============================================================================

LIB_DIR="/tasks/lib"

source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-recovery.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"

log_info "mongo-sanity-check" "Starting sanity check: namespace=${DB_NAMESPACE}"

# ── Internal-config defaults ──────────────────────────────────────────────────
[[ -f /etc/aqsh/config/mongodb.env ]] && source /etc/aqsh/config/mongodb.env
_PRIMARY_RESOLVE_MAX_WAIT="${MONGO_PRIMARY_RESOLVE_MAX_WAIT_SECONDS:-90}"
_PRIMARY_RESOLVE_INTERVAL="${MONGO_PRIMARY_RESOLVE_INTERVAL_SECONDS:-3}"

# ── Preflight failure writer ──────────────────────────────────────────────────
_preflight_critical() {
  local reason="${1:-preflight check failed}"
  log_error "mongo-sanity-check" "Preflight failed: ${reason}"
  jq -n \
    --arg status    "critical" \
    --arg reason    "${reason}" \
    --arg namespace "${DB_NAMESPACE}" \
    '{status:$status,namespace:$namespace,reason:$reason,pass:0,warn:0,fail:1,total:1}' \
    > "$AQSH_RESULT_FILE"
  exit 1
}

# ── Tier 1→2→3: StatefulSet name ─────────────────────────────────────────────
if [[ -n "${MONGO_STS_NAME_DEFAULT:-}" ]]; then
  _STS_NAME="${MONGO_STS_NAME_DEFAULT}"
  log_debug "mongo-sanity-check" "sts_name from internal config: ${_STS_NAME}"
else
  _detected_sts=$(_recovery_detect_sts_name) || _detected_sts=""
  if [[ -n "$_detected_sts" ]]; then
    _STS_NAME="$_detected_sts"
    log_info "mongo-sanity-check" "sts_name auto-detected: ${_STS_NAME}"
  else
    _STS_NAME="mongodb"
    log_debug "mongo-sanity-check" "sts_name: using hardcoded literal '${_STS_NAME}'"
  fi
fi

# ── Tier 1→2→3: credentials ──────────────────────────────────────────────────
# Any internal-config field set → use all config fields; never mix a detected
# secret name with an unrelated config key or vice versa.
_CRED_SECRET="${MONGO_CRED_SECRET_DEFAULT:-}"
_CRED_USER_KEY="${MONGO_CRED_USER_KEY_DEFAULT:-}"
_CRED_PASS_KEY="${MONGO_CRED_PASS_KEY_DEFAULT:-}"
_DIRECT_USER=""

if [[ -z "$_CRED_SECRET" && -z "$_CRED_USER_KEY" && -z "$_CRED_PASS_KEY" ]]; then
  _detected_creds=$(_recovery_detect_credentials "$_STS_NAME") || _detected_creds=""
  if [[ -n "$_detected_creds" ]]; then
    IFS=$'\x1f' read -r _CRED_SECRET _DIRECT_USER _CRED_USER_KEY _CRED_PASS_KEY \
      <<< "$_detected_creds"
    log_info "mongo-sanity-check" \
      "credentials auto-detected: secret=${_CRED_SECRET} user_key=${_CRED_USER_KEY:-<direct>} pass_key=${_CRED_PASS_KEY}"
  fi
fi
_CRED_SECRET="${_CRED_SECRET:-mongodb-credentials}"
_CRED_USER_KEY="${_CRED_USER_KEY:-MONGO_ROOT_USER}"
_CRED_PASS_KEY="${_CRED_PASS_KEY:-MONGO_ROOT_PASS}"

log_debug "mongo-sanity-check" \
  "resolved: sts=${_STS_NAME} secret=${_CRED_SECRET} user_key=${_CRED_USER_KEY} pass_key=${_CRED_PASS_KEY}"

# ── Load credentials from Secret ─────────────────────────────────────────────
_mongo_load_credentials \
  "${DB_NAMESPACE}" "${_CRED_SECRET}" "${_CRED_USER_KEY}" "${_CRED_PASS_KEY}" "${_DIRECT_USER}"

# ── Resolve primary via headless FQDN ────────────────────────────────────────
_resolve_primary_with_retry() {
  local seed_host="$1" seed_port="$2" user="$3" pass="$4" auth_db="$5"
  local elapsed=0 out
  while (( elapsed < _PRIMARY_RESOLVE_MAX_WAIT )); do
    if out=$(mongo_resolve_primary "$seed_host" "$seed_port" "$user" "$pass" "$auth_db" 2>/dev/null); then
      printf '%s\n' "$out"
      return 0
    fi
    log_warn "mongo-sanity-check" \
      "primary not ready via ${seed_host}:${seed_port}; retry in ${_PRIMARY_RESOLVE_INTERVAL}s (${elapsed}/${_PRIMARY_RESOLVE_MAX_WAIT}s elapsed)"
    sleep "${_PRIMARY_RESOLVE_INTERVAL}"
    elapsed=$(( elapsed + _PRIMARY_RESOLVE_INTERVAL ))
  done
  return 1
}

# The STS's own spec.serviceName governs pod DNS and is not guaranteed to
# equal the StatefulSet's name (e.g. Bitnami commonly uses "<sts>-headless").
_HEADLESS_SVC=$(_recovery_detect_headless_service "$_STS_NAME") || _HEADLESS_SVC="$_STS_NAME"
[[ "$_HEADLESS_SVC" != "$_STS_NAME" ]] && \
  log_info "mongo-sanity-check" "headless service auto-detected: ${_HEADLESS_SVC} (sts=${_STS_NAME})"

_SEED_HOST="${_STS_NAME}-0.${_HEADLESS_SVC}.${DB_NAMESPACE}.svc.cluster.local"
_SEED_PORT="27017"
log_debug "mongo-sanity-check" "resolving primary via seed: ${_SEED_HOST}:${_SEED_PORT}"

_PRIMARY_OUTPUT=$(_resolve_primary_with_retry \
  "$_SEED_HOST" "$_SEED_PORT" "$_MONGO_USER" "$_MONGO_PASS" "admin") || \
  _preflight_critical "cannot resolve MongoDB primary via ${_SEED_HOST}:${_SEED_PORT} within ${_PRIMARY_RESOLVE_MAX_WAIT}s — check that pods are running and credentials are correct"

MONGO_HOST=$(printf '%s\n' "$_PRIMARY_OUTPUT" | sed -n '1p')
_RESOLVED_PORT=$(printf '%s\n' "$_PRIMARY_OUTPUT" | sed -n '2p')
MONGO_PORT="${_RESOLVED_PORT:-27017}"

[[ -z "$MONGO_HOST" ]] && \
  _preflight_critical "mongo_resolve_primary returned empty host for seed ${_SEED_HOST}:${_SEED_PORT} — no primary elected or seed unreachable"

log_info "mongo-sanity-check" "primary resolved: ${MONGO_HOST}:${MONGO_PORT}"

export K8S_NAMESPACE="${DB_NAMESPACE}"
export STS_NAME="${_STS_NAME}"
export MONGO_HOST MONGO_PORT
export MONGO_AUTHDB="admin"
export MONGO_USER="${_MONGO_USER}" MONGO_PASS="${_MONGO_PASS}"

# ── Run checks ────────────────────────────────────────────────────────────────
source "${LIB_DIR}/mongodb_constant.sh"
source "${LIB_DIR}/custom.sh"

check_k8s_layer         || true
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
  '{status:$status,namespace:$namespace,pass:$pass,warn:$warn,fail:$fail,total:$total}' \
  > "$AQSH_RESULT_FILE"

log_info "mongo-sanity-check" \
  "Done: status=${RESULT_STATUS} pass=${SC_PASS} warn=${SC_WARN} fail=${SC_FAIL}"
