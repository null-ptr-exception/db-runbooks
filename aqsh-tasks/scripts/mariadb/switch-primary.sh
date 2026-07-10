#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/switch-primary.sh
# Promote a chosen replica to primary within one replicated MariaDB instance,
# by patching spec.replication.primary.podIndex. The mariadb-operator performs a
# graceful switchover (read-lock old primary, wait for replicas in sync, promote
# target, reconnect). AWS-RDS analogue: FailoverDBCluster (with a target).
#
# Safety split: the OPERATOR guarantees data safety (it blocks on lagged replicas
# and won't lose data). This task's job is to (a) avoid a self-inflicted write
# outage by only switching to a fully caught-up replica, and (b) self-heal a
# stuck switchover instead of leaving the primary read_only.
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
LAG_THRESHOLD="${LAG_THRESHOLD:-0}"        # max secondsBehindMaster to allow switching
ROLLBACK_ON_TIMEOUT="${ROLLBACK_ON_TIMEOUT:-true}"
# Gated until an e2e proves the eviction recovery is reliable (see #59): a bad
# auto pod-deletion could turn a hiccup into an outage.
ALLOW_POD_EVICTION="${ALLOW_POD_EVICTION:-false}"
RESULT_FILE="${AQSH_RESULT_FILE:-}"

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
# code path. A pod we cannot read is recorded as UNHEALTHY (never omitted) so
# Guard 4's all_ok stays exactly as strict as the CR-status path — we never
# blind-switch to a replica whose lag we couldn't confirm.
_replica_entry_via_sql() {
  local pod="$1" pw="$2" out io sql lag
  out="$(mariadb_sql_vertical "$pod" "$pw" "SHOW SLAVE STATUS")" || out=""
  if [[ -z "$out" ]]; then
    printf '{"slaveIORunning":false,"slaveSQLRunning":false,"secondsBehindMaster":null}'
    return 0
  fi
  io="$(sed -n 's/^[[:space:]]*Slave_IO_Running:[[:space:]]*//p' <<<"$out" | head -1)"
  sql="$(sed -n 's/^[[:space:]]*Slave_SQL_Running:[[:space:]]*//p' <<<"$out" | head -1)"
  lag="$(sed -n 's/^[[:space:]]*Seconds_Behind_Master:[[:space:]]*//p' <<<"$out" | head -1)"
  jq -nc --arg io "$io" --arg sql "$sql" --arg lag "$lag" '{
    slaveIORunning: ($io == "Yes"),
    slaveSQLRunning: ($sql == "Yes"),
    secondsBehindMaster: (if ($lag | test("^[0-9]+$")) then ($lag | tonumber) else null end)
  }'
}

