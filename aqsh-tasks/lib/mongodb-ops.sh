#!/usr/bin/env bash
# =============================================================================
# mongodb-ops.sh — currentOp listing/killing helpers for the ops/list and
# ops/kill aqsh tasks (see docs/mongodb/ops.md).
#
# Dependencies (sourced by the calling script, not here):
#   logging.sh           — log_debug/log_info
#   k8s.sh               — _kubectl
#   mongodb.sh           — _mongo_uri_percent_encode (used by mongodb-recovery.sh)
#   mongodb-recovery.sh  — _recovery_list_pods, _recovery_mongosh_pod,
#                          _recovery_mongosh_host, _recovery_primary_host
#
# currentOp/killOp are per-node views (each mongod only knows its own
# in-flight operations) — an opid observed via ops/list on one member means
# nothing on another. _ops_resolve_target below always resolves to a single,
# named node: either the caller's explicit target_pod, or (default) the
# elected PRIMARY, so ops/list and ops/kill share one unambiguous target.
# =============================================================================

[[ -n "${_MONGODB_OPS_LIB_LOADED:-}" ]] && return 0
_MONGODB_OPS_LIB_LOADED=1

# ---------------------------------------------------------------------------
# _ops_probe_pod <sts_name>
# Own copy of the Ready-first/Running-fallback pod loop (see mongodb-fcv.sh's
# _fcv_probe_pod comment for why each lib carries its own rather than
# reaching into another gateway's private helper).
# ---------------------------------------------------------------------------
_ops_probe_pod() {
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
# _ops_resolve_target <sts_name> <probe_pod> <target_pod_input> <user> <pass>
# Echoes "<exec_pod>\x1f<direct_host_or_empty>":
#   - target_pod_input non-empty: exec_pod=target_pod_input, direct_host
#     empty (connect to that pod's own localhost via _ops_mongosh below).
#   - target_pod_input empty (default): exec_pod=<probe_pod>,
#     direct_host=<elected PRIMARY's host:port> (directConnection from the
#     probe, same technique as fcv/oplog).
# Returns 1 when target_pod_input is empty and no PRIMARY is reachable.
# ---------------------------------------------------------------------------
_ops_resolve_target() {
  local sts_name="${1:?sts_name is required}" probe="${2:?probe pod is required}"
  local target_pod_input="${3:-}"
  local user="${4:?user is required}" pass="${5:?pass is required}"
  if [[ -n "$target_pod_input" ]]; then
    printf '%s\x1f' "$target_pod_input"
    return 0
  fi
  local primary_host
  primary_host=$(_recovery_primary_host "$sts_name" "$user" "$pass") || return 1
  printf '%s\x1f%s' "$probe" "$primary_host"
}

# ---------------------------------------------------------------------------
# _ops_mongosh <exec_pod> <direct_host> <user> <pass> <js>
# Dispatch to _recovery_mongosh_pod (direct_host empty: run inside exec_pod,
# connecting to its own localhost) or _recovery_mongosh_host (direct_host
# set: run from exec_pod, directConnection to direct_host).
# ---------------------------------------------------------------------------
_ops_mongosh() {
  local exec_pod="${1:?exec pod is required}" direct_host="${2:-}"
  local user="${3:?user is required}" pass="${4:?pass is required}" js="${5:?js is required}"
  if [[ -n "$direct_host" ]]; then
    _recovery_mongosh_host "$exec_pod" "$direct_host" "$user" "$pass" "$js"
  else
    _recovery_mongosh_pod "$exec_pod" "$user" "$pass" "$js"
  fi
}

# Shared field projection: keep this identical between ops_list_current and
# ops_get_one so a caller sees the same shape from either task. secs_running
# comes back as a BSON Long (not a plain number) for some operation shapes —
# JSON.stringify would otherwise emit {high,low,unsigned} instead of a
# number (same BSON-Long-via-JSON.stringify issue reconfig's `term` field
# hits — see mongodb-reconfig.sh's _RECONFIG_FACTS_JS comment).
# shellcheck disable=SC2016  # single-quoted on purpose: this is JavaScript
readonly _OPS_PROJECT_JS='function(o){
  var secs = o.secs_running;
  if (secs !== undefined && secs !== null && secs.toNumber) { secs = secs.toNumber(); }
  return {
    opid: o.opid,
    secs_running: (secs===undefined?null:secs),
    op: (o.op||null),
    ns: (o.ns||null),
    desc: (o.desc||null),
    client: (o.client||o.client_s||null),
    planSummary: (o.planSummary||null),
    waitingForLock: !!o.waitingForLock,
    effectiveUsers: (o.effectiveUsers||[]).map(function(u){return u.user;}),
    killPending: !!o.killPending
  };
}'

