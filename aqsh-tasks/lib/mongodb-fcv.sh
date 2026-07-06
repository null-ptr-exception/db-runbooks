#!/usr/bin/env bash
# =============================================================================
# mongodb-fcv.sh — featureCompatibilityVersion (FCV) helpers for the
# fcv/status and fcv/set aqsh tasks (see docs/mongodb/fcv.md).
#
# Dependencies (sourced by the calling script, not here):
#   logging.sh           — log_debug/log_info
#   k8s.sh               — _kubectl
#   mongodb.sh           — _mongo_uri_percent_encode (used by mongodb-recovery.sh)
#   mongodb-recovery.sh  — _recovery_list_pods, _recovery_mongosh_host
#
# All mongosh round trips use the printed-sentinel idiom
# (FCVINFO:/FCVSET:/FCVSETERR: prefix + tail -1): _recovery_mongosh_host
# merges kubectl's own stderr into stdout, so a kubectl-layer failure would
# otherwise be indistinguishable from real JS output — only lines carrying
# the sentinel prefix are trusted (same technique as _recovery_detect_data_path).
# =============================================================================

[[ -n "${_MONGODB_FCV_LIB_LOADED:-}" ]] && return 0
_MONGODB_FCV_LIB_LOADED=1

# ---------------------------------------------------------------------------
# fcv_binary_series <full_version>
# Reduce a mongod binary version to its release series: "7.0.21" -> "7.0".
# Returns 1 (empty stdout) when the input doesn't look like a version.
# ---------------------------------------------------------------------------
fcv_binary_series() {
  local full="${1:-}"
  [[ "$full" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+.*)?$ ]] || return 1
  printf '%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# ---------------------------------------------------------------------------
# fcv_previous_series <series>
# The FCV a binary series may be downgraded to — MongoDB's documented
# compatibility table, NOT plain major-1 arithmetic: 5.0's predecessor is
# 4.4 and 4.4's is 4.2 (the pre-5.0 point-release era). From 5.0 onward the
# annual-release rule holds, so unknown series >= 9.0 with minor 0 derive
# numerically; anything else (< 4.2, or an X.Y with Y != 0 like "7.1")
# returns 1 — callers must treat that as UNSUPPORTED_SERVER_VERSION, never
# guess. This table is duplicated verbatim in docs/mongodb/fcv.md — keep
# both in sync.
# ---------------------------------------------------------------------------
fcv_previous_series() {
  local series="${1:?series is required}"
  case "$series" in
    8.0) printf '7.0' ;;
    7.0) printf '6.0' ;;
    6.0) printf '5.0' ;;
    5.0) printf '4.4' ;;
    4.4) printf '4.2' ;;
    4.2) printf '4.0' ;;
    *)
      local major="${series%%.*}" minor="${series#*.}"
      if [[ "$major" =~ ^[0-9]+$ && "$minor" == "0" ]] && ((major >= 9)); then
        printf '%s.0' "$((major - 1))"
      else
        return 1
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# fcv_allowed_targets <series>
# Space-separated set of FCV values a binary of <series> accepts:
# "<previous> <series>". Returns 1 when the series has no known mapping.
# ---------------------------------------------------------------------------
fcv_allowed_targets() {
  local series="${1:?series is required}"
  local prev
  prev=$(fcv_previous_series "$series") || return 1
  printf '%s %s' "$prev" "$series"
}

# ---------------------------------------------------------------------------
# fcv_direction <current_fcv> <target_fcv>
# Prints upgrade | downgrade | none (numeric major.minor comparison).
# ---------------------------------------------------------------------------
fcv_direction() {
  local current="${1:?current is required}" target="${2:?target is required}"
  local cmaj="${current%%.*}" cmin="${current#*.}"
  local tmaj="${target%%.*}" tmin="${target#*.}"
  if ((tmaj > cmaj || (tmaj == cmaj && tmin > cmin))); then
    printf 'upgrade'
  elif ((tmaj < cmaj || (tmaj == cmaj && tmin < cmin))); then
    printf 'downgrade'
  else
    printf 'none'
  fi
}

