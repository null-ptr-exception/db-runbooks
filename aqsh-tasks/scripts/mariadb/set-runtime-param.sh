#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/set-runtime-param.sh
# Emergency / break-glass ONLINE parameter override: apply a MariaDB global
# variable at runtime with `SET GLOBAL`, e.g. bump max_connections during a
# connection-exhaustion incident. AWS RDS analogue: ModifyDBParameterGroup for
# a *dynamic* (ApplyType) parameter.
#
# Deliberately EPHEMERAL — it does NOT write my.cnf / spec.myCnf. A restart or
# failover reverts the change, by design: durable config is owned by the
# declarative source (a config PR / GitOps), and this task is only the runtime
# escape hatch. That also sidesteps the imperative-vs-declarative drift problem
# (a live CR patch would fight helm/ArgoCD) — this never touches the CR.
#
# Static (restart-only) params are refused and redirected to the config-PR path.
# Whether a param is dynamic is asked of the live server, not hardcoded.
# =============================================================================

MDB_INPUT="${MARIADB_NAME:-}"

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

bool() { case "${1:-}" in 1 | true | TRUE | yes | YES | on | ON) return 0 ;; *) return 1 ;; esac; }

# --- curated allow-list (single source of truth for what this task will set) --
# Tier drives the confirm/warning strength; validation is per-param.
srp_tier() {
  case "$1" in
    max_connections | max_statement_time | slow_query_log | long_query_time | wait_timeout | interactive_timeout) echo safe ;;
    innodb_buffer_pool_size | tmp_table_size | max_heap_table_size | sort_buffer_size | join_buffer_size) echo memory ;;
    innodb_flush_log_at_trx_commit | sync_binlog) echo durability ;;
    read_only | super_read_only) echo protect ;;
    *) echo "" ;;
  esac
}
srp_params() {
  printf '%s\n' \
    max_connections max_statement_time slow_query_log long_query_time wait_timeout interactive_timeout \
    innodb_buffer_pool_size tmp_table_size max_heap_table_size sort_buffer_size join_buffer_size \
    innodb_flush_log_at_trx_commit sync_binlog read_only super_read_only
}
# echoes an error message and returns 1 when the value is invalid for the param
srp_validate() {
  local p="$1" v="$2"
  case "$p" in
    max_connections | wait_timeout | interactive_timeout | max_heap_table_size | tmp_table_size | sort_buffer_size | join_buffer_size | sync_binlog | innodb_buffer_pool_size)
      [[ "$v" =~ ^[0-9]+$ ]] || { echo "must be a non-negative integer (bytes for size params; no K/M/G suffix online)"; return 1; } ;;
    max_statement_time | long_query_time)
      [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "must be a non-negative number"; return 1; } ;;
    slow_query_log | read_only | super_read_only)
      case "${v^^}" in ON | OFF | 0 | 1) : ;; *) echo "must be ON/OFF/0/1"; return 1 ;; esac ;;
    innodb_flush_log_at_trx_commit)
      case "$v" in 0 | 1 | 2) : ;; *) echo "must be 0, 1, or 2"; return 1 ;; esac ;;
    *) echo "not in the allow-list"; return 1 ;;
  esac
}
# params whose value is a plain number and can therefore take a RELATIVE value
# (*1.5 / +100 / -25%). Enums / ON-OFF (slow_query_log, read_only, sync_binlog,
# innodb_flush_log_at_trx_commit) can't.
srp_is_numeric() {
  case "$1" in
    max_connections | wait_timeout | interactive_timeout | max_heap_table_size | tmp_table_size | sort_buffer_size | join_buffer_size | innodb_buffer_pool_size | max_statement_time | long_query_time) return 0 ;;
    *) return 1 ;;
  esac
}
# printf format for a computed value: integers round to whole, time params keep ms
srp_fmt() { case "$1" in max_statement_time | long_query_time) echo '%.3f' ;; *) echo '%.0f' ;; esac; }

# --- inputs ------------------------------------------------------------------
CONTEXT="${K8S_CONTEXT:-}"
NAMESPACE="${DB_NAMESPACE:-${K8S_NAMESPACE:-}}"
RESOURCE="${MARIADB_RESOURCE:-mariadb}"
MDB="$MDB_INPUT"
CONTAINER="${MARIADB_CONTAINER:-mariadb}"
PARAM="${RUNTIME_PARAM:-}"          # empty => discovery/list mode
VALUE="${RUNTIME_VALUE:-}"
VALUE_EXPR=""                       # set to the original relative form (*1.5, +25%, …)
SCOPE="${RUNTIME_SCOPE:-all}"       # all | primary | <pod-name>
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"
RESULT_FILE="${AQSH_RESULT_FILE:-}"

