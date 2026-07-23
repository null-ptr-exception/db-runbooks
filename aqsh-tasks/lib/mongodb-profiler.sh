#!/usr/bin/env bash
# =============================================================================
# mongodb-profiler.sh — query profiler helpers for the profiler/status and
# profiler/set aqsh tasks (see docs/mongodb/profiler.md).
#
# Dependencies (sourced by the calling script, not here):
#   logging.sh           — log_debug/log_info
#   k8s.sh               — _kubectl
#   mongodb.sh           — _mongo_uri_percent_encode (used by mongodb-recovery.sh)
#   mongodb-recovery.sh  — _recovery_list_pods, _recovery_mongosh_pod,
#                          _recovery_mongosh_host, _recovery_primary_host
#
# The profiler level is per-node state (each mongod has its own setting) —
# _profiler_resolve_target below always resolves to a single, named node:
# either the caller's explicit target_pod, or (default) the elected
# PRIMARY. Same target-resolution shape as mongodb-ops.sh; duplicated
# rather than shared, per this codebase's own convention of each gateway
# lib carrying its own small copy instead of cross-depending on another
# gateway's private helpers (see mongodb-fcv.sh's _fcv_probe_pod comment).
# =============================================================================

[[ -n "${_MONGODB_PROFILER_LIB_LOADED:-}" ]] && return 0
_MONGODB_PROFILER_LIB_LOADED=1

# ---------------------------------------------------------------------------
# _profiler_probe_pod <sts_name>
# Own copy of the Ready-first/Running-fallback pod loop.
# ---------------------------------------------------------------------------
_profiler_probe_pod() {
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
# _profiler_resolve_target <sts_name> <probe_pod> <target_pod_input> <user> <pass>
# Echoes "<exec_pod>\x1f<direct_host_or_empty>" — see mongodb-ops.sh's
# _ops_resolve_target for the identical shape/rationale.
# ---------------------------------------------------------------------------
_profiler_resolve_target() {
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
# _profiler_mongosh <exec_pod> <direct_host> <user> <pass> <js>
# Dispatch to _recovery_mongosh_pod (direct_host empty) or
# _recovery_mongosh_host (direct_host set) — same shape as mongodb-ops.sh's
# _ops_mongosh.
# ---------------------------------------------------------------------------
_profiler_mongosh() {
  local exec_pod="${1:?exec pod is required}" direct_host="${2:-}"
  local user="${3:?user is required}" pass="${4:?pass is required}" js="${5:?js is required}"
  if [[ -n "$direct_host" ]]; then
    _recovery_mongosh_host "$exec_pod" "$direct_host" "$user" "$pass" "$js"
  else
    _recovery_mongosh_pod "$exec_pod" "$user" "$pass" "$js"
  fi
}

# ---------------------------------------------------------------------------
# profiler_get_status <exec_pod> <direct_host> <user> <pass>
# Prints {"level":N,"slowms":N,"sampleRate":N} — level is normalized from
# db.getProfilingStatus()'s historically-named "was" field (a MongoDB shell
# quirk: the same field name is reused whether you're reading current state
# or the pre-change value from a set call) into a clearer name for this
# task family's API. Returns 1 on a connection/auth failure.
# ---------------------------------------------------------------------------
profiler_get_status() {
  local exec_pod="${1:?exec pod is required}" direct_host="${2:-}"
  local user="${3:?user is required}" pass="${4:?pass is required}"
  local js out
  js="try{var s=db.getProfilingStatus();"
  js+="print('PROFSTATUS:'+JSON.stringify({level:s.was,slowms:s.slowms,"
  js+="sampleRate:(s.sampleRate===undefined?1:s.sampleRate)}));"
  js+="}catch(e){print('PROFSTATUSERR:'+e.message);}"
  out=$(_profiler_mongosh "$exec_pod" "$direct_host" "$user" "$pass" "$js" \
    2>/dev/null | tail -1 | tr -d '\r') || return 1
  [[ "$out" == PROFSTATUS:* ]] || return 1
  printf '%s' "${out#PROFSTATUS:}"
}

# ---------------------------------------------------------------------------
# profiler_set <exec_pod> <direct_host> <user> <pass> <level> <slowms> <sample_rate>
# Runs setProfilingLevel(level, {slowms, sampleRate}). Prints
# {"level":N,"slowms":N,"sampleRate":N} — the NEW state read back via
# profiler_get_status after the set succeeds (never trusts the command's own
# "was"-shaped response for the post-change state, to avoid the same naming
# quirk profiler_get_status normalizes away). Returns 1 on failure.
# ---------------------------------------------------------------------------
profiler_set() {
  local exec_pod="${1:?exec pod is required}" direct_host="${2:-}"
  local user="${3:?user is required}" pass="${4:?pass is required}"
  local level="${5:?level is required}" slowms="${6:?slowms is required}" sample_rate="${7:?sample_rate is required}"
  local js out
  js="try{db.setProfilingLevel(${level},{slowms:${slowms},sampleRate:${sample_rate}});"
  js+="print('PROFSET:ok');}"
  js+="catch(e){print('PROFSETERR:'+(e.codeName||'')+':'+e.message);}"
  out=$(_profiler_mongosh "$exec_pod" "$direct_host" "$user" "$pass" "$js" \
    2>/dev/null | tail -1 | tr -d '\r') || return 1
  if [[ "$out" == "PROFSET:ok" ]]; then
    local final
    # if/then form (not a bare command) so a failure here doesn't trip the
    # caller script's `set -e` before this function gets to return 1 itself.
    if final=$(profiler_get_status "$exec_pod" "$direct_host" "$user" "$pass"); then
      printf '%s' "$final"
      return 0
    else
      return 1
    fi
  fi
  if [[ "$out" == PROFSETERR:* ]]; then
    printf '%s' "${out#PROFSETERR:}"
    return 1
  fi
  printf '%s' "$out"
  return 1
}
