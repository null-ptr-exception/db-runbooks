#!/usr/bin/env bash
# =============================================================================
# mongodb-oplog.sh — oplog size/window helpers for the oplog/status and
# oplog/resize aqsh tasks (see docs/mongodb/oplog.md).
#
# Dependencies (sourced by the calling script, not here):
#   logging.sh           — log_debug/log_info
#   k8s.sh               — _kubectl
#   mongodb.sh           — _mongo_uri_percent_encode (used by mongodb-recovery.sh)
#   mongodb-recovery.sh  — _recovery_list_pods, _recovery_mongosh_pod,
#                          _recovery_mongosh_host
#
# replSetResizeOplog only resizes the LOCAL oplog of the node it runs
# against (MongoDB docs) — every size-touching helper here therefore
# operates member-by-member via directConnection, never assuming the
# primary speaks for the whole set.
# =============================================================================

[[ -n "${_MONGODB_OPLOG_LIB_LOADED:-}" ]] && return 0
_MONGODB_OPLOG_LIB_LOADED=1

# ---------------------------------------------------------------------------
# _oplog_probe_pod <sts_name>
# Echo the name of a Ready pod of the StatefulSet (fallback: any Running
# pod) to exec mongosh from. Same Ready-first loop as _recovery_primary_host
# / _fcv_probe_pod / _reconfig_probe_pod — each lib carries its own copy by
# convention rather than reaching into another lib's private helpers.
# ---------------------------------------------------------------------------
_oplog_probe_pod() {
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
# _oplog_member_hosts <probe_pod> <user> <pass>
# Space-separated list of every current RS member's host:port
# (rs.status().members[].name), read from any reachable pod — used to
# iterate status/resize per member rather than assuming primary-only.
# Returns 1 when the probe pod can't answer rs.status() at all.
# ---------------------------------------------------------------------------
_oplog_member_hosts() {
  local probe="${1:?probe pod is required}" user="${2:?user is required}" pass="${3:?pass is required}"
  local out
  out=$(_recovery_mongosh_pod "$probe" "$user" "$pass" \
    "try{print('OPLOGHOSTS:'+rs.status().members.map(function(m){return m.name;}).join(' '));}catch(e){print('OPLOGHOSTSERR:'+e.message);}" \
    2>/dev/null | tail -1 | tr -d '\r') || return 1
  [[ "$out" == OPLOGHOSTS:* ]] || return 1
  printf '%s' "${out#OPLOGHOSTS:}"
}

# ---------------------------------------------------------------------------
# _oplog_member_info <probe_pod> <member_host> <user> <pass>
# One mongosh round trip against a specific member (directConnection), using
# the documented db.getReplicationInfo() helper rather than hand-rolling
# oplog.rs queries. Prints:
#   {"host":"...","size_mb":990,"used_mb":512,"window_hours":36.2}
# window_hours is whatever getReplicationInfo reports for an empty/near-empty
# oplog (0 or a tiny value) — never a divide-by-zero crash. Returns 1 when
# the member doesn't answer (unreachable, not yet initial-synced, auth
# failure).
# ---------------------------------------------------------------------------
_oplog_member_info() {
  local probe="${1:?probe pod is required}" host="${2:?host is required}"
  local user="${3:?user is required}" pass="${4:?pass is required}"
  local js out
  js="try{var i=db.getReplicationInfo();"
  js+="print('OPLOGINFO:'+JSON.stringify({size_mb:Math.round(i.logSizeMB),"
  js+="used_mb:Math.round(i.usedMB),window_hours:Math.round((i.timeDiffHours||0)*100)/100}));"
  js+="}catch(e){print('OPLOGINFOERR:'+e.message);}"
  out=$(_recovery_mongosh_host "$probe" "$host" "$user" "$pass" "$js" \
    2>/dev/null | tail -1 | tr -d '\r') || return 1
  [[ "$out" == OPLOGINFO:* ]] || return 1
  jq -c --arg host "$host" '. + {host:$host}' <<<"${out#OPLOGINFO:}"
}

# ---------------------------------------------------------------------------
# _oplog_resize_member <probe_pod> <member_host> <user> <pass> <target_mb>
# Run replSetResizeOplog on a specific member (directConnection). Prints the
# server's response JSON on success and returns 0; prints the diagnostic
# message and returns 1 on failure — including MongoDB's own minimum-size
# enforcement, which is never hardcoded here since the floor has moved
# across server versions; the server's own error is the source of truth.
# ---------------------------------------------------------------------------
_oplog_resize_member() {
  local probe="${1:?probe pod is required}" host="${2:?host is required}"
  local user="${3:?user is required}" pass="${4:?pass is required}" target_mb="${5:?target_mb is required}"
  local js out
  js="try{var r=db.adminCommand({replSetResizeOplog:1,size:${target_mb}});"
  js+="print('OPLOGRESIZE:'+JSON.stringify(r));}"
  js+="catch(e){print('OPLOGRESIZEERR:'+(e.codeName||'')+':'+e.message);}"
  out=$(_recovery_mongosh_host "$probe" "$host" "$user" "$pass" "$js" \
    2>/dev/null | tail -1 | tr -d '\r') || return 1
  if [[ "$out" == OPLOGRESIZE:* ]]; then
    local payload="${out#OPLOGRESIZE:}"
    printf '%s' "$payload"
    printf '%s' "$payload" | jq -e '.ok == 1' >/dev/null 2>&1 || return 1
    return 0
  fi
  if [[ "$out" == OPLOGRESIZEERR:* ]]; then
    printf '%s' "${out#OPLOGRESIZEERR:}"
    return 1
  fi
  printf '%s' "$out"
  return 1
}
