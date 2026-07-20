#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/switch-primary.sh
# Promote a chosen replica to primary within one replicated MariaDB instance,
# by patching spec.replication.primary.podIndex. The mariadb-operator performs a
# graceful switchover (read-lock old primary, wait for replicas in sync, promote
# target, reconnect). AWS-RDS analogue: FailoverDBCluster (with a target).
#
# Safety split: before changing desired state, this task fences writes on the
# old primary and drains every replica to the fenced GTID. The OPERATOR then
# owns the actual promotion/reconnect sequence. This prevents both an unsafe
# handoff and the legacy operator's unbounded read_only + retry failure mode.
#
# Version-compat like restart.sh: the target field is probed with `kubectl
# explain` rather than assuming a CRD version.
# =============================================================================

# Capture caller-supplied name before mariadb.sh defaults MARIADB_NAME to "mariadb".
MDB_INPUT="${MARIADB_NAME:-${MARIADB_STS_NAME:-}}"

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi
# shellcheck source=../../lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=../../lib/response.sh
source "${LIB_DIR}/response.sh"
# shellcheck source=../../lib/k8s.sh
source "${LIB_DIR}/k8s.sh"
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"
# shellcheck source=../../lib/mariadb-operator.sh
source "${LIB_DIR}/mariadb-operator.sh"

bool() { case "${1:-}" in 1 | true | TRUE | yes | YES | on | ON) return 0 ;; *) return 1 ;; esac; }

# --- inputs ------------------------------------------------------------------
CONTEXT="${K8S_CONTEXT:-}"
NAMESPACE="${DB_NAMESPACE:-${K8S_NAMESPACE:-}}"
RESOURCE="${MARIADB_RESOURCE:-mariadb}"
MDB="$MDB_INPUT"
CONTAINER="${MARIADB_CONTAINER:-mariadb}"
TARGET_INDEX="${TARGET_POD_INDEX:-}"       # optional: replica podIndex; auto-picked if empty
AUTO_SELECTED=false                        # set true when we pick the target ourselves
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"        # seconds to wait for the switch to complete
# Recovery (rollback/eviction) uses a shorter budget so forward + recovery waits
# still fit inside the aqsh task timeout and the final status always gets emitted.
RECOVERY_TIMEOUT="${SWITCH_RECOVERY_TIMEOUT:-120}"
POLL_INTERVAL="${SWITCH_POLL_INTERVAL:-5}" # seconds between status polls
# Policy / safety knobs — internal config (env-overridable), NOT task inputs:
# the acceptable lag is a per-deployment policy, and auto-rollback is a safety
# behaviour that should stay on rather than be a caller's per-call choice.
LAG_THRESHOLD="${LAG_THRESHOLD:-5}"        # max pre-fence lag; GTID drain is authoritative
REPLICATION_DRAIN_TIMEOUT="${REPLICATION_DRAIN_TIMEOUT:-60}"
ROLLBACK_ON_TIMEOUT="${ROLLBACK_ON_TIMEOUT:-true}"
# Gated until an e2e proves the eviction recovery is reliable (see #59): a bad
# auto pod-deletion could turn a hiccup into an outage.
ALLOW_POD_EVICTION="${ALLOW_POD_EVICTION:-false}"
RESULT_FILE="${AQSH_RESULT_FILE:-}"

# Fence ownership is deliberately explicit. Before a successful CR patch this
# task owns read_only and must undo it on every exit path. After the patch the
# operator owns the switchover, so an EXIT trap must not race it by enabling
# writes behind its back.
FENCE_ACTIVE=false
OPERATOR_OWNS_SWITCH=false
PRIMARY_POD=""
ROOT_PASSWORD=""

_set_primary_read_only() {
  local value="$1" observed
  mariadb_sql "$PRIMARY_POD" "$ROOT_PASSWORD" "SET GLOBAL read_only = ${value}" >/dev/null || return 1
  observed="$(mariadb_sql "$PRIMARY_POD" "$ROOT_PASSWORD" 'SELECT @@global.read_only')" || return 1
  [[ "$observed" == "$value" ]]
}

