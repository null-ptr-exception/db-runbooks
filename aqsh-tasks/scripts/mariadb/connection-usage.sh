#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/connection-usage.sh
# Read-only, point-in-time connection usage grouped by database account.
# Queries every pod so direct replica/read-service traffic is not hidden.
# =============================================================================

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi

# shellcheck source=../../lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=../../lib/k8s.sh
source "${LIB_DIR}/k8s.sh"
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"

CONTEXT="${K8S_CONTEXT:-}"
NAMESPACE="${DB_NAMESPACE:-${K8S_NAMESPACE:-}}"
RESOURCE="${MARIADB_RESOURCE:-mariadb}"
MDB=""
CONTAINER="${MARIADB_CONTAINER:-mariadb}"
ACCOUNT_LIMIT="${ACCOUNT_LIMIT:-10}"
MAX_ACCOUNT_LIMIT="${CONNECTION_USAGE_MAX_ACCOUNT_LIMIT:-50}"
UTIL_WARN_PCT="${CONNECTION_USAGE_WARN_PCT:-80}"
ACCOUNT_SHARE_WARN_PCT="${CONNECTION_USAGE_ACCOUNT_SHARE_WARN_PCT:-60}"
ACCOUNT_SHARE_WARN_MIN="${CONNECTION_USAGE_ACCOUNT_SHARE_WARN_MIN:-10}"
RESULT_FILE="${AQSH_RESULT_FILE:-}"

is_canonical_uint() {
  [[ "${1:-}" =~ ^(0|[1-9][0-9]*)$ ]]
}

emit() {
  local status="$1" reason="$2" summary="$3" partial="$4" extra="${5:-}" out
  [[ -n "$extra" ]] || extra='{}'
  out=$(jq -nc \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg summary "$summary" \
    --arg namespace "$NAMESPACE" \
    --argjson partial "$partial" \
    --argjson extra "$extra" \
    '{
      status: $status,
      reason_code: $reason,
      summary: $summary,
      namespace: $namespace,
      snapshot_type: "point-in-time",
      partial: $partial,
      changed: false
    } + $extra')
  [[ -n "$RESULT_FILE" ]] && printf '%s\n' "$out" > "$RESULT_FILE"
  printf '%s\n' "$out"
}

if [[ -z "$NAMESPACE" ]]; then
  emit BLOCKED INVALID_INPUT "namespace is required" false
  exit 0
fi
for policy_name in MAX_ACCOUNT_LIMIT UTIL_WARN_PCT ACCOUNT_SHARE_WARN_PCT ACCOUNT_SHARE_WARN_MIN; do
  if ! is_canonical_uint "${!policy_name}"; then
    emit ERROR INVALID_POLICY "internal connection-usage policy is invalid" false
    exit 1
  fi
done
if ! is_canonical_uint "$ACCOUNT_LIMIT" || \
    (( ACCOUNT_LIMIT < 1 || ACCOUNT_LIMIT > MAX_ACCOUNT_LIMIT )); then
  emit BLOCKED INVALID_ACCOUNT_LIMIT \
    "account_limit must be an integer between 1 and ${MAX_ACCOUNT_LIMIT}" false \
    "$(jq -nc --arg value "$ACCOUNT_LIMIT" --argjson max "$MAX_ACCOUNT_LIMIT" \
      '{invalid_value:$value, max_account_limit:$max}')"
  exit 0
fi

mariadb_set_target "$CONTEXT" "$NAMESPACE" "$RESOURCE" "" "$CONTAINER"
_on_ambiguous() {
  emit BLOCKED MARIADB_AMBIGUOUS \
    "namespace '${NAMESPACE}' must contain exactly one MariaDB instance" false
  exit 0
}
_on_none() {
  emit BLOCKED MARIADB_NOT_FOUND "no MariaDB instance found in '${NAMESPACE}'" false
  exit 0
}
mariadb_autodetect_target false _on_ambiguous _on_none
MDB="$MARIADB_NAME"

if ! MEMBER_PODS="$(mariadb_list_member_pods)"; then
  emit BLOCKED POD_TARGETS_UNRESOLVED \
    "cannot resolve exact member pods for MariaDB '${MDB}' in '${NAMESPACE}'" false
  exit 0
fi
mapfile -t PODS <<<"$MEMBER_PODS"

CURRENT_PRIMARY="$(mariadb_jsonpath "$RESOURCE" "$MDB" '{.status.currentPrimary}' 2>/dev/null || true)"
ROOT_PASSWORD="$(mariadb_read_root_password "$CURRENT_PRIMARY" "${PODS[@]}")" || {
  emit BLOCKED ROOT_PASSWORD_UNAVAILABLE "cannot read the managed root credential from any MariaDB pod" false
  exit 0
}