# ---------------------------------------------------------------------------
# ops_list_current <exec_pod> <direct_host> <user> <pass> <min_secs_running>
# Prints a JSON array of currently active operations (min_secs_running=0
# means no filter beyond "active"). Excludes MongoDB's own internal
# housekeeping threads (op:"none" — NoopWriter, JournalFlusher,
# OplogApplier-*, Checkpointer, etc.), which are always "active" but never
# something a caller would want to see or kill. Returns 1 on a connection/
# auth failure — an empty result set (no matching ops) is success with
# "[]", not a failure.
# ---------------------------------------------------------------------------
ops_list_current() {
  local exec_pod="${1:?exec pod is required}" direct_host="${2:-}"
  local user="${3:?user is required}" pass="${4:?pass is required}" min_secs="${5:-0}"
  local js out
  js="try{var filter={active:true,op:{\$ne:'none'}};"
  if ((min_secs > 0)); then
    js+="filter.secs_running={\$gte:${min_secs}};"
  fi
  js+="var project=${_OPS_PROJECT_JS};"
  js+="print('OPSLIST:'+JSON.stringify(db.currentOp(filter).inprog.map(project)));"
  js+="}catch(e){print('OPSLISTERR:'+e.message);}"
  out=$(_ops_mongosh "$exec_pod" "$direct_host" "$user" "$pass" "$js" \
    2>/dev/null | tail -1 | tr -d '\r') || return 1
  [[ "$out" == OPSLIST:* ]] || return 1
  printf '%s' "${out#OPSLIST:}"
}

# ---------------------------------------------------------------------------
# ops_get_one <exec_pod> <direct_host> <user> <pass> <opid>
# Prints the single matching op's projected JSON, or "null" when no active
# operation with that opid exists (already finished, wrong node, or never
# existed) — that is a normal, non-error outcome for callers to check.
# Returns 1 only on a connection/auth failure.
# ---------------------------------------------------------------------------
ops_get_one() {
  local exec_pod="${1:?exec pod is required}" direct_host="${2:-}"
  local user="${3:?user is required}" pass="${4:?pass is required}" opid="${5:?opid is required}"
  local js out
  js="try{var project=${_OPS_PROJECT_JS};"
  js+="var m=db.currentOp({opid:${opid}}).inprog;"
  js+="print('OPSONE:'+JSON.stringify(m.length?project(m[0]):null));"
  js+="}catch(e){print('OPSONEERR:'+e.message);}"
  out=$(_ops_mongosh "$exec_pod" "$direct_host" "$user" "$pass" "$js" \
    2>/dev/null | tail -1 | tr -d '\r') || return 1
  [[ "$out" == OPSONE:* ]] || return 1
  printf '%s' "${out#OPSONE:}"
}

# ---------------------------------------------------------------------------
# ops_kill <exec_pod> <direct_host> <user> <pass> <opid>
# Runs killOp for <opid>. killOp only sets an interrupt flag — MongoDB does
# not guarantee the operation is gone the instant this returns ok:1 — so
# this only reports the command's own result; the calling script is
# responsible for an honest post-kill re-check rather than treating this
# return as proof of termination. Returns 1 on failure (including "no such
# operation" from the server, which killOp itself reports as ok:1 with no
# error in most server versions — callers should not assume return 1 means
# "opid didn't exist"; use ops_get_one before/after to know that).
# ---------------------------------------------------------------------------
ops_kill() {
  local exec_pod="${1:?exec pod is required}" direct_host="${2:-}"
  local user="${3:?user is required}" pass="${4:?pass is required}" opid="${5:?opid is required}"
  local js out
  js="try{var r=db.adminCommand({killOp:1,op:${opid}});"
  js+="print('OPSKILL:'+JSON.stringify(r));}"
  js+="catch(e){print('OPSKILLERR:'+(e.codeName||'')+':'+e.message);}"
  out=$(_ops_mongosh "$exec_pod" "$direct_host" "$user" "$pass" "$js" \
    2>/dev/null | tail -1 | tr -d '\r') || return 1
  if [[ "$out" == OPSKILL:* ]]; then
    local payload="${out#OPSKILL:}"
    printf '%s' "$payload"
    printf '%s' "$payload" | jq -e '.ok == 1' >/dev/null 2>&1 || return 1
    return 0
  fi
  if [[ "$out" == OPSKILLERR:* ]]; then
    printf '%s' "${out#OPSKILLERR:}"
    return 1
  fi
  printf '%s' "$out"
  return 1
}