_release_owned_fence() {
  bool "$FENCE_ACTIVE" || return 0
  bool "$OPERATOR_OWNS_SWITCH" && return 0
  if _set_primary_read_only 0; then
    FENCE_ACTIVE=false
    return 0
  fi
  return 1
}

_desired_primary_index() {
  local cr
  cr="$(_cr_json)" || return 1
  jq -r '.spec.replication.primary.podIndex // empty' <<<"$cr"
}

_cleanup_owned_fence() {
  # A signal may arrive after the API server accepted the patch but before
  # kubectl returned. In that ambiguous window, desired state is the authority:
  # never clear the fence if the operator can already see the new target.
  if bool "$FENCE_ACTIVE" && ! bool "$OPERATOR_OWNS_SWITCH" && [[ -n "${FROM_INDEX:-}" ]]; then
    cleanup_desired="$(_desired_primary_index 2>/dev/null || true)"
    if [[ -n "$cleanup_desired" && "$cleanup_desired" != "$FROM_INDEX" ]]; then
      OPERATOR_OWNS_SWITCH=true
    fi
  fi
  _release_owned_fence >/dev/null 2>&1 || true
}
_signal_exit() { exit "$1"; }
trap _cleanup_owned_fence EXIT
trap '_signal_exit 130' INT
trap '_signal_exit 143' TERM

# emit <status> <reason> <summary> <changed:bool> [extra_json]
emit() {
  local status="$1" reason="$2" summary="$3" changed="$4" extra="${5:-}" out
  [[ -n "$extra" ]] || extra='{}'
  out=$(jq -nc \
    --arg status "$status" --arg reason "$reason" --arg summary "$summary" \
    --arg namespace "$NAMESPACE" --arg mdb "${MDB:-}" \
    --arg repl_source "${REPLICAS_SOURCE:-}" \
    --argjson from "$(json_num_or_null "${FROM_INDEX:-}")" \
    --argjson to "$(json_num_or_null "${TARGET_INDEX:-}")" \
    --argjson dry_run "$(bool "$DRY_RUN" && echo true || echo false)" \
    --argjson confirm "$(bool "$CONFIRM" && echo true || echo false)" \
    --argjson auto_selected "$(bool "$AUTO_SELECTED" && echo true || echo false)" \
    --argjson changed "$changed" \
    --argjson extra "$extra" \
    '{
      status: $status, reason_code: $reason, summary: $summary,
      namespace: $namespace, mdb: $mdb, operator_controlled: true,
      from_pod_index: $from, to_pod_index: $to, target_auto_selected: $auto_selected,
      replicas_source: (if $repl_source == "" then null else $repl_source end),
      dry_run: $dry_run, confirm: $confirm, changed: $changed
    } + $extra')
  [[ -n "$RESULT_FILE" ]] && printf '%s\n' "$out" > "$RESULT_FILE"
  printf '%s\n' "$out"
}

json_num_or_null() { [[ "${1:-}" =~ ^[0-9]+$ ]] && printf '%s' "$1" || printf 'null'; }

_cr_json() { _kubectl get "$RESOURCE" "$MDB" -o json 2>/dev/null; }
_ready() { jq -r '.status.conditions[]? | select(.type=="Ready") | .status' <<<"$1" | tail -1; }
_primary_index() { jq -r '.status.currentPrimaryPodIndex // empty' <<<"$1"; }

