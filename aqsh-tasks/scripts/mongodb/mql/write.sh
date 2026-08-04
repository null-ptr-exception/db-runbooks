#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/mql/write.sh
# aqsh task: gated MongoDB Query Language write operations (insert_one/
# insert_many/update_one/update_many/delete_one/delete_many) against one
# collection — always on the elected PRIMARY (writes have no target_pod
# choice). Gated dry_run -> confirm, same triad as ops/kill and
# profiler/set.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE   — target namespace, e.g. "mongo-1"
#   MQL_DATABASE   — required; database name
#   MQL_COLLECTION — required; collection name (system.* is refused)
#   MQL_OPERATION  — required; insert_one | insert_many | update_one |
#                    update_many | delete_one | delete_many
#   MQL_FILTER     — JSON object, default "{}" (update_*/delete_* only)
#   MQL_UPDATE     — JSON object; required for update_one/update_many
#   MQL_DOCUMENT   — JSON object; required for insert_one
#   MQL_DOCUMENTS  — JSON array; required for insert_many
#   MQL_UPSERT     — optional bool, default "false" (update_* only)
#   DRY_RUN        — default "true": preview only, nothing changed
#   CONFIRM        — must be "true" when DRY_RUN is "false"
#   LOG_LEVEL      — optional per-call log verbosity
#
# admin/local/config (plus MQL_PROTECTED_DATABASES_DEFAULT internal config)
# are always refused (PROTECTED_DATABASE) — see docs/mongodb/mql.md.
#
# sts_name/credential secret/user/keys are not task inputs (see CLAUDE.md
# "Configuration Layers") — they resolve internal config -> live cluster
# auto-detect -> hardcoded literal fallback.
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-recovery.sh"
source "${LIB_DIR}/mongodb-account.sh"
source "${LIB_DIR}/mongodb-mql.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
log_set_level "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT:-INFO}}"

_DATABASE="${MQL_DATABASE:?database is required}"
_COLLECTION="${MQL_COLLECTION:?collection is required}"
_OPERATION="${MQL_OPERATION:?operation is required}"
_FILTER="${MQL_FILTER:-{}}"
_UPDATE="${MQL_UPDATE:-}"
_DOCUMENT="${MQL_DOCUMENT:-}"
_DOCUMENTS="${MQL_DOCUMENTS:-}"
_UPSERT="${MQL_UPSERT:-false}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"

# ── Gate (same triad as ops/kill, profiler/set) ──────────────────────────────
if bool_enabled "$DRY_RUN" && bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true with dry_run=true is not supported"
fi
if ! bool_enabled "$DRY_RUN" && ! bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true is required when dry_run=false"
fi

# ── Input validation ─────────────────────────────────────────────────────────
if [[ ! "$_OPERATION" =~ ^(insert_one|insert_many|update_one|update_many|delete_one|delete_many)$ ]]; then
  fail_task "INVALID_INPUT" "operation must be one of insert_one, insert_many, update_one, update_many, delete_one, delete_many (got '${_OPERATION}')"
fi
if ! mql_validate_collection_name "$_COLLECTION"; then
  fail_task "INVALID_INPUT" "collection is invalid or refers to a system.* collection"
fi
if ! mql_validate_json "$_FILTER" object; then
  fail_task "INVALID_INPUT" "filter must be a valid JSON object"
fi

case "$_OPERATION" in
  insert_one)
    [[ -n "$_DOCUMENT" ]] || fail_task "INVALID_INPUT" "document is required when operation=insert_one"
    mql_validate_json "$_DOCUMENT" object || fail_task "INVALID_INPUT" "document must be a valid JSON object"
    ;;
  insert_many)
    [[ -n "$_DOCUMENTS" ]] || fail_task "INVALID_INPUT" "documents is required when operation=insert_many"
    mql_validate_json "$_DOCUMENTS" array || fail_task "INVALID_INPUT" "documents must be a valid JSON array"
    [[ "$(jq 'length' <<<"$_DOCUMENTS")" -gt 0 ]] || fail_task "INVALID_INPUT" "documents must be a non-empty array"
    ;;
  update_one | update_many)
    [[ -n "$_UPDATE" ]] || fail_task "INVALID_INPUT" "update is required when operation=${_OPERATION}"
    mql_validate_json "$_UPDATE" object || fail_task "INVALID_INPUT" "update must be a valid JSON object"
    ;;
esac

