#!/usr/bin/env bash
# =============================================================================
# mongodb-mql.sh — structured-query CRUD helpers for the mql/read and
# mql/write aqsh tasks (see docs/mongodb/mql.md).
#
# Dependencies (sourced by the calling script, not here):
#   logging.sh           — log_debug/log_info
#   k8s.sh                — _kubectl
#   mongodb.sh            — _escape_js_string, _mongo_uri_percent_encode
#                            (used by mongodb-recovery.sh)
#   mongodb-recovery.sh   — _recovery_list_pods, _recovery_mongosh_pod,
#                            _recovery_mongosh_host, _recovery_primary_host,
#                            recovery_resolve_sts_name, recovery_resolve_credentials
#   mongodb-account.sh    — bool_enabled
#
# _mql_probe_pod/_mql_mongosh are this gateway's own copies of the
# probe/dispatch pattern already used by ops/list.sh, ops/kill.sh and
# profiler/*.sh (lib/mongodb-ops.sh, lib/mongodb-profiler.sh) — this repo's
# stated convention is that each gateway lib keeps its own small copy of
# these helpers rather than reaching into another gateway's private
# functions (see the _fcv_probe_pod comment in mongodb-fcv.sh).
#
# Filter/projection/pipeline/document(s)/update fields are validated JSON
# (mql_validate_json — a jq type check that also rejects any trailing
# garbage after the JSON value) and then interpolated directly into the JS
# expression — the same technique lib/mongodb.sh's mongo_find/
# mongo_update_one/etc. already use for filter_json/update_json/
# pipeline_json. This is NOT raw eval of caller-supplied code: only a
# pre-validated JSON *value* ever lands in the expression, never arbitrary
# JS syntax. Collection names and the distinct field name are plain
# strings, escaped with _escape_js_string instead.
# =============================================================================

[[ -n "${_MONGODB_MQL_LIB_LOADED:-}" ]] && return 0
_MONGODB_MQL_LIB_LOADED=1

# ---------------------------------------------------------------------------
# mql_is_protected_database <database>
# Always-refuse guard for MongoDB's own system databases (admin/local/config)
# — blocks credential dumps via admin.system.users, raw oplog/replset-config
# access via local, and this repo's own admin.run_account_policies
# account-lifecycle state. Hardcoded, not overridable (same posture as
# recovery/*'s auto-detect tier) — MQL_PROTECTED_DATABASES_DEFAULT internal
# config can only ADD names on top, mirroring
# SECRETS_PROTECTED_NAMES_DEFAULT's role in lib/secrets.sh.
# ---------------------------------------------------------------------------
mql_is_protected_database() {
  local database="${1:?database is required}"
  local db_lower
  db_lower=$(printf '%s' "$database" | tr '[:upper:]' '[:lower:]')
  case "$db_lower" in
    admin | local | config) return 0 ;;
  esac
  local extra="${MQL_PROTECTED_DATABASES_DEFAULT:-}"
  [[ -z "$extra" ]] && return 1
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    [[ "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" == "$db_lower" ]] && return 0
  done < <(printf '%s' "$extra" | tr ', ' '\n')
  return 1
}

# ---------------------------------------------------------------------------
# mql_validate_collection_name <collection>
# Rejects empty/oversized/unsupported-charset names and MongoDB's own
# system.* collections (still reachable even inside a non-system database).
# ---------------------------------------------------------------------------
mql_validate_collection_name() {
  local collection="${1:?collection is required}"
  [[ "$collection" =~ ^[A-Za-z0-9_.-]{1,120}$ ]] || return 1
  case "$collection" in
    system.*) return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# mql_validate_json <value> <expected_type: object|array>
# True when <value> is exactly one well-formed JSON document (no trailing
# content after it, and no second whitespace-separated document — jq's
# default single-value mode accepts "{} {}" as two consecutive values, so
# this uses slurp mode and requires exactly one element) of the expected
# top-level type.
# ---------------------------------------------------------------------------
mql_validate_json() {
  local value="${1:?value is required}" expected_type="${2:?expected_type is required}"
  jq -se "length == 1 and (.[0] | type == \"${expected_type}\")" >/dev/null 2>&1 <<<"$value"
}

