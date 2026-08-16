#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/mql/read.sh
# aqsh task: read-only MongoDB Query Language operations (find/aggregate/
# count/distinct) against one collection on a single node — the elected
# PRIMARY by default, or an explicit target_pod. Executes nothing.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE     — target namespace, e.g. "mongo-1"
#   TARGET_POD       — optional; defaults to the elected PRIMARY
#   MQL_DATABASE     — required; database name
#   MQL_COLLECTION   — required; collection name (system.* is refused)
#   MQL_OPERATION    — required; find | aggregate | count | distinct
#   MQL_FILTER       — optional JSON object, default "{}" (find/count/distinct)
#   MQL_PROJECTION   — optional JSON object, default "{}" (find only)
#   MQL_PIPELINE     — optional JSON array, default "[]" (aggregate only)
#   MQL_DISTINCT_FIELD — required when operation=distinct
#   MQL_LIMIT        — optional int, default 50, capped at 1000 (find only)
#   LOG_LEVEL        — optional per-call log verbosity
#
# admin/local/config (plus MQL_PROTECTED_DATABASES_DEFAULT internal config)
# are always refused (PROTECTED_DATABASE) — see docs/mongodb/mql.md.
#
# sts_name/credential secret/user/keys are not task inputs (see AGENTS.md
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

_TARGET_POD_INPUT="${TARGET_POD:-}"
_DATABASE="${MQL_DATABASE:?database is required}"
_COLLECTION="${MQL_COLLECTION:?collection is required}"
_OPERATION="${MQL_OPERATION:?operation is required}"
# NOT "${MQL_FILTER:-{}}": bash's ${param:-word} default-word scan stops at
# the first unescaped '}', so an inline "{}" default leaves a stray
# trailing '}' appended to the value whenever the parameter is actually set
# — which task defaulting (tasks-mongodb.yaml already supplies "{}") means
# it always is. Two-step default sidesteps the parser pitfall.
_FILTER="${MQL_FILTER:-}"
[[ -z "$_FILTER" ]] && _FILTER='{}'
_PROJECTION="${MQL_PROJECTION:-}"
[[ -z "$_PROJECTION" ]] && _PROJECTION='{}'
_PIPELINE="${MQL_PIPELINE:-[]}"
_DISTINCT_FIELD="${MQL_DISTINCT_FIELD:-}"
_LIMIT="${MQL_LIMIT:-50}"

# ── Input validation ─────────────────────────────────────────────────────────
if [[ ! "$_OPERATION" =~ ^(find|aggregate|count|distinct)$ ]]; then
  fail_task "INVALID_INPUT" "operation must be one of find, aggregate, count, distinct (got '${_OPERATION}')"
fi
if ! mql_validate_collection_name "$_COLLECTION"; then
  fail_task "INVALID_INPUT" "collection is invalid or refers to a system.* collection"
fi
if ! mql_validate_json "$_FILTER" object; then
  fail_task "INVALID_INPUT" "filter must be a valid JSON object"
fi
if ! mql_validate_json "$_PROJECTION" object; then
  fail_task "INVALID_INPUT" "projection must be a valid JSON object"
fi
if ! mql_validate_json "$_PIPELINE" array; then
  fail_task "INVALID_INPUT" "pipeline must be a valid JSON array"
fi
if [[ "$_OPERATION" == "aggregate" ]] && mql_pipeline_has_write_stage "$_PIPELINE"; then
  fail_task "INVALID_INPUT" "aggregate pipeline must not contain \$out or \$merge (write stages are not permitted via mql/read)"
fi
if [[ "$_OPERATION" == "distinct" && -z "$_DISTINCT_FIELD" ]]; then
  fail_task "INVALID_INPUT" "distinct_field is required when operation=distinct"
fi
if [[ ! "$_LIMIT" =~ ^[0-9]+$ ]] || [[ "$_LIMIT" -lt 1 ]] || [[ "$_LIMIT" -gt 1000 ]]; then
  fail_task "INVALID_INPUT" "limit must be an integer between 1 and 1000 (got '${_LIMIT}')"