# --- legacy replica-health fallback ------------------------------------------
# The current-generation operator publishes per-replica health at
# status.replication.replicas; the legacy mmontes-era operator (group
# mariadb.*.mmontes.io) never does. When that map is absent we ask each replica
# pod directly and synthesize the SAME {slaveIORunning, slaveSQLRunning,
# secondsBehindMaster} shape, so auto-select and Guard 4 keep one source-agnostic
# code path. The extra healthQuery object preserves why an entry is unavailable
# without exposing SQL output. A pod we cannot read is recorded as UNKNOWN
# (never omitted), so Guard 4's all_ok stays exactly as strict as the CR-status
# path — we never blind-switch to a replica whose lag we couldn't confirm.
_unavailable_replica_entry() {
  local status="$1" row_count="${2:-0}"
  jq -nc --arg status "$status" --argjson rows "$row_count" '{
    slaveIORunning: null,
    slaveSQLRunning: null,
    secondsBehindMaster: null,
    healthQuery: {status: $status, rowCount: $rows}
  }'
}

_replica_entry_via_sql() {
  local pod="$1" pw="$2" out io sql lag connection_name row_count
  if ! out="$(mariadb_sql_vertical "$pod" "$pw" "SHOW ALL SLAVES STATUS")"; then
    _unavailable_replica_entry query_failed
    return 0
  fi
  if [[ -z "$out" ]]; then
    _unavailable_replica_entry query_empty
    return 0
  fi

  # mariadb -E prints one Slave_IO_Running field per connection. Requiring
  # exactly one prevents an arbitrary first connection from being promoted.
  row_count="$(awk -F': *' '$1 ~ "^[* ]*Slave_IO_Running$" {n++} END {print n+0}' <<<"$out")"
  if [[ "$row_count" -eq 0 ]]; then
    _unavailable_replica_entry malformed_result
    return 0
  fi
  if [[ "$row_count" -ne 1 ]]; then
    _unavailable_replica_entry multiple_connections "$row_count"
    return 0
  fi

  io="$(mariadb_status_field Slave_IO_Running <<<"$out")"
  sql="$(mariadb_status_field Slave_SQL_Running <<<"$out")"
  lag="$(mariadb_status_field Seconds_Behind_Master <<<"$out")"
  connection_name="$(mariadb_status_field Connection_name <<<"$out")"
  jq -nc --arg io "$io" --arg sql "$sql" --arg lag "$lag" \
    --arg connection_name "$connection_name" '{
    slaveIORunning: ($io == "Yes"),
    slaveSQLRunning: ($sql == "Yes"),
    secondsBehindMaster: (if ($lag | test("^[0-9]+$")) then ($lag | tonumber) else null end),
    healthQuery: {
      status: "ok",
      rowCount: 1,
      connectionNamePresent: ($connection_name != "")
    }
  }'
}

# Build the status.replication.replicas-equivalent map (keyed by pod name) from
# live SHOW ALL SLAVES STATUS across every non-primary replica. The returned
# envelope includes a redacted diagnostic even if credentials cannot be read.
_build_replicas_via_sql() {
  local pw i pod entry map='{}' candidates=()
  for ((i = 0; i < CR_REPLICAS; i++)); do
    [[ "$i" == "$FROM_INDEX" ]] && continue
    candidates+=("${MDB}-${i}")
  done
  if ! pw="$(mariadb_read_root_password "${MDB}-${FROM_INDEX}" "${candidates[@]}")"; then
    jq -nc '{replicas: {}, diagnostic: {status: "credentials_unavailable", query: "SHOW ALL SLAVES STATUS"}}'
    return 0
  fi
  for pod in "${candidates[@]}"; do
    entry="$(_replica_entry_via_sql "$pod" "$pw")" || entry="$(_unavailable_replica_entry parser_failed)"
    map="$(jq -c --arg k "$pod" --argjson v "$entry" '.[$k] = $v' <<<"$map")"
  done
  jq -nc --argjson replicas "$map" --argjson count "${#candidates[@]}" '{
    replicas: $replicas,
    diagnostic: {status: "completed", query: "SHOW ALL SLAVES STATUS", podCount: $count}
  }'
}

# --- resolve target ----------------------------------------------------------
mariadb_set_target "$CONTEXT" "$NAMESPACE" "$RESOURCE" "$MDB_INPUT" "$CONTAINER"