# ---------------------------------------------------------------------------
# mql_pipeline_has_write_stage <pipeline>
# True when a validated aggregation pipeline array contains $out or $merge
# — both persist their result to a collection, i.e. they are writes.
# mql/read.sh calls this (alongside its other upfront input validation)
# before an aggregate pipeline ever reaches mql_read_execute, so "read-only"
# is an enforced property of every pipeline this gateway runs, not merely
# an assumption based on which task the caller happened to call.
# ---------------------------------------------------------------------------
mql_pipeline_has_write_stage() {
  local pipeline="${1:?pipeline is required}"
  jq -e 'any(.[]?; has("$out") or has("$merge"))' >/dev/null 2>&1 <<<"$pipeline"
}

# ---------------------------------------------------------------------------
# mql_resolve_deployment <target_pod_input>
# Resolves sts_name + credential secret/keys via the standard 3-tier chain
# (internal config -> live auto-detect -> hardcoded fallback; see CLAUDE.md
# "Configuration Layers") and sets globals: _MQL_STS, _MQL_SECRET,
# _MQL_DIRECT_USER, _MQL_USER_KEY, _MQL_PASS_KEY. Shared by mql/read.sh and
# mql/write.sh so the two scripts can't drift apart on how this resolves —
# mql/write.sh always passes "" (writes have no target_pod).
# ---------------------------------------------------------------------------
mql_resolve_deployment() {
  local target_pod_input="${1:-}"
  _MQL_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "$target_pod_input")
  local cred_row
  cred_row=$(recovery_resolve_credentials \
    "${MONGO_CRED_SECRET_DEFAULT:-}" \
    "${MONGO_CRED_USER_DEFAULT:-}" \
    "${MONGO_CRED_USER_KEY_DEFAULT:-}" \
    "${MONGO_CRED_PASS_KEY_DEFAULT:-}" \
    "$_MQL_STS")
  IFS=$'\x1f' read -r _MQL_SECRET _MQL_DIRECT_USER _MQL_USER_KEY _MQL_PASS_KEY <<<"$cred_row"
}

