#!/usr/bin/env bash
# The executor provides AQSH_URL/AQSH_TOKEN through private deployment config.
# Read options as environment values; never interpolate them into shell code.
set +x
set -euo pipefail
: "${AQSH_URL:?configure AQSH_URL on the executor}"
: "${AQSH_TOKEN:?configure AQSH_TOKEN securely on the executor}"
BASE_URL="${AQSH_URL%/}"
[[ "$BASE_URL" =~ ^https?:// ]] || { echo 'Invalid AQSH URL' >&2; exit 1; }
POLL_SECONDS="${AQSH_POLL_TIMEOUT_SECONDS:-180}"
[[ "$POLL_SECONDS" =~ ^[1-9][0-9]{0,2}$ ]] && (( POLL_SECONDS <= 180 )) \
  || { echo 'Invalid poll timeout (expected 1..180 seconds)' >&2; exit 1; }
BODY="$(jq -nc \
  --arg ns "${RD_OPTION_NAMESPACE:-}" --arg pod "${RD_OPTION_TARGET_POD:-}" \
  --arg action "${RD_OPTION_ACTION:-diagnose}" --arg id "${RD_OPTION_CONNECTION_ID:-}" \
  --arg dry "${RD_OPTION_DRY_RUN:-true}" --arg confirm "${RD_OPTION_CONFIRM:-false}" \
  --arg token "${RD_OPTION_EXPECTED_SESSION:-}" \
  '{namespace:$ns,target_pod:$pod,action:$action,connection_id:$id,
    dry_run:$dry,confirm:$confirm,expected_session:$token}')"
# Only this route can be submitted. No automatic POST retries.
EXECUTION_ID=unavailable
submission_finished() {
  local rc=$?
  trap - EXIT
  printf 'AQSH execution: %s; inspect that execution before resubmitting any termination.\n' \
    "$EXECUTION_ID" >&2
  exit "$rc"
}
trap submission_finished EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
RESPONSE="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
  -H "Authorization: Bearer $AQSH_TOKEN" -H 'Content-Type: application/json' \
  --data "$BODY" "$BASE_URL/tasks/sessions")"
ID="$(jq -er '.id | strings' <<< "$RESPONSE")"
[[ "$ID" =~ ^[a-zA-Z0-9_-]+$ && ${#ID} -le 128 ]] \
  || { echo 'Invalid execution ID' >&2; exit 1; }
EXECUTION_ID="$ID"
printf 'AQSH execution: %s\n' "$EXECUTION_ID"
DEADLINE=$((SECONDS + POLL_SECONDS))
pause_poll() {
  local remaining=$((DEADLINE - SECONDS))
  (( remaining > 0 )) || return 0
  (( remaining <= 2 )) || remaining=2
  sleep "$remaining"
}
while (( SECONDS < DEADLINE )); do
  REMAINING=$((DEADLINE - SECONDS))
  (( REMAINING > 0 )) || break
  (( REMAINING <= 15 )) || REMAINING=15
  if ! RESPONSE="$(curl --fail --silent --show-error --connect-timeout 5 --max-time "$REMAINING" \
    -H "Authorization: Bearer $AQSH_TOKEN" "$BASE_URL/executions/$EXECUTION_ID")"; then
    pause_poll
    continue
  fi
  STATE="$(jq -er '.status | strings' <<< "$RESPONSE")"
  case "$STATE" in
    completed|failed|cancelled)
      RESULT="$(jq -ec '.result.data as $data |
        (if ($data|type)=="string" then ($data|fromjson) else $data end) |
        select(type=="object" and has("reason_code"))' <<< "$RESPONSE")" || {
          echo "Execution $STATE without a readable task result; outcome unavailable" >&2
          exit 1
        }
      jq . <<< "$RESULT"
      [[ "$STATE" == completed ]] || exit 1
      case "$(jq -r .status <<< "$RESULT")" in
        READY|PARTIAL|NO_ACTION|DRY_RUN_READY|VERIFIED) exit 0 ;;
        *) exit 1 ;;
      esac
      ;;
    queued|running|retrying|pending) pause_poll ;;
    *) echo "Unknown execution state: $STATE" >&2; exit 1 ;;
  esac
done
echo "Polling timed out for $EXECUTION_ID; inspect that execution before resubmitting" >&2
exit 1