# JSON_OBJECT keeps account names safely encoded without exposing raw process
# rows. CONNECTION_ID() excludes this task's own administrative connection.
SQL_QUERY=$(printf '%s\n' \
  'SELECT @@GLOBAL.max_connections;' \
  "SELECT JSON_OBJECT('account', USER, 'current_connections', COUNT(*), 'active_connections', SUM(CASE WHEN COMMAND = 'Sleep' THEN 0 ELSE 1 END), 'idle_connections', SUM(CASE WHEN COMMAND = 'Sleep' THEN 1 ELSE 0 END), 'longest_active_seconds', MAX(CASE WHEN COMMAND = 'Sleep' THEN 0 ELSE TIME END)) FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID() AND USER IS NOT NULL AND USER <> '' AND LOWER(USER) NOT IN ('system user', 'event_scheduler') GROUP BY USER ORDER BY COUNT(*) DESC, USER ASC;")

SNAPSHOT_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
ALL_ROWS='[]'
POD_RESULTS='[]'
QUERIED_PODS=0
FAILED_PODS=0
CONNECTION_CAPACITY=0

for pod in "${PODS[@]}"; do
  raw=""
  if ! raw=$(mariadb_sql "$pod" "$ROOT_PASSWORD" "$SQL_QUERY"); then
    FAILED_PODS=$((FAILED_PODS + 1))
    POD_RESULTS=$(jq -c --arg pod "$pod" \
      '. + [{pod:$pod, collected:false, error:"SQL collection failed"}]' <<<"$POD_RESULTS")
    continue
  fi

  pod_max=$(sed -n '1p' <<<"$raw")
  rows_text=$(sed '1d' <<<"$raw")
  if ! is_canonical_uint "$pod_max" || (( pod_max < 1 )); then
    FAILED_PODS=$((FAILED_PODS + 1))
    POD_RESULTS=$(jq -c --arg pod "$pod" \
      '. + [{pod:$pod, collected:false, error:"invalid max_connections result"}]' <<<"$POD_RESULTS")
    continue
  fi
  if ! pod_rows=$(sed '/^[[:space:]]*$/d' <<<"$rows_text" | jq -sc '.'); then
    FAILED_PODS=$((FAILED_PODS + 1))
    POD_RESULTS=$(jq -c --arg pod "$pod" \
      '. + [{pod:$pod, collected:false, error:"invalid account usage result"}]' <<<"$POD_RESULTS")
    continue
  fi
  # MariaDB 10.6 JSON_OBJECT may encode aggregate DECIMAL values (notably SUM)
  # as JSON strings. Normalise those known numeric fields at the trust boundary;
  # `tonumber` fails closed for anything else.
  if ! pod_rows=$(jq -ce 'map({
      account: (if (.account | type) == "string" then .account
                else error("account is not a string") end),
      current_connections: (.current_connections | tonumber),
      active_connections: (.active_connections | tonumber),
      idle_connections: (.idle_connections | tonumber),
      longest_active_seconds: (.longest_active_seconds // 0 | tonumber)
    })' <<<"$pod_rows"); then
    FAILED_PODS=$((FAILED_PODS + 1))
    POD_RESULTS=$(jq -c --arg pod "$pod" \
      '. + [{pod:$pod, collected:false, error:"malformed account usage result"}]' <<<"$POD_RESULTS")
    continue
  fi

  pod_rows=$(jq -c --arg pod "$pod" 'map(. + {pod:$pod})' <<<"$pod_rows")
  pod_current=$(jq '[.[].current_connections] | add // 0' <<<"$pod_rows")
  pod_utilization=$(jq -n --argjson current "$pod_current" --argjson capacity "$pod_max" \
    'if $capacity == 0 then 0 else (($current * 1000 / $capacity) | round / 10) end')

  QUERIED_PODS=$((QUERIED_PODS + 1))
  CONNECTION_CAPACITY=$((CONNECTION_CAPACITY + pod_max))
  ALL_ROWS=$(jq -c --argjson rows "$pod_rows" '. + $rows' <<<"$ALL_ROWS")
  POD_RESULTS=$(jq -c \
    --arg pod "$pod" \
    --argjson current "$pod_current" \
    --argjson capacity "$pod_max" \
    --argjson utilization "$pod_utilization" \
    '. + [{pod:$pod, collected:true, current_connections:$current,
           max_connections:$capacity, utilization_percent:$utilization}]' <<<"$POD_RESULTS")
done

if (( QUERIED_PODS == 0 )); then
  emit ERROR CONNECTION_USAGE_UNAVAILABLE "connection usage could not be collected from any MariaDB pod" false \
    "$(jq -nc --arg snapshot_at "$SNAPSHOT_AT" --argjson pods "$POD_RESULTS" \
      '{snapshot_at:$snapshot_at, pods:$pods, accounts:[], warnings:[]}')"
  exit 1