_on_ambiguous() { emit BLOCKED MARIADB_AMBIGUOUS "several MariaDB CRs in '${NAMESPACE}'; set mdb to choose one" false "$(jq -n --arg c "$1" '{candidates: ($c|split(","))}')"; exit 0; }
_on_none() { emit BLOCKED MARIADB_OPERATOR_REQUIRED "no MariaDB CR found in '${NAMESPACE}' (operator-driven switch needs one)" false; exit 0; }
if [[ -z "$MDB" ]]; then
  mariadb_autodetect_target false _on_ambiguous _on_none   # sets MARIADB_NAME or exits
  MDB="$MARIADB_NAME"
else
  MDB="$MDB_INPUT"
fi

# --- guards ------------------------------------------------------------------
# Guard 1: version/capability — the CRD must expose replication.primary.podIndex.
if ! mariadb_operator_metadata_field_supported "$RESOURCE" "replication.primary.podIndex"; then
  emit BLOCKED SWITCH_UNSUPPORTED "MariaDB CRD does not expose spec.replication.primary.podIndex; this operator version cannot switch the primary" false; exit 0
fi

CR_JSON="$(_cr_json)" || true
if [[ -z "$CR_JSON" ]]; then
  emit BLOCKED MARIADB_OPERATOR_REQUIRED "MariaDB CR '${MDB}' not found in '${NAMESPACE}'" false; exit 0
fi

# Guard 2: must be a replication cluster with >= 2 replicas.
REPL_ENABLED="$(jq -r '.spec.replication.enabled // false' <<<"$CR_JSON")"
CR_REPLICAS="$(jq -r '.spec.replicas // 1' <<<"$CR_JSON")"
if [[ "$REPL_ENABLED" != "true" || "$CR_REPLICAS" -lt 2 ]]; then
  emit BLOCKED NOT_REPLICATED "switch-primary needs a replication MariaDB with >= 2 replicas (spec.replication.enabled + spec.replicas)" false \
    "$(jq -n --argjson r "$CR_REPLICAS" --arg e "$REPL_ENABLED" '{replicas: $r, replication_enabled: ($e == "true")}')"; exit 0
fi

FROM_INDEX="$(_primary_index "$CR_JSON")"
if [[ -z "$FROM_INDEX" ]]; then
  emit BLOCKED CURRENT_PRIMARY_UNKNOWN "cannot determine the current primary podIndex (status.currentPrimaryPodIndex empty)" false; exit 0
fi

DESIRED_INDEX="$(jq -r '.spec.replication.primary.podIndex // empty' <<<"$CR_JSON")"
if [[ -z "$DESIRED_INDEX" || "$DESIRED_INDEX" != "$FROM_INDEX" ]]; then
  emit BLOCKED SWITCH_ALREADY_IN_PROGRESS "desired primary podIndex (${DESIRED_INDEX:-unknown}) differs from current primary (${FROM_INDEX}); another switch is already in progress" false; exit 0
fi