# ---------------------------------------------------------------------------
# _mql_probe_pod <sts_name>
# Own copy of the Ready-first/Running-fallback pod loop (see
# _ops_probe_pod / _fcv_probe_pod for the same pattern elsewhere).
# ---------------------------------------------------------------------------
_mql_probe_pod() {
  local sts_name="${1:?sts_name is required}"
  local pods_raw probe="" pod
  pods_raw=$(_recovery_list_pods "$sts_name") || return 1
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    local pod_ready
    pod_ready=$(_kubectl get pod "$pod" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || continue
    [[ "$pod_ready" == "True" ]] && {
      probe="$pod"
      break
    }
  done <<<"$pods_raw"
  if [[ -z "$probe" ]]; then
    while IFS= read -r pod; do
      [[ -z "$pod" ]] && continue
      local phase
      phase=$(_kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null) || continue
      [[ "$phase" == "Running" ]] && {
        probe="$pod"
        break
      }
    done <<<"$pods_raw"
  fi
  [[ -z "$probe" ]] && return 1
  printf '%s\n' "$probe"
}

# ---------------------------------------------------------------------------
# _mql_resolve_target <sts_name> <probe_pod> <target_pod_input> <user> <pass>
# Echoes "<exec_pod>\x1f<direct_host_or_empty>". Unlike _ops_resolve_target,
# an explicit target_pod_input is verified to actually belong to the
# resolved StatefulSet (via its own ownerReferences, same check
# pods_owned_by_sts/lib/pods.sh makes for pods/delete) before it is trusted
# as the exec target — this gateway loads and uses live MongoDB credentials
# against whatever pod it execs into, so an unverified target_pod_input
# would let a caller redirect an authenticated query/write at any pod in
# the namespace, not just a member of the deployment those credentials were
# resolved for. mql/write never passes a target_pod_input (writes always
# resolve the elected PRIMARY), so this check is only reachable from
# mql/read. Returns 1 when target_pod_input is empty and no PRIMARY is
# reachable, 2 when target_pod_input is non-empty but not owned by
# sts_name (including "pod doesn't exist").
# ---------------------------------------------------------------------------
_mql_resolve_target() {
  local sts_name="${1:?sts_name is required}" probe="${2:?probe pod is required}"
  local target_pod_input="${3:-}"
  local user="${4:?user is required}" pass="${5:?pass is required}"
  if [[ -n "$target_pod_input" ]]; then
    local owner
    owner=$(_kubectl get pod "$target_pod_input" \
      -o jsonpath='{.metadata.ownerReferences[?(@.kind=="StatefulSet")].name}' 2>/dev/null) || return 2
    [[ "$owner" == "$sts_name" ]] || return 2
    printf '%s\x1f' "$target_pod_input"
    return 0
  fi
  local primary_host
  primary_host=$(_recovery_primary_host "$sts_name" "$user" "$pass") || return 1
  printf '%s\x1f%s' "$probe" "$primary_host"
}

# ---------------------------------------------------------------------------
# _mql_mongosh <exec_pod> <direct_host> <user> <pass> <js>
# Dispatch to _recovery_mongosh_pod (direct_host empty: run inside exec_pod,
# connecting to its own localhost) or _recovery_mongosh_host (direct_host
# set: run from exec_pod, directConnection to direct_host).
# ---------------------------------------------------------------------------
_mql_mongosh() {
  local exec_pod="${1:?exec pod is required}" direct_host="${2:-}"
  local user="${3:?user is required}" pass="${4:?pass is required}" js="${5:?js is required}"
  if [[ -n "$direct_host" ]]; then
    _recovery_mongosh_host "$exec_pod" "$direct_host" "$user" "$pass" "$js"
  else
    _recovery_mongosh_pod "$exec_pod" "$user" "$pass" "$js"
  fi
}

# ---------------------------------------------------------------------------
# _mql_run_expr <exec_pod> <direct_host> <user> <pass> <expr> <ok_prefix> <err_prefix>
# Shared tail of mql_read_execute/mql_write_preview/mql_write_execute:
# wrap a JS expression in try/JSON.stringify/catch, run it, take the last
# non-empty output line (mongosh's own connection banner/warnings can
# precede it), strip a stray \r, and split on the ok/err sentinel prefix.
# Prints the JSON payload (success) or the error message (failure) with the
# prefix stripped either way. Returns 1 on connection/auth failure or a
# response with neither prefix (unexpected mongosh output).
# ---------------------------------------------------------------------------
_mql_run_expr() {
  local exec_pod="${1:?exec pod is required}" direct_host="${2:-}"
  local user="${3:?user is required}" pass="${4:?pass is required}"
  local expr="${5:?expr is required}" ok_prefix="${6:?ok_prefix is required}" err_prefix="${7:?err_prefix is required}"
  local js out

  js="try{print('${ok_prefix}:'+JSON.stringify(${expr}));}catch(e){print('${err_prefix}:'+e.message);}"
  out=$(_mql_mongosh "$exec_pod" "$direct_host" "$user" "$pass" "$js" \
    2>/dev/null | tail -1 | tr -d '\r') || return 1
  if [[ "$out" == "${ok_prefix}:"* ]]; then
    printf '%s' "${out#"${ok_prefix}":}"
    return 0
  fi
  printf '%s' "${out#"${err_prefix}":}"
  return 1
}

# ---------------------------------------------------------------------------
# mql_read_execute <exec_pod> <direct_host> <user> <pass> <database>
#                   <collection> <operation> <filter> <projection> <pipeline>
#                   <distinct_field> <limit>
# operation: find | aggregate | count | distinct. filter/projection/pipeline
# are pre-validated JSON text, embedded raw — the caller (mql/read.sh) must
# have already rejected any pipeline containing $out/$merge via
# mql_pipeline_has_write_stage, since aggregate has no other write gate.
# <limit> bounds find/aggregate/distinct result materialization (count has
# no array to bound) so a large collection can't exhaust mongosh/task memory
# before the task timeout: find uses cursor.limit() directly; aggregate
# cursors don't support cursor.limit() at all (MongoDB's own docs: use a
# $limit stage instead), so a {$limit: <limit>} stage is appended after
# whatever pipeline the caller supplied — always the *last* stage, so a
# caller-supplied $limit earlier in the pipeline can only shrink the result
# further, never grow past the gateway's cap; distinct has no cursor (one
# command, one response) so its already-materialized array is sliced
# client-side instead.
# Returns 1 on connection/auth failure, 2 on an unknown operation (caller
# bug, not a runtime failure).
# ---------------------------------------------------------------------------
mql_read_execute() {
  local exec_pod="${1:?exec pod is required}" direct_host="${2:-}"
  local user="${3:?user is required}" pass="${4:?pass is required}"
  local database="${5:?database is required}" collection="${6:?collection is required}"
  local operation="${7:?operation is required}"
  local filter="${8:-}" projection="${9:-}" pipeline="${10:-[]}"
  local distinct_field="${11:-}" limit="${12:-50}"
  local esc_col esc_field esc_db coll expr capped_pipeline
  # NOT "${8:-{}}": bash's word-scan for a ${param:-word} default ends at
  # the FIRST unescaped '}' it sees — a literal '{' in the default word is
  # not depth-counted, so "{}" as an inline default leaves a stray trailing
  # '}' appended to the RESULT whenever the parameter is actually set
  # (verified in bash 5.1: "${1:-{}}" with $1="hello" yields "hello}", not
  # "hello"). Assigning the '{}' default as a separate statement sidesteps
  # the parser pitfall entirely.
  [[ -z "$filter" ]] && filter='{}'
  [[ -z "$projection" ]] && projection='{}'

  esc_col=$(_escape_js_string "$collection")
  esc_db=$(_escape_js_string "$database")
  coll="db.getSiblingDB('${esc_db}').getCollection('${esc_col}')"

  case "$operation" in
    find)
      expr="${coll}.find(${filter},${projection}).limit(${limit}).toArray()"
      ;;
    aggregate)
      capped_pipeline=$(jq -c --argjson lim "$limit" '. + [{"$limit":$lim}]' <<<"$pipeline")
      expr="${coll}.aggregate(${capped_pipeline}).toArray()"
      ;;
    count)
      expr="({count: ${coll}.countDocuments(${filter})})"
      ;;
    distinct)
      esc_field=$(_escape_js_string "$distinct_field")
      expr="({values: ${coll}.distinct('${esc_field}',${filter}).slice(0,${limit})})"
      ;;
    *)
      return 2
      ;;
  esac

  _mql_run_expr "$exec_pod" "$direct_host" "$user" "$pass" "$expr" "MQLOK" "MQLERR"
}