# ---------------------------------------------------------------------------
# _fcv_probe_pod <sts_name>
# Echo the name of a Ready pod of the StatefulSet (fallback: any Running
# pod) to exec mongosh from. Same Ready-first loop as _recovery_primary_host
# / _reconfig_probe_pod — each lib carries its own copy by convention rather
# than reaching into another lib's private helpers.
# ---------------------------------------------------------------------------
_fcv_probe_pod() {
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
# fcv_read_info <from_pod> <primary_host> <user> <pass>
# One mongosh round trip against the PRIMARY. Prints a single JSON object:
#   {"version":"7.0.21","fcv":"7.0","targetFcv":null}
# targetFcv is non-null only in a transitional state — a previous
# setFeatureCompatibilityVersion was interrupted and the FCV document still
# carries its pending target. Returns 1 when no FCVINFO sentinel came back
# (auth failure, unreachable primary, kubectl error).
# ---------------------------------------------------------------------------
fcv_read_info() {
  local from_pod="${1:?from_pod is required}" primary_host="${2:?primary_host is required}"
  local user="${3:?user is required}" pass="${4:?pass is required}"
  local js out
  js="try{var f=db.adminCommand({getParameter:1,featureCompatibilityVersion:1}).featureCompatibilityVersion;"
  js+="print('FCVINFO:'+JSON.stringify({version:db.version(),fcv:f.version,targetFcv:(f.targetVersion===undefined?null:f.targetVersion)}));}"
  js+="catch(e){print('FCVERR:'+e.message);}"
  log_debug "mongo-fcv" "reading server version + FCV from primary ${primary_host} via pod ${from_pod}"
  out=$(_recovery_mongosh_host "$from_pod" "$primary_host" "$user" "$pass" "$js" \
    2>/dev/null | tail -1 | tr -d '\r') || return 1
  log_debug "mongo-fcv" "fcv_read_info raw sentinel line: ${out}"
  [[ "$out" == FCVINFO:* ]] || return 1
  printf '%s' "${out#FCVINFO:}"
}

# ---------------------------------------------------------------------------
# fcv_execute_set <from_pod> <primary_host> <user> <pass> <target> <server_major>
# Run setFeatureCompatibilityVersion on the PRIMARY. `confirm: true` is
# included only when the binary major is >= 7: 7.0+ requires it for
# downgrades (and accepts it for upgrades), while <= 6.0 servers may reject
# the then-unknown field. On success prints the server's response JSON and
# returns 0; on failure prints whatever diagnostic came back
# ("codeName:message" from FCVSETERR, or the raw last line) and returns 1.
# ---------------------------------------------------------------------------
fcv_execute_set() {
  local from_pod="${1:?from_pod is required}" primary_host="${2:?primary_host is required}"
  local user="${3:?user is required}" pass="${4:?pass is required}"
  local target="${5:?target is required}" server_major="${6:?server_major is required}"
  [[ "$target" =~ ^[0-9]+\.[0-9]+$ ]] || return 1

  local confirm_js="" js out
  if ((server_major >= 7)); then
    confirm_js="cmd.confirm=true;"
    log_debug "mongo-fcv" "including confirm:true (server major ${server_major} >= 7 requires it for downgrade, accepts it for upgrade)"
  else
    log_debug "mongo-fcv" "omitting confirm field (server major ${server_major} <= 6 may reject the unknown field)"
  fi
  js="try{var cmd={setFeatureCompatibilityVersion:'${target}'};${confirm_js}"
  js+="var r=db.adminCommand(cmd);print('FCVSET:'+JSON.stringify(r));}"
  js+="catch(e){print('FCVSETERR:'+(e.codeName||'')+':'+e.message);}"
  log_debug "mongo-fcv" "executing setFeatureCompatibilityVersion('${target}') on primary ${primary_host} via pod ${from_pod}"
  out=$(_recovery_mongosh_host "$from_pod" "$primary_host" "$user" "$pass" "$js" \
    2>/dev/null | tail -1 | tr -d '\r') || return 1
  log_debug "mongo-fcv" "fcv_execute_set raw sentinel line: ${out}"
  if [[ "$out" == FCVSET:* ]]; then
    local payload="${out#FCVSET:}"
    printf '%s' "$payload"
    printf '%s' "$payload" | jq -e '.ok == 1' >/dev/null 2>&1 || return 1
    return 0
  fi
  if [[ "$out" == FCVSETERR:* ]]; then
    printf '%s' "${out#FCVSETERR:}"
    return 1
  fi
  printf '%s' "$out"
  return 1
}