if [[ ! "$LAG_THRESHOLD" =~ ^[0-9]+$ || ! "$REPLICATION_DRAIN_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  emit ERROR SWITCH_POLICY_INVALID "LAG_THRESHOLD must be a non-negative integer and REPLICATION_DRAIN_TIMEOUT must be a positive integer" false; exit 1
fi

# Resolve the replica-health map ONCE; auto-select and Guard 4 both read it, so
# neither cares which operator generation produced it. Current gen: the CR's
# status.replication.replicas. Legacy (mmontes) gen: that key is absent, so fall
# back to live SHOW ALL SLAVES STATUS. Fallback fails soft — an empty map just
# lets the guards below block, never a blind switch.
REPLICAS_JSON="$(jq -c '.status.replication.replicas // {}' <<<"$CR_JSON")"
REPLICAS_SOURCE="cr_status"
REPLICAS_QUERY_DIAGNOSTIC='null'
if [[ "$REPLICAS_JSON" == "{}" ]]; then
  _sql_result="$(_build_replicas_via_sql)" || _sql_result='{"replicas":{},"diagnostic":{"status":"build_failed","query":"SHOW ALL SLAVES STATUS"}}'
  REPLICAS_JSON="$(jq -c '.replicas // {}' <<<"$_sql_result")"
  REPLICAS_QUERY_DIAGNOSTIC="$(jq -c '.diagnostic // null' <<<"$_sql_result")"
  REPLICAS_SOURCE="show_all_slaves_status"
fi

# Target selection: an explicit podIndex, or — when the caller gives none — the
# best replica we pick ourselves (AWS RDS FailoverDBCluster likewise makes the
# target optional). Auto-pick = the healthy replica with the least pre-fence lag
# within LAG_THRESHOLD (tie-break: lowest podIndex). Exact catch-up is proven
# later with MASTER_GTID_WAIT after writes have been fenced.
if [[ -n "$TARGET_INDEX" ]]; then
  if [[ ! "$TARGET_INDEX" =~ ^[0-9]+$ ]]; then
    emit BLOCKED TARGET_INVALID "target must be a non-negative integer podIndex" false; exit 0
  fi
else
  TARGET_INDEX="$(jq -r --argjson threshold "$LAG_THRESHOLD" --arg mdb "$MDB" '
    to_entries
    | map({idx: (.key | ltrimstr($mdb + "-") | (try tonumber catch null)),
           lag: .value.secondsBehindMaster, v: .value})
    | map(select(.idx != null and .v.slaveIORunning == true and .v.slaveSQLRunning == true
                 and (.lag != null) and (.lag <= $threshold)))
    | sort_by(.lag, .idx)
    | (.[0].idx // "")' <<<"$REPLICAS_JSON")"
  if [[ -z "$TARGET_INDEX" ]]; then
    emit BLOCKED NO_ELIGIBLE_REPLICA "no healthy replica is within the pre-fence lag limit (lag_threshold=${LAG_THRESHOLD}s); nothing safe to switch to" false \
      "$(jq -nc --argjson replicas "$REPLICAS_JSON" --argjson diagnostic "$REPLICAS_QUERY_DIAGNOSTIC" \
        '{replicas: $replicas} + (if $diagnostic == null then {} else {replica_health_query: $diagnostic} end)')"; exit 0
  fi
  AUTO_SELECTED=true
fi

# Guard 3: target in range and not already primary.
if [[ "$TARGET_INDEX" -ge "$CR_REPLICAS" ]]; then
  emit BLOCKED TARGET_OUT_OF_RANGE "target podIndex ${TARGET_INDEX} is out of range (0..$((CR_REPLICAS-1)))" false; exit 0
fi
if [[ "$TARGET_INDEX" == "$FROM_INDEX" ]]; then
  emit UNCHANGED ALREADY_PRIMARY "podIndex ${TARGET_INDEX} is already the primary; nothing to do" false; exit 0
fi

# Guard 4: bounded health pre-check. The replica-health map (REPLICAS_JSON, from CR
# status or the legacy SHOW ALL SLAVES STATUS fallback) is keyed by pod name
# (<mdb>-<index>). Verify the TARGET pod is actually a known replica (a bare
# all(...) would pass vacuously if the target key were missing) AND that every
# replica is healthy and within the pre-fence lag budget. This is an outage-risk
# guard, not the consistency proof; the apply path fences writes and drains to a
# fixed GTID before it patches the CR.
TARGET_KEY="${MDB}-${TARGET_INDEX}"
REPL_CHECK="$(jq --argjson threshold "$LAG_THRESHOLD" --arg tk "$TARGET_KEY" '
  def healthy: (.slaveIORunning == true and .slaveSQLRunning == true and (.secondsBehindMaster != null) and (.secondsBehindMaster <= $threshold));
  . as $r
  | ($r[$tk]) as $t
  | {
      target_present: ($t != null),
      target_ok: ($t != null and ($t | healthy)),
      all_ok: (($r | length) > 0 and all($r[]; healthy)),
      replicas: $r
    }' <<<"$REPLICAS_JSON")"
if [[ "$(jq -r '.target_present' <<<"$REPL_CHECK")" != "true" ]]; then
  emit BLOCKED TARGET_NOT_A_REPLICA "target podIndex ${TARGET_INDEX} (pod ${TARGET_KEY}) is not a known replica in status.replication.replicas" false \
    "$(jq -c '{replicas: .replicas}' <<<"$REPL_CHECK")"; exit 0
fi
if [[ "$(jq -r '.target_ok and .all_ok' <<<"$REPL_CHECK")" != "true" ]]; then
  emit BLOCKED REPLICAS_NOT_READY_TO_DRAIN "replicas (incl. the target) are not all healthy and within the pre-fence lag limit (lag_threshold=${LAG_THRESHOLD}s)" false \
    "$(jq -c '{replicas: .replicas}' <<<"$REPL_CHECK")"; exit 0
fi

# --- dry-run / confirm -------------------------------------------------------
_pick_note="$(bool "$AUTO_SELECTED" && echo " (auto-selected)" || echo "")"
if bool "$DRY_RUN"; then
  emit READY SWITCH_DRY_RUN "dry run: would fence primary podIndex ${FROM_INDEX}, drain replicas to its GTID, then switch to ${TARGET_INDEX}${_pick_note}" false; exit 0
fi
bool "$CONFIRM" || { emit BLOCKED SWITCH_CONFIRM_REQUIRED "set confirm=true with dry_run=false to switch the primary" false; exit 0; }

# --- fence + GTID drain ------------------------------------------------------
PRIMARY_POD="${MDB}-${FROM_INDEX}"
replica_pods=()
for ((i = 0; i < CR_REPLICAS; i++)); do
  [[ "$i" == "$FROM_INDEX" ]] || replica_pods+=("${MDB}-${i}")
done

if ! ROOT_PASSWORD="$(mariadb_read_root_password "$PRIMARY_POD" "${replica_pods[@]}")"; then
  emit ERROR FENCE_CREDENTIALS_UNAVAILABLE "cannot read MariaDB root credentials; no write fence was applied" false; exit 1
fi

initial_read_only="$(mariadb_sql "$PRIMARY_POD" "$ROOT_PASSWORD" 'SELECT @@global.read_only' || true)"
if [[ "$initial_read_only" != "0" ]]; then
  emit BLOCKED PRIMARY_NOT_WRITABLE "old primary ${PRIMARY_POD} is not confirmed writable (@@global.read_only=${initial_read_only:-unknown}); refusing to take fence ownership" false; exit 0
fi

if ! _set_primary_read_only 1; then
  # SET may have succeeded even if verification failed; make a best-effort
  # restore before reporting the fence failure.
  FENCE_ACTIVE=true
  if _release_owned_fence; then
    emit ERROR PRIMARY_FENCE_FAILED "could not verify the write fence on ${PRIMARY_POD}; writable state was restored" false; exit 1
  fi
  emit ERROR PRIMARY_FENCE_STUCK "could not verify the write fence on ${PRIMARY_POD}, and writable state could not be restored" false; exit 1
fi
FENCE_ACTIVE=true

# read_only blocks new application writes; FTWRL then waits out writes that were
# already in flight before read_only took effect. Capture the GTID while that
# session holds the lock, then release FTWRL while leaving read_only enabled for
# the drain/handoff window. A failed client session releases its own FTWRL.
FENCED_GTID="$(mariadb_sql "$PRIMARY_POD" "$ROOT_PASSWORD" \
  'FLUSH TABLES WITH READ LOCK; SELECT @@global.gtid_binlog_pos; UNLOCK TABLES' || true)"
if [[ -z "$FENCED_GTID" || ! "$FENCED_GTID" =~ ^[0-9,-]+$ ]]; then
  if _release_owned_fence; then
    emit ERROR PRIMARY_GTID_UNAVAILABLE "could not read a valid primary GTID after fencing; writable state was restored" false; exit 1
  fi
  emit ERROR PRIMARY_FENCE_STUCK "primary GTID is unavailable and writable state could not be restored" false; exit 1
fi

drain_deadline=$(( SECONDS + REPLICATION_DRAIN_TIMEOUT ))
drain_results='[]'
for pod in "${replica_pods[@]}"; do
  remaining=$(( drain_deadline - SECONDS ))
  if (( remaining <= 0 )); then
    wait_result="timeout"
  else
    wait_result="$(mariadb_sql "$pod" "$ROOT_PASSWORD" \
      "SELECT MASTER_GTID_WAIT('${FENCED_GTID}', ${remaining})" || true)"
  fi
  drain_results="$(jq -c --arg pod "$pod" --arg result "$wait_result" \
    '. + [{pod: $pod, result: $result}]' <<<"$drain_results")"
  if [[ "$wait_result" != "0" ]]; then
    if _release_owned_fence; then
      emit ERROR REPLICA_DRAIN_FAILED "replica ${pod} did not reach the fenced primary GTID; CR was not patched and writable state was restored" false \
        "$(jq -nc --arg gtid "$FENCED_GTID" --argjson results "$drain_results" '{fenced_gtid: $gtid, drain_results: $results, fence_released: true}')"; exit 1
    fi
    emit ERROR PRIMARY_FENCE_STUCK "replica ${pod} did not drain and the old primary could not be restored writable" false \
      "$(jq -nc --arg gtid "$FENCED_GTID" --argjson results "$drain_results" '{fenced_gtid: $gtid, drain_results: $results, fence_released: false}')"; exit 1
  fi
done

# --- patch + wait ------------------------------------------------------------
_patch_index() {
  local expected="$1" next="$2" cr desired rv patch
  cr="$(_cr_json)" || return 1
  desired="$(jq -r '.spec.replication.primary.podIndex // empty' <<<"$cr")"
  [[ "$desired" == "$next" ]] && return 0
  [[ "$desired" == "$expected" ]] || return 2
  rv="$(jq -r '.metadata.resourceVersion // empty' <<<"$cr")"
  [[ -n "$rv" ]] || return 1
  patch="$(jq -nc --arg rv "$rv" --argjson expected "$expected" --argjson next "$next" '[
    {op:"test", path:"/metadata/resourceVersion", value:$rv},
    {op:"test", path:"/spec/replication/primary/podIndex", value:$expected},
    {op:"replace", path:"/spec/replication/primary/podIndex", value:$next}
  ]')"
  _kubectl patch "$RESOURCE" "$MDB" --type json -p "$patch" >/dev/null 2>&1
}

# Poll until currentPrimaryPodIndex == want and the CR is Ready, or timeout.
_wait_switch() {
  local want="$1" timeout="${2:-$WAIT_TIMEOUT}" cr
  local deadline=$(( SECONDS + timeout ))
  while (( SECONDS < deadline )); do
    cr="$(_cr_json)" || cr=""
    if [[ -n "$cr" && "$(_primary_index "$cr")" == "$want" && "$(_ready "$cr")" == "True" ]]; then
      return 0
    fi
    sleep "$POLL_INTERVAL"
  done
  return 1
}

patch_applied=true
if ! _patch_index "$FROM_INDEX" "$TARGET_INDEX"; then
  patch_applied=false
fi
if ! bool "$patch_applied"; then
  observed_desired="$(_desired_primary_index 2>/dev/null || true)"
  if [[ "$observed_desired" == "$TARGET_INDEX" ]]; then
    patch_applied=true # an equivalent concurrent caller won the atomic patch
  elif [[ -n "$observed_desired" && "$observed_desired" != "$FROM_INDEX" ]]; then
    OPERATOR_OWNS_SWITCH=true
    emit ERROR CONCURRENT_SWITCH_DETECTED "another caller changed desired primary from ${FROM_INDEX} to ${observed_desired}; operator owns the existing fence and this request will not overwrite it" false \
      "$(jq -nc --arg gtid "$FENCED_GTID" --argjson observed "$observed_desired" '{fenced_gtid: $gtid, observed_desired_pod_index: $observed, fence_released: false}')"; exit 1
  elif _release_owned_fence; then
    emit ERROR PATCH_FAILED "failed the atomic patch of spec.replication.primary.podIndex to ${TARGET_INDEX}; writable state was restored" false \
      "$(jq -nc --arg gtid "$FENCED_GTID" '{fenced_gtid: $gtid, fence_released: true}')"; exit 1
  fi
  emit ERROR PRIMARY_FENCE_STUCK "failed the atomic target patch and could not restore the old primary writable" false \
    "$(jq -nc --arg gtid "$FENCED_GTID" '{fenced_gtid: $gtid, fence_released: false}')"; exit 1
fi
OPERATOR_OWNS_SWITCH=true

if _wait_switch "$TARGET_INDEX"; then
  FENCE_ACTIVE=false
  emit CHANGED PRIMARY_SWITCHED "primary switched from podIndex ${FROM_INDEX} to ${TARGET_INDEX} after write fencing and GTID drain" true \
    "$(jq -nc --arg gtid "$FENCED_GTID" --argjson results "$drain_results" '{fenced_gtid: $gtid, drain_results: $results}')"; exit 0
fi

# --- stuck: self-heal (rollback -> verify -> [gated] evict -> verify) --------
recovery='{"attempted":[]}'
_record() { recovery="$(jq -c --arg s "$1" '.attempted += [$s]' <<<"$recovery")"; }

if bool "$ROLLBACK_ON_TIMEOUT"; then
  _record "rollback"
  _patch_index "$TARGET_INDEX" "$FROM_INDEX" || true
  if [[ "$(_desired_primary_index 2>/dev/null || true)" == "$FROM_INDEX" ]]; then
    OPERATOR_OWNS_SWITCH=false
    _record "release-fence"
    fence_released=false
    if _release_owned_fence; then fence_released=true; fi
    recovery_cr="$(_cr_json 2>/dev/null || true)"
    if bool "$fence_released" && [[ -n "$recovery_cr" ]] && [[ "$(_primary_index "$recovery_cr")" == "$FROM_INDEX" ]]; then
      emit ERROR SWITCH_TIMEOUT_ROLLED_BACK "switch to podIndex ${TARGET_INDEX} did not complete within ${WAIT_TIMEOUT}s; auto-rolled back to ${FROM_INDEX} (DB is primary-serving again)" false \
        "$(jq -c '. + {recovered: true, fence_released: true}' <<<"$recovery")"; exit 1
    fi
  else
    _record "rollback-patch-unconfirmed"
  fi

  # Rollback did not recover. The old primary may be hung (see #363); the proven
  # recovery is to evict it so the operator/k8s rebuilds it. Gated by default.
  if bool "$ALLOW_POD_EVICTION"; then
    stuck_pod="$(_kubectl get "$RESOURCE" "$MDB" -o jsonpath='{.status.currentPrimary}' 2>/dev/null || true)"
    if [[ -n "$stuck_pod" ]]; then
      _record "evict:${stuck_pod}"
      _kubectl delete pod "$stuck_pod" --ignore-not-found >/dev/null 2>&1 || true
      if _wait_switch "$FROM_INDEX" "$RECOVERY_TIMEOUT"; then
        FENCE_ACTIVE=false
        emit ERROR SWITCH_TIMEOUT_RECOVERED "switch timed out; auto-recovered by rolling back and evicting the stuck primary pod (${stuck_pod})" false \
          "$(jq -c '. + {recovered: true}' <<<"$recovery")"; exit 1
      fi
    fi
  fi
fi

emit ERROR SWITCH_STUCK "switch to podIndex ${TARGET_INDEX} did not complete within ${WAIT_TIMEOUT}s and automatic recovery did not restore a primary; manual intervention required (inspect the MariaDB CR and consider evicting the stuck primary pod — see operator issue mariadb-operator#363)" false \
  "$(jq -c '. + {recovered: false}' <<<"$recovery")"
exit 1