# ---------------------------------------------------------------------------
# mql_write_preview <exec_pod> <direct_host> <user> <pass> <database>
#                    <collection> <operation> <filter> <document> <documents>
# dry_run preview: update_*/delete_* report candidate_count (all matching
# documents, via countDocuments) and would_change_count — the count the
# confirmed call can actually change, which for update_one/delete_one is
# capped at 1 since a *_one operation touches at most one document even
# when the filter matches more; sample_ids is limited to that same count
# (1 for *_one, up to 5 for *_many). insert_* have nothing live to preview,
# so the validated payload is echoed back as-is. Returns 1 on connection/
# auth failure, 2 on an unknown operation.
# ---------------------------------------------------------------------------
mql_write_preview() {
  local exec_pod="${1:?exec pod is required}" direct_host="${2:-}"
  local user="${3:?user is required}" pass="${4:?pass is required}"
  local database="${5:?database is required}" collection="${6:?collection is required}"
  local operation="${7:?operation is required}"
  local filter="${8:-}" document="${9:-}" documents="${10:-}"
  local esc_col esc_db coll expr sample_limit
  # See mql_read_execute's comment: an inline "${8:-{}}" default corrupts
  # any non-empty filter by appending a stray '}' (bash parser pitfall).
  [[ -z "$filter" ]] && filter='{}'

  case "$operation" in
    insert_one)
      printf '{"would_insert":%s}' "$document"
      return 0
      ;;
    insert_many)
      printf '{"would_insert_count":%s,"would_insert":%s}' "$(jq -c 'length' <<<"$documents")" "$documents"
      return 0
      ;;
    update_one | delete_one)
      sample_limit=1
      esc_col=$(_escape_js_string "$collection")
      esc_db=$(_escape_js_string "$database")
      coll="db.getSiblingDB('${esc_db}').getCollection('${esc_col}')"
      expr="(function(){var c=${coll}.countDocuments(${filter});return {candidate_count:c,would_change_count:(c>0?1:0),sample_ids:${coll}.find(${filter},{_id:1}).limit(${sample_limit}).toArray().map(function(d){return d._id;})};})()"
      ;;
    update_many | delete_many)
      sample_limit=5
      esc_col=$(_escape_js_string "$collection")
      esc_db=$(_escape_js_string "$database")
      coll="db.getSiblingDB('${esc_db}').getCollection('${esc_col}')"
      expr="(function(){var c=${coll}.countDocuments(${filter});return {candidate_count:c,would_change_count:c,sample_ids:${coll}.find(${filter},{_id:1}).limit(${sample_limit}).toArray().map(function(d){return d._id;})};})()"
      ;;
    *)
      return 2
      ;;
  esac

  _mql_run_expr "$exec_pod" "$direct_host" "$user" "$pass" "$expr" "MQLPRE" "MQLPREERR"
}