fi
if mql_is_protected_database "$_DATABASE"; then
  fail_task "PROTECTED_DATABASE" "refusing to read database '${_DATABASE}' (MongoDB system database or internal-config-protected)"
fi

# ── Resolve deployment naming + credentials (3-tier, no task-input tier) ────
mql_resolve_deployment "$_TARGET_POD_INPUT"

log_info "mql-read" "STS=${_MQL_STS} namespace=${DB_NAMESPACE} target_pod=${_TARGET_POD_INPUT:-<primary>} database=${_DATABASE} collection=${_COLLECTION} operation=${_OPERATION}"
log_debug "mql-read" "resolved credentials: secret=${_MQL_SECRET} user_key=${_MQL_USER_KEY:-<direct>} pass_key=${_MQL_PASS_KEY}"
log_debug "mql-read" "filter=${_FILTER} projection=${_PROJECTION} pipeline=${_PIPELINE} distinct_field=${_DISTINCT_FIELD} limit=${_LIMIT}"

_mongo_load_credentials "${DB_NAMESPACE}" "${_MQL_SECRET}" "${_MQL_USER_KEY}" "${_MQL_PASS_KEY}" "${_MQL_DIRECT_USER}"

_PROBE=$(_mql_probe_pod "$_MQL_STS") \
  || fail_task "NO_PRIMARY" "no Ready/Running pod found for StatefulSet ${_MQL_STS} in ${DB_NAMESPACE}"
log_debug "mql-read" "probe pod: ${_PROBE}"

_TARGET_ROW=$(_mql_resolve_target "$_MQL_STS" "$_PROBE" "$_TARGET_POD_INPUT" "$_MONGO_USER" "$_MONGO_PASS") && _TARGET_RC=0 || _TARGET_RC=$?
if [[ "$_TARGET_RC" -eq 2 ]]; then
  log_debug "mql-read" "target_pod '${_TARGET_POD_INPUT}' is not owned by StatefulSet ${_MQL_STS}"
  fail_task "TARGET_POD_NOT_MEMBER" "'${_TARGET_POD_INPUT}' is not a member pod of StatefulSet ${_MQL_STS} in ${DB_NAMESPACE}"
elif [[ "$_TARGET_RC" -ne 0 ]]; then
  fail_task "NO_PRIMARY" "no target_pod given and no reachable PRIMARY for StatefulSet ${_MQL_STS} in ${DB_NAMESPACE}"
fi
IFS=$'\x1f' read -r _EXEC_POD _DIRECT_HOST <<<"$_TARGET_ROW"
log_debug "mql-read" "exec_pod=${_EXEC_POD} direct_host=${_DIRECT_HOST:-<local>}"

_RESULT_JSON=$(mql_read_execute "$_EXEC_POD" "$_DIRECT_HOST" "$_MONGO_USER" "$_MONGO_PASS" \
  "$_DATABASE" "$_COLLECTION" "$_OPERATION" "$_FILTER" "$_PROJECTION" "$_PIPELINE" \
  "$_DISTINCT_FIELD" "$_LIMIT") \
  || fail_task "QUERY_FAILED" "could not run ${_OPERATION} on ${_DATABASE}.${_COLLECTION}" \
    "$(jq -nc --arg detail "${_RESULT_JSON:-}" '{detail:$detail}')"

log_info "mql-read" "${_OPERATION} completed on ${_DATABASE}.${_COLLECTION}"

jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg target_pod "${_TARGET_POD_INPUT:-$_EXEC_POD}" \
  --arg database "$_DATABASE" \
  --arg collection "$_COLLECTION" \
  --arg operation "$_OPERATION" \
  --argjson result "$_RESULT_JSON" \
  '{status:"ok", reason_code:"QUERY_OK", namespace:$namespace, target_pod:$target_pod,
    database:$database, collection:$collection, operation:$operation, result:$result}' \
  >"$AQSH_RESULT_FILE"