if mql_is_protected_database "$_DATABASE"; then
  fail_task "PROTECTED_DATABASE" "refusing to write database '${_DATABASE}' (MongoDB system database or internal-config-protected)"
fi

# ── Resolve deployment naming + credentials (3-tier, no task-input tier) ────
mql_resolve_deployment ""

log_info "mql-write" "STS=${_MQL_STS} namespace=${DB_NAMESPACE} database=${_DATABASE} collection=${_COLLECTION} operation=${_OPERATION} dry_run=${DRY_RUN}"
log_debug "mql-write" "resolved credentials: secret=${_MQL_SECRET} user_key=${_MQL_USER_KEY:-<direct>} pass_key=${_MQL_PASS_KEY}"
log_debug "mql-write" "filter=${_FILTER} update=${_UPDATE} document=${_DOCUMENT} documents=${_DOCUMENTS} upsert=${_UPSERT}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_MQL_SECRET}" "${_MQL_USER_KEY}" "${_MQL_PASS_KEY}" "${_MQL_DIRECT_USER}"

_PROBE=$(_mql_probe_pod "$_MQL_STS") \
  || fail_task "NO_PRIMARY" "no Ready/Running pod found for StatefulSet ${_MQL_STS} in ${DB_NAMESPACE}"
log_debug "mql-write" "probe pod: ${_PROBE}"

# Writes always target the elected PRIMARY — no target_pod field.
_TARGET_ROW=$(_mql_resolve_target "$_MQL_STS" "$_PROBE" "" "$_MONGO_USER" "$_MONGO_PASS") \
  || fail_task "NO_PRIMARY" "no reachable PRIMARY for StatefulSet ${_MQL_STS} in ${DB_NAMESPACE}"
IFS=$'\x1f' read -r _EXEC_POD _DIRECT_HOST <<<"$_TARGET_ROW"
log_debug "mql-write" "exec_pod=${_EXEC_POD} direct_host=${_DIRECT_HOST:-<local>}"

if bool_enabled "$DRY_RUN"; then
  _PREVIEW=$(mql_write_preview "$_EXEC_POD" "$_DIRECT_HOST" "$_MONGO_USER" "$_MONGO_PASS" \
    "$_DATABASE" "$_COLLECTION" "$_OPERATION" "$_FILTER" "$_DOCUMENT" "$_DOCUMENTS") \
    || fail_task "PREVIEW_FAILED" "could not preview ${_OPERATION} on ${_DATABASE}.${_COLLECTION}" \
      "$(jq -nc --arg detail "${_PREVIEW:-}" '{detail:$detail}')"

  log_info "mql-write" "dry-run: previewed ${_OPERATION} on ${_DATABASE}.${_COLLECTION}"
  jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg database "$_DATABASE" \
    --arg collection "$_COLLECTION" \
    --arg operation "$_OPERATION" \
    --argjson preview "$_PREVIEW" \
    '{status:"DRY_RUN_READY", reason_code:"DRY_RUN_READY",
      summary:"Dry-run only. Would apply the operation shown below.",
      namespace:$namespace, database:$database, collection:$collection,
      operation:$operation, preview:$preview, changed:false, would_change:true}' \
    >"$AQSH_RESULT_FILE"
  exit 0
fi

# ── Execute ──────────────────────────────────────────────────────────────────
_RESULT_JSON=$(mql_write_execute "$_EXEC_POD" "$_DIRECT_HOST" "$_MONGO_USER" "$_MONGO_PASS" \
  "$_DATABASE" "$_COLLECTION" "$_OPERATION" "$_FILTER" "$_UPDATE" "$_DOCUMENT" "$_DOCUMENTS" "$_UPSERT") \
  || fail_task "WRITE_FAILED" "${_OPERATION} failed on ${_DATABASE}.${_COLLECTION}" \
    "$(jq -nc --arg detail "${_RESULT_JSON:-}" '{detail:$detail}')"

log_info "mql-write" "${_OPERATION} completed on ${_DATABASE}.${_COLLECTION}"
jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg database "$_DATABASE" \
  --arg collection "$_COLLECTION" \
  --arg operation "$_OPERATION" \
  --argjson result "$_RESULT_JSON" \
  '{status:"ok", reason_code:"WRITE_OK", summary:"Write applied.",
    namespace:$namespace, database:$database, collection:$collection,
    operation:$operation, result:$result, changed:true}' \
  >"$AQSH_RESULT_FILE"