fi

TOTAL_CONNECTIONS=$(jq '[.[].current_connections] | add // 0' <<<"$ALL_ROWS")
UTILIZATION_PERCENT=$(jq -n \
  --argjson current "$TOTAL_CONNECTIONS" \
  --argjson capacity "$CONNECTION_CAPACITY" \
  'if $capacity == 0 then 0 else (($current * 1000 / $capacity) | round / 10) end')

ALL_ACCOUNTS=$(jq -c --argjson total "$TOTAL_CONNECTIONS" '
  group_by(.account)
  | map({
      account: .[0].account,
      current_connections: ([.[].current_connections] | add),
      active_connections: ([.[].active_connections] | add),
      idle_connections: ([.[].idle_connections] | add),
      longest_active_seconds: ([.[].longest_active_seconds] | max),
      pods: ([.[] | select(.current_connections > 0) | .pod] | unique)
    })
  | map(. + {
      share_percent: (if $total == 0 then 0
        else ((.current_connections * 1000 / $total) | round / 10) end)
    })
  | sort_by([-.current_connections, .account])' <<<"$ALL_ROWS")
TOTAL_ACCOUNT_COUNT=$(jq 'length' <<<"$ALL_ACCOUNTS")
ACCOUNTS=$(jq -c --argjson account_limit "$ACCOUNT_LIMIT" \
  '.[:$account_limit]' <<<"$ALL_ACCOUNTS")
RETURNED_ACCOUNT_COUNT=$(jq 'length' <<<"$ACCOUNTS")
TRUNCATED=$(jq -n \
  --argjson total "$TOTAL_ACCOUNT_COUNT" \
  --argjson returned "$RETURNED_ACCOUNT_COUNT" \
  '$returned < $total')

WARNINGS=$(jq -nc \
  --argjson utilization "$UTILIZATION_PERCENT" \
  --argjson utilization_threshold "$UTIL_WARN_PCT" \
  --argjson total "$TOTAL_CONNECTIONS" \
  --argjson account_threshold "$ACCOUNT_SHARE_WARN_PCT" \
  --argjson account_min "$ACCOUNT_SHARE_WARN_MIN" \
  --argjson accounts "$ALL_ACCOUNTS" '
  ([if $utilization >= $utilization_threshold then {
      code:"CONNECTION_UTILIZATION_HIGH",
      utilization_percent:$utilization,
      threshold_percent:$utilization_threshold
    } else empty end]
   + [if ($total >= $account_min and ($accounts | length) > 0 and
             $accounts[0].share_percent >= $account_threshold) then {
      code:"ACCOUNT_CONNECTION_SHARE_HIGH",
      account:$accounts[0].account,
      share_percent:$accounts[0].share_percent,
      threshold_percent:$account_threshold
    } else empty end])')

EXTRA=$(jq -nc \
  --arg snapshot_at "$SNAPSHOT_AT" \
  --argjson requested_pods "${#PODS[@]}" \
  --argjson queried_pods "$QUERIED_PODS" \
  --argjson failed_pods "$FAILED_PODS" \
  --argjson total_connections "$TOTAL_CONNECTIONS" \
  --argjson connection_capacity "$CONNECTION_CAPACITY" \
  --argjson utilization_percent "$UTILIZATION_PERCENT" \
  --argjson total_account_count "$TOTAL_ACCOUNT_COUNT" \
  --argjson returned_account_count "$RETURNED_ACCOUNT_COUNT" \
  --argjson account_limit "$ACCOUNT_LIMIT" \
  --argjson truncated "$TRUNCATED" \
  --argjson accounts "$ACCOUNTS" \
  --argjson pods "$POD_RESULTS" \
  --argjson warnings "$WARNINGS" '
  {
    snapshot_at:$snapshot_at,
    requested_pods:$requested_pods,
    queried_pods:$queried_pods,
    failed_pods:$failed_pods,
    total_connections:$total_connections,
    connection_capacity:$connection_capacity,
    capacity_scope:"sum-of-queried-pods",
    utilization_percent:$utilization_percent,
    total_account_count:$total_account_count,
    returned_account_count:$returned_account_count,
    account_limit:$account_limit,
    truncated:$truncated,
    accounts:$accounts,
    pods:$pods,
    warnings:$warnings
  }')

if (( FAILED_PODS > 0 )); then
  emit PARTIAL CONNECTION_USAGE_PARTIAL \
    "connection usage collected from ${QUERIED_PODS}/${#PODS[@]} MariaDB pods" true "$EXTRA"
elif (( $(jq 'length' <<<"$WARNINGS") > 0 )); then
  emit WARN CONNECTION_USAGE_WARNING "connection usage collected with warnings" false "$EXTRA"
else
  emit READY CONNECTION_USAGE_READY "connection usage collected" false "$EXTRA"
fi