# Build the status.replication.replicas-equivalent map (keyed by pod name) from
# live SHOW SLAVE STATUS across every non-primary replica. Returns 1 (empty) only
# when the root password cannot be resolved at all — the caller then falls
# through to the existing guards, which block rather than guess.
_build_replicas_via_sql() {
  local pw i pod entry map='{}' candidates=()
  local unhealthy='{"slaveIORunning":false,"slaveSQLRunning":false,"secondsBehindMaster":null}'
  for ((i = 0; i < CR_REPLICAS; i++)); do
    [[ "$i" == "$FROM_INDEX" ]] && continue
    candidates+=("${MDB}-${i}")
  done
  pw="$(mariadb_read_root_password "${MDB}-${FROM_INDEX}" "${candidates[@]}")" || return 1
  for pod in "${candidates[@]}"; do
    entry="$(_replica_entry_via_sql "$pod" "$pw")" || entry="$unhealthy"
    map="$(jq -c --arg k "$pod" --argjson v "$entry" '.[$k] = $v' <<<"$map")"
  done
  printf '%s' "$map"
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

# Resolve the replica-health map ONCE; auto-select and Guard 4 both read it, so
# neither cares which operator generation produced it. Current gen: the CR's
# status.replication.replicas. Legacy (mmontes) gen: that key is absent, so fall
# back to live SHOW SLAVE STATUS. Fallback fails soft — an empty map just lets
# the guards below block, never a blind switch.
REPLICAS_JSON="$(jq -c '.status.replication.replicas // {}' <<<"$CR_JSON")"
REPLICAS_SOURCE="cr_status"
if [[ "$REPLICAS_JSON" == "{}" ]]; then
  _sql_map="$(_build_replicas_via_sql)" || _sql_map=""
  if [[ -n "$_sql_map" && "$_sql_map" != "{}" ]]; then
    REPLICAS_JSON="$_sql_map"
    REPLICAS_SOURCE="show_slave_status"
  fi
fi

# Target selection: an explicit podIndex, or — when the caller gives none — the
# best replica we pick ourselves (AWS RDS FailoverDBCluster likewise makes the
# target optional). Auto-pick = the healthy replica with the least lag within
# LAG_THRESHOLD (tie-break: lowest podIndex); it passes Guard 4 by construction.
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
    emit BLOCKED NO_ELIGIBLE_REPLICA "no healthy, caught-up replica available to promote (lag_threshold=${LAG_THRESHOLD}s); nothing safe to switch to" false; exit 0
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

# Guard 4: strict lag pre-check. The replica-health map (REPLICAS_JSON, from CR
# status or the legacy SHOW SLAVE STATUS fallback) is keyed by pod name
# (<mdb>-<index>). Verify the TARGET pod is actually a known replica (a bare
# all(...) would pass vacuously if the target key were missing) AND that every
# replica is healthy and caught up — so the operator's sync-wait is instant and
# the current primary never parks in a stuck read_only state.
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
  emit BLOCKED REPLICAS_NOT_IN_SYNC "replicas (incl. the target) are not all healthy and caught up (lag_threshold=${LAG_THRESHOLD}s); refusing to switch to avoid a stuck read_only window" false \
    "$(jq -c '{replicas: .replicas}' <<<"$REPL_CHECK")"; exit 0
fi

# --- dry-run / confirm -------------------------------------------------------
_pick_note="$(bool "$AUTO_SELECTED" && echo " (auto-selected)" || echo "")"
if bool "$DRY_RUN"; then
  emit READY SWITCH_DRY_RUN "dry run: would switch primary from podIndex ${FROM_INDEX} to ${TARGET_INDEX}${_pick_note} (operator performs a graceful switchover)" false; exit 0
fi
bool "$CONFIRM" || { emit BLOCKED SWITCH_CONFIRM_REQUIRED "set confirm=true with dry_run=false to switch the primary" false; exit 0; }

# --- patch + wait ------------------------------------------------------------
_patch_index() {
  _kubectl patch "$RESOURCE" "$MDB" --type merge \
    -p "{\"spec\":{\"replication\":{\"primary\":{\"podIndex\":$1}}}}" >/dev/null 2>&1
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

if ! _patch_index "$TARGET_INDEX"; then
  emit ERROR PATCH_FAILED "failed to patch spec.replication.primary.podIndex to ${TARGET_INDEX}" false; exit 1
fi

if _wait_switch "$TARGET_INDEX"; then
  emit CHANGED PRIMARY_SWITCHED "primary switched from podIndex ${FROM_INDEX} to ${TARGET_INDEX}" true; exit 0
fi

# --- stuck: self-heal (rollback -> verify -> [gated] evict -> verify) --------
recovery='{"attempted":[]}'
_record() { recovery="$(jq -c --arg s "$1" '.attempted += [$s]' <<<"$recovery")"; }

if bool "$ROLLBACK_ON_TIMEOUT"; then
  _record "rollback"
  _patch_index "$FROM_INDEX" || true
  if _wait_switch "$FROM_INDEX" "$RECOVERY_TIMEOUT"; then
    emit ERROR SWITCH_TIMEOUT_ROLLED_BACK "switch to podIndex ${TARGET_INDEX} did not complete within ${WAIT_TIMEOUT}s; auto-rolled back to ${FROM_INDEX} (DB is primary-serving again)" false \
      "$(jq -c '. + {recovered: true}' <<<"$recovery")"; exit 1
  fi

  # Rollback did not recover. The old primary may be hung (see #363); the proven
  # recovery is to evict it so the operator/k8s rebuilds it. Gated by default.
  if bool "$ALLOW_POD_EVICTION"; then
    stuck_pod="$(_kubectl get "$RESOURCE" "$MDB" -o jsonpath='{.status.currentPrimary}' 2>/dev/null || true)"
    if [[ -n "$stuck_pod" ]]; then
      _record "evict:${stuck_pod}"
      _kubectl delete pod "$stuck_pod" --ignore-not-found >/dev/null 2>&1 || true
      if _wait_switch "$FROM_INDEX" "$RECOVERY_TIMEOUT"; then
        emit ERROR SWITCH_TIMEOUT_RECOVERED "switch timed out; auto-recovered by rolling back and evicting the stuck primary pod (${stuck_pod})" false \
          "$(jq -c '. + {recovered: true}' <<<"$recovery")"; exit 1
      fi
    fi
  fi
fi

emit ERROR SWITCH_STUCK "switch to podIndex ${TARGET_INDEX} did not complete within ${WAIT_TIMEOUT}s and automatic recovery did not restore a primary; manual intervention required (inspect the MariaDB CR and consider evicting the stuck primary pod — see operator issue mariadb-operator#363)" false \
  "$(jq -c '. + {recovered: false}' <<<"$recovery")"
exit 1