# ---------------------------------------------------------------------------
# mql_write_execute <exec_pod> <direct_host> <user> <pass> <database>
#                    <collection> <operation> <filter> <update> <document>
#                    <documents> <upsert>
# operation: insert_one | insert_many | update_one | update_many |
# delete_one | delete_many. upsert applies to update_one/update_many only.
# Returns the driver's own result document (insertedId,
# matchedCount/modifiedCount, deletedCount, ...). Returns 1 on connection/
# auth/execution failure, 2 on an unknown operation.
# ---------------------------------------------------------------------------
mql_write_execute() {
  local exec_pod="${1:?exec pod is required}" direct_host="${2:-}"
  local user="${3:?user is required}" pass="${4:?pass is required}"
  local database="${5:?database is required}" collection="${6:?collection is required}"
  local operation="${7:?operation is required}"
  local filter="${8:-}" update="${9:-}" document="${10:-}" documents="${11:-}"
  local upsert="${12:-false}"
  local esc_col esc_db coll expr upsert_js
  # See mql_read_execute's comment: an inline "${8:-{}}" default corrupts
  # any non-empty filter by appending a stray '}' (bash parser pitfall).
  [[ -z "$filter" ]] && filter='{}'

  esc_col=$(_escape_js_string "$collection")
  esc_db=$(_escape_js_string "$database")
  coll="db.getSiblingDB('${esc_db}').getCollection('${esc_col}')"
  upsert_js="false"
  bool_enabled "$upsert" && upsert_js="true"

  case "$operation" in
    insert_one)
      expr="${coll}.insertOne(${document})"
      ;;
    insert_many)
      expr="${coll}.insertMany(${documents})"
      ;;
    update_one)
      expr="${coll}.updateOne(${filter},${update},{upsert:${upsert_js}})"
      ;;
    update_many)
      expr="${coll}.updateMany(${filter},${update},{upsert:${upsert_js}})"
      ;;
    delete_one)
      expr="${coll}.deleteOne(${filter})"
      ;;
    delete_many)
      expr="${coll}.deleteMany(${filter})"
      ;;
    *)
      return 2
      ;;
  esac

  _mql_run_expr "$exec_pod" "$direct_host" "$user" "$pass" "$expr" "MQLWOK" "MQLWERR"
}