EPHEMERAL_NOTE="TEMPORARY runtime override — reverts on restart/failover. For a durable change, update the deployment config (PR)."

json_num_or_null() { [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "$1" || printf 'null'; }

emit() {
  local status="$1" reason="$2" summary="$3" changed="$4" extra="${5:-}" out
  [[ -n "$extra" ]] || extra='{}'
  out=$(jq -nc \
    --arg status "$status" --arg reason "$reason" --arg summary "$summary" \
    --arg namespace "$NAMESPACE" --arg mdb "${MDB:-}" \
    --arg param "$PARAM" --arg value "$VALUE" --arg value_expr "$VALUE_EXPR" --arg scope "$SCOPE" \
    --arg tier "$(srp_tier "$PARAM")" --arg note "$EPHEMERAL_NOTE" \
    --argjson dry_run "$(bool "$DRY_RUN" && echo true || echo false)" \
    --argjson confirm "$(bool "$CONFIRM" && echo true || echo false)" \
    --argjson changed "$changed" --argjson extra "$extra" \
    '{
      status: $status, reason_code: $reason, summary: $summary,
      namespace: $namespace, mdb: $mdb,
      param: (if $param == "" then null else $param end), value: (if $value == "" then null else $value end),
      value_expr: (if $value_expr == "" then null else $value_expr end),
      scope: $scope, tier: (if $tier == "" then null else $tier end),
      ephemeral: true, ephemeral_note: $note,
      dry_run: $dry_run, confirm: $confirm, changed: $changed
    } + $extra')
  [[ -n "$RESULT_FILE" ]] && printf '%s\n' "$out" > "$RESULT_FILE"
  printf '%s\n' "$out"
}

# Fail closed: an unrecognized dry_run/confirm must NOT silently become "false"
# and apply changes (e.g. a `dry_run=treu` typo would otherwise skip the dry run).
_valid_bool() { case "${1,,}" in 1 | true | yes | on | 0 | false | no | off) return 0 ;; *) return 1 ;; esac; }
_valid_bool "$DRY_RUN" || { emit BLOCKED INVALID_BOOL "dry_run must be a boolean (true/false); got '${DRY_RUN}'" false; exit 0; }
_valid_bool "$CONFIRM" || { emit BLOCKED INVALID_BOOL "confirm must be a boolean (true/false); got '${CONFIRM}'" false; exit 0; }

# --- resolve target ----------------------------------------------------------
mariadb_set_target "$CONTEXT" "$NAMESPACE" "$RESOURCE" "$MDB_INPUT" "$CONTAINER"
_on_ambiguous() { emit BLOCKED MARIADB_AMBIGUOUS "several MariaDB CRs in '${NAMESPACE}'; set mdb to choose one" false; exit 0; }
_on_none() { emit BLOCKED MARIADB_NOT_FOUND "no MariaDB CR found in '${NAMESPACE}'" false; exit 0; }
if [[ -z "$MDB" ]]; then
  mariadb_autodetect_target false _on_ambiguous _on_none
  MDB="$MARIADB_NAME"
fi

