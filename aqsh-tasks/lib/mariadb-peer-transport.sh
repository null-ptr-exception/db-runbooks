#!/usr/bin/env bash
# =============================================================================
# lib/mariadb-peer-transport.sh
# Neutral AQSH submit/poll transport shared by MariaDB orchestrators.
#
# Payloads are sent verbatim. Callers that need additional schema fields (for
# example blue/green's peer credentials) must add them before calling here.
# Failure output is deliberately restricted to stable identifiers so a caller
# can diagnose a peer task without leaking its message, logs, or secret-bearing
# backend response.
# =============================================================================

[[ -n "${_MARIADB_PEER_TRANSPORT_LOADED:-}" ]] && return 0
_MARIADB_PEER_TRANSPORT_LOADED=1

# Read by the task scripts that source this lib, so ShellCheck cannot see it.
# shellcheck disable=SC2034
MDBT_PEER_ERR=""

mdbt_validate_url() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^https?://[A-Za-z0-9._:/-]+$ ]]; then
    mdbt_fail "$op" "${name} must be an http(s) URL" \
      "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

# mdbt_peer_call_task <peer_url> <peer_token> <task_path> <payload> [timeout_seconds]
# Echoes the peer task's inner result data (compact JSON) on success, returns 0.
# On any failure sets MDBT_PEER_ERR to a stable, public-safe marker and returns
# 1 (does NOT exit, so callers can roll back).
# MDBT_PEER_ERR is read by the scripts that source this lib.
# shellcheck disable=SC2034
mdbt_peer_call_task() {
  local peer_url="$1" peer_token="$2" task_path="$3" payload="$4" timeout="${5:-540}"
  local encoded submit code body task_id resp status curl_rc
  # Wall clock, not a sum of sleeps: each poll can also spend up to 15s inside
  # curl, so counting only the sleeps lets a degraded peer push the loop far
  # past `timeout` — and past the surrounding aqsh task budget.
  local deadline=$(( $(date +%s) + timeout ))

  MDBT_PEER_ERR=""
  encoded="${task_path//\//%2F}"

  if submit="$(curl -sS --connect-timeout 5 -m 60 -w $'\n%{http_code}' \
    -X POST "${peer_url}/tasks/${encoded}" \
    -H "Authorization: Bearer ${peer_token}" \
    -H 'Content-Type: application/json' \
    -d "$payload" 2>/dev/null)"; then
    curl_rc=0
  else
    curl_rc=$?
  fi
  if (( curl_rc != 0 )); then
    MDBT_PEER_ERR='{"stage":"peer-operation","reason":"PEER_UNREACHABLE"}'
    return 1
  fi

  code="$(printf '%s' "$submit" | tail -n1)"
  body="$(printf '%s' "$submit" | sed '$d')"
  if [[ "$code" != "202" ]]; then
    # Keep the marker public-safe: HTTP class only, never the response body
    # (which can carry auth diagnostics).
    case "$code" in
      401|403) MDBT_PEER_ERR='{"stage":"peer-operation","reason":"PEER_AUTH_FAILED"}' ;;
      400)     MDBT_PEER_ERR='{"stage":"peer-operation","reason":"PEER_REQUEST_REJECTED"}' ;;
      *)       MDBT_PEER_ERR="$(jq -nc --arg code "$code" \
                 '{stage:"peer-operation",reason:"PEER_SUBMIT_FAILED",httpStatus:$code}')" ;;
    esac
    return 1
  fi
  task_id="$(jq -r '.id // empty' <<<"$body" 2>/dev/null || true)"
  if [[ -z "$task_id" ]]; then
    MDBT_PEER_ERR='{"stage":"peer-operation","reason":"PEER_SUBMIT_FAILED"}'
    return 1
  fi

  while (( $(date +%s) < deadline )); do
    if resp="$(curl -sS --connect-timeout 5 -m 15 \
      -H "Authorization: Bearer ${peer_token}" \
      "${peer_url}/executions/${task_id}" 2>/dev/null)"; then
      curl_rc=0
    else
      curl_rc=$?
    fi
    if (( curl_rc != 0 )); then
      MDBT_PEER_ERR='{"stage":"peer-operation","reason":"PEER_UNREACHABLE"}'
      return 1
    fi
    status="$(jq -r '.status // empty' <<<"$resp" 2>/dev/null || true)"
    case "$status" in
      completed)
        jq -c '
          .result.data as $d
          | (($d | try fromjson catch null) // (if ($d | type) == "object" then $d else {} end))
          | (.data // {})
        ' <<<"$resp" 2>/dev/null || printf '{}'
        return 0
        ;;
      failed)
        MDBT_PEER_ERR="$(jq -c '
          {stage:"peer-operation",reason:"PEER_TASK_FAILED"}
          + (if .reason then {peerReason:.reason} else {} end)
          + (if .operation then {operation:.operation} else {} end)
          + (if .peerStage then {peerStage:.peerStage} else {} end)
        ' <<<"$(_mdbt_peer_failure_marker "$resp")")"
        return 1
        ;;
    esac
    sleep 5
  done

  MDBT_PEER_ERR='{"stage":"peer-operation","reason":"PEER_TASK_TIMEOUT"}'
  return 1
}

# mdbt_peer_call_task_capture <out_var> <peer_url> <peer_token> <task_path> <payload> [timeout]
# Same contract as mdbt_peer_call_task, but stores success JSON in <out_var> and
# keeps MDBT_PEER_ERR in the *current* shell. Callers must not wrap this (or
# mdbt_peer_call_task) in $(...) when they need the failure marker — command
# substitution runs in a subshell and drops MDBT_PEER_ERR.
mdbt_peer_call_task_capture() {
  local __out_var="$1"; shift
  local __tmp __rc=0
  __tmp="$(mktemp)"
  mdbt_peer_call_task "$@" >"$__tmp" || __rc=$?
  if [[ "$__rc" -eq 0 ]]; then
    printf -v "$__out_var" '%s' "$(<"$__tmp")"
  else
    printf -v "$__out_var" '%s' ''
  fi
  rm -f "$__tmp"
  return "$__rc"
}

_mdbt_peer_failure_marker() {
  local response="${1:-}"
  [[ -n "$response" ]] || response="{}"
  jq -c '
    def stable($value; $pattern):
      if ($value | type) == "string" and ($value | test($pattern))
      then $value else null end;
    .result.data as $raw
    | (($raw | try fromjson catch null)
       // (if ($raw | type) == "object" then $raw else {} end)) as $detail
    | {stage: "peer-operation"}
      + (stable($detail.reason; "^[A-Z][A-Z0-9_]*$") as $reason
         | if $reason == null then {} else {reason: $reason} end)
      + (stable($detail.operation; "^[a-z0-9][a-z0-9_/-]*$") as $operation
         | if $operation == null then {} else {operation: $operation} end)
      + (stable($detail.data.stage; "^[a-z0-9][a-z0-9_-]*$") as $peerStage
         | if $peerStage == null then {} else {peerStage: $peerStage} end)
  ' <<<"$response" 2>/dev/null || printf '%s' '{"stage":"peer-operation"}'
}