mapfile -t ALL_PODS < <(mariadb_list_pods)
[[ ${#ALL_PODS[@]} -gt 0 ]] || { emit BLOCKED NO_PODS "no MariaDB pods found in '${NAMESPACE}'" false; exit 0; }
# CURRENT_PRIMARY is the REAL primary (may be empty on a standalone or mid-reconcile
# cluster); QUERY_POD is just "any ready pod" for read-only queries (root password,
# information_schema, current values). scope=primary must NOT silently fall back to
# QUERY_POD — see the scope resolution below.
CURRENT_PRIMARY="$(mariadb_jsonpath "$RESOURCE" "$MDB" '{.status.currentPrimary}' 2>/dev/null || true)"
QUERY_POD="${CURRENT_PRIMARY:-${ALL_PODS[0]}}"
ROOT_PW="$(mariadb_read_root_password "$QUERY_POD" "${ALL_PODS[@]}")" \
  || { emit BLOCKED ROOT_PASSWORD_UNAVAILABLE "cannot read MARIADB_ROOT_PASSWORD from any ready pod" false; exit 0; }

# --- discovery / list mode (empty param) -------------------------------------
if [[ -z "$PARAM" ]]; then
  rows='[]'
  while IFS= read -r p; do
    cur="$(mariadb_sql "$QUERY_POD" "$ROOT_PW" "SELECT @@GLOBAL.${p}" 2>/dev/null || echo "?")"
    rows="$(jq -c --arg p "$p" --arg t "$(srp_tier "$p")" --arg c "$cur" '. + [{param:$p, tier:$t, current:$c}]' <<<"$rows")"
  done < <(srp_params)
  emit READY SRP_LIST "supported runtime params (current values read from ${QUERY_POD})" false \
    "$(jq -c '{params: .}' <<<"$rows")"
  exit 0
fi

# --- validate param + value --------------------------------------------------
TIER="$(srp_tier "$PARAM")"
if [[ -z "$TIER" ]]; then
  emit BLOCKED PARAM_NOT_ALLOWED "'${PARAM}' is not in the allow-list; run with no param to list supported params" false \
    "$(jq -nc --argjson a "$(srp_params | jq -R . | jq -sc .)" '{allowed: $a}')"; exit 0
fi
if [[ -z "$VALUE" ]]; then
  emit BLOCKED VALUE_REQUIRED "value is required for '${PARAM}'" false; exit 0
fi

# Relative value (*1.5 / +100 / -25%): compute the absolute target from the live
# value, then fall through to normal validation/apply. Numeric params only.
if [[ "$VALUE" == [*+-]* || "$VALUE" == *% ]]; then
  if ! srp_is_numeric "$PARAM"; then
    emit BLOCKED RELATIVE_UNSUPPORTED "relative value '${VALUE}' is only valid for numeric params, not '${PARAM}'" false; exit 0
  fi
  _op=""; _operand=""
  if [[ "$VALUE" =~ ^\*([0-9]+(\.[0-9]+)?)$ ]]; then _op=mul; _operand="${BASH_REMATCH[1]}"
  elif [[ "$VALUE" =~ ^([+-])([0-9]+)%$ ]]; then _op=pct; _operand="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  elif [[ "$VALUE" =~ ^([+-])([0-9]+(\.[0-9]+)?)$ ]]; then _op=add; _operand="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  else
    emit BLOCKED VALUE_INVALID "relative value '${VALUE}' malformed (use *1.5, +100, -50, +25%, -25%)" false; exit 0
  fi
  _cur="$(mariadb_sql "$QUERY_POD" "$ROOT_PW" "SELECT @@GLOBAL.${PARAM}" 2>/dev/null || true)"
  if ! [[ "$_cur" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    emit BLOCKED CURRENT_UNREADABLE "cannot read current value of '${PARAM}' to resolve relative '${VALUE}'" false; exit 0
  fi
  _fmt="$(srp_fmt "$PARAM")"
  case "$_op" in
    mul) VALUE="$(awk -v c="$_cur" -v o="$_operand" -v f="$_fmt" 'BEGIN{printf f, c*o}')" ;;
    add) VALUE="$(awk -v c="$_cur" -v o="$_operand" -v f="$_fmt" 'BEGIN{printf f, c+o}')" ;;
    pct) VALUE="$(awk -v c="$_cur" -v o="$_operand" -v f="$_fmt" 'BEGIN{printf f, c*(1+o/100)}')" ;;
  esac
  VALUE_EXPR="$(printf '%s (from %s of %s)' "$VALUE" "$RUNTIME_VALUE" "$_cur")"
fi

if ! verr="$(srp_validate "$PARAM" "$VALUE")"; then
  emit BLOCKED VALUE_INVALID "value '${VALUE}' invalid for '${PARAM}': ${verr}" false; exit 0
fi

# --- static (restart-only) params are refused --------------------------------
RO="$(mariadb_sql "$QUERY_POD" "$ROOT_PW" \
  "SELECT READ_ONLY FROM information_schema.SYSTEM_VARIABLES WHERE VARIABLE_NAME='${PARAM^^}'" 2>/dev/null || true)"
if [[ -z "$RO" ]]; then
  emit BLOCKED PARAM_UNKNOWN "server does not expose '${PARAM}' (SYSTEM_VARIABLES empty)" false; exit 0
fi
if [[ "$RO" == "YES" ]]; then
  emit BLOCKED PARAM_STATIC "'${PARAM}' is static (restart-only); change it via a config PR + rolling restart, not this task" false; exit 0
fi

# --- resolve scope -> target pods --------------------------------------------
case "$SCOPE" in
  all) TARGET_PODS=("${ALL_PODS[@]}") ;;
  primary)
    if [[ -n "$CURRENT_PRIMARY" ]]; then
      TARGET_PODS=("$CURRENT_PRIMARY")
    elif [[ ${#ALL_PODS[@]} -eq 1 ]]; then
      TARGET_PODS=("${ALL_PODS[0]}")   # standalone: the sole pod is the primary
    else
      emit BLOCKED PRIMARY_UNKNOWN "cannot resolve the primary (status.currentPrimary empty) with multiple pods; use scope=all or scope=<pod>" false; exit 0
    fi ;;
  *)
    if printf '%s\n' "${ALL_PODS[@]}" | grep -qxF "$SCOPE"; then TARGET_PODS=("$SCOPE"); else
      emit BLOCKED SCOPE_INVALID "scope '${SCOPE}' is not a pod of this instance (use all|primary|<pod>)" false; exit 0
    fi ;;
esac

# --- dry-run: show current -> target per pod ---------------------------------
_current_json() {
  local out='[]' pod cur
  for pod in "${TARGET_PODS[@]}"; do
    cur="$(mariadb_sql "$pod" "$ROOT_PW" "SELECT @@GLOBAL.${PARAM}" 2>/dev/null || echo "?")"
    out="$(jq -c --arg pod "$pod" --arg cur "$cur" '. + [{pod:$pod, current:$cur}]' <<<"$out")"
  done
  printf '%s' "$out"
}

if bool "$DRY_RUN"; then
  warn=""
  [[ "$TIER" == "memory" ]] && warn=" WARNING: raising a memory param can OOM a memory-limited pod."
  [[ "$TIER" == "durability" ]] && warn=" WARNING: relaxes durability — data-loss window on crash."
  [[ "$TIER" == "protect" ]] && warn=" WARNING: changes read/write mode — can block writes on the targeted pods."
  emit READY SRP_DRY_RUN "dry run: would SET GLOBAL ${PARAM}=${VALUE}${VALUE_EXPR:+ [${RUNTIME_VALUE}]} on ${#TARGET_PODS[@]} pod(s) [tier=${TIER}].${warn} ${EPHEMERAL_NOTE}" false \
    "$(jq -c '{targets: .}' <<<"$(_current_json)")"
  exit 0
fi
bool "$CONFIRM" || { emit BLOCKED CONFIRM_REQUIRED "set confirm=true with dry_run=false to apply (tier=${TIER})" false; exit 0; }

# --- apply SET GLOBAL on each target pod --------------------------------------
# PARAM is allow-listed and VALUE is validated, so the identifier/literal are safe.
# Read-back is AUTHORITATIVE: the pod only counts as applied if the live global
# actually reports the intended value. @@GLOBAL returns 0/1 for ON/OFF, and size
# params get rounded to a chunk multiple, so normalise the expected value and
# tolerate rounding only for size (memory-tier) params.
_want="$(case "${VALUE^^}" in ON | YES) echo 1 ;; OFF | NO) echo 0 ;; *) echo "$VALUE" ;; esac)"
results='[]'
failed=0
applied_any=0
for pod in "${TARGET_PODS[@]}"; do
  if ! mariadb_sql "$pod" "$ROOT_PW" "SET GLOBAL ${PARAM} = ${VALUE}" >/dev/null 2>&1; then
    failed=1
    results="$(jq -c --arg pod "$pod" '. + [{pod:$pod, applied:false, error:"SET GLOBAL failed"}]' <<<"$results")"
    continue
  fi
  now="$(mariadb_sql "$pod" "$ROOT_PW" "SELECT @@GLOBAL.${PARAM}" 2>/dev/null || true)"
  if [[ -z "$now" ]]; then
    failed=1
    results="$(jq -c --arg pod "$pod" '. + [{pod:$pod, applied:false, error:"read-back failed"}]' <<<"$results")"
  elif [[ "$now" == "$_want" ]]; then
    applied_any=1
    results="$(jq -c --arg pod "$pod" --arg now "$now" '. + [{pod:$pod, applied:true, value:$now}]' <<<"$results")"
  elif [[ "$TIER" == "memory" ]]; then
    applied_any=1   # size params round to a chunk multiple — accept, but flag it
    results="$(jq -c --arg pod "$pod" --arg now "$now" --arg want "$_want" '. + [{pod:$pod, applied:true, value:$now, requested:$want, adjusted:true}]' <<<"$results")"
  else
    failed=1
    results="$(jq -c --arg pod "$pod" --arg now "$now" --arg want "$_want" '. + [{pod:$pod, applied:false, value:$now, expected:$want, error:"read-back mismatch"}]' <<<"$results")"
  fi
done

if [[ "$failed" -eq 1 ]]; then
  # honest `changed`: if some pods were already mutated, live state DID change
  changed_json="$([[ "$applied_any" -eq 1 ]] && echo true || echo false)"
  emit ERROR SRP_APPLY_FAILED "SET GLOBAL ${PARAM}=${VALUE} did not verify on one or more pods$([[ "$applied_any" -eq 1 ]] && echo ' (PARTIAL — some pods were changed)')" "$changed_json" \
    "$(jq -c '{results: ., partial: ('"$changed_json"')}' <<<"$results")"; exit 1
fi
emit CHANGED SRP_APPLIED "SET GLOBAL ${PARAM}=${VALUE}${VALUE_EXPR:+ [${RUNTIME_VALUE}]} applied + verified on ${#TARGET_PODS[@]} pod(s) [tier=${TIER}]. ${EPHEMERAL_NOTE}" true \
  "$(jq -c '{results: .}' <<<"$results")"
