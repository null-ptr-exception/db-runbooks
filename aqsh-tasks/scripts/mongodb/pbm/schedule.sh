#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/pbm/schedule.sh
# aqsh task: manage the recurring-backup schedule for a namespace, gated
# dry_run -> confirm. PBM has NO built-in scheduler (Percona docs: "We
# recommend using crond or similar services"; the in-CR cron people
# remember is the Percona OPERATOR's feature) — this task manages the
# house equivalent: one aqsh-owned Kubernetes CronJob that periodically
# POSTs pbm/backup back into the aqsh API. Callers see only a cron
# expression + backup type; the CronJob name and aqsh URL are internal
# config, never inputs. See docs/mongodb/pbm.md#scheduling.
#
# Semantics:
#   dry-run                — current schedule + the diff confirm would apply
#   confirm + schedule=... — create or update (type/enabled folded in)
#   confirm + enabled=...  — suspend/resume an existing schedule
#   confirm + remove=true  — delete the managed CronJob
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE         — target namespace
#   PBM_SCHEDULE_CRON    — cron expression, e.g. "0 2 * * *"
#   PBM_SCHEDULE_TYPE    — backup type for scheduled runs (default logical;
#                          physical/incremental prerequisites are enforced
#                          by pbm/backup at each run)
#   PBM_SCHEDULE_ENABLED — "true"/"false" suspend toggle (empty = keep)
#   PBM_SCHEDULE_REMOVE  — "true" deletes the schedule (exclusive)
#   DRY_RUN / CONFIRM    — standard triad
#   LOG_LEVEL            — optional per-call log verbosity
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-recovery.sh"
source "${LIB_DIR}/mongodb-account.sh"
source "${LIB_DIR}/mongodb-pbm.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
log_set_level "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT:-INFO}}"

_CRON="${PBM_SCHEDULE_CRON:-}"
_TYPE="${PBM_SCHEDULE_TYPE:-}"
_ENABLED="${PBM_SCHEDULE_ENABLED:-}"
_REMOVE="${PBM_SCHEDULE_REMOVE:-false}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"

# ── Gate ─────────────────────────────────────────────────────────────────────
if bool_enabled "$DRY_RUN" && bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true with dry_run=true is not supported"
fi
if ! bool_enabled "$DRY_RUN" && ! bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true is required when dry_run=false"
fi
if bool_enabled "$_REMOVE" && [[ -n "$_CRON" || -n "$_TYPE" || -n "$_ENABLED" ]]; then
  fail_task "INVALID_INPUT" "remove=true cannot be combined with schedule/type/enabled"
fi
if [[ -n "$_ENABLED" && "$_ENABLED" != "true" && "$_ENABLED" != "false" ]]; then
  fail_task "INVALID_INPUT" "enabled must be 'true' or 'false' (got '${_ENABLED}')"
fi

# A scheduled backup is pointless (and NO_PBM_AGENT at every tick) without
# a PBM-capable deployment — resolve/validate the same way pbm/backup does.
pbm_task_init "pbm-schedule"

_CJ_NAME=$(pbm_schedule_cronjob_name)
_AQSH_URL=$(pbm_schedule_aqsh_url)

_CURRENT='{"exists": false}'
_EXISTS=false
if _CJ_JSON=$(pbm_schedule_get_json "$_CJ_NAME"); then
  _EXISTS=true
  _CURRENT=$(pbm_schedule_summary "$_CJ_JSON")
fi
log_debug "pbm-schedule" "cronjob=${_CJ_NAME} exists=${_EXISTS} current=${_CURRENT}"

# ── Compute the desired state (requested values over current values) ─────────
_ACTION="none"
_DESIRED='null'
if bool_enabled "$_REMOVE"; then
  [[ "$_EXISTS" == "true" ]] && _ACTION="remove"
else
  _D_CRON="$_CRON"
  [[ -z "$_D_CRON" ]] && _D_CRON=$(jq -r '.schedule // empty' <<< "$_CURRENT")
  _D_TYPE="$_TYPE"
  [[ -z "$_D_TYPE" ]] && _D_TYPE=$(jq -r '.backup_type // "logical"' <<< "$_CURRENT")
  [[ -z "$_D_TYPE" ]] && _D_TYPE="logical"
  if [[ -n "$_ENABLED" ]]; then
    _D_SUSPENDED=$([[ "$_ENABLED" == "false" ]] && echo true || echo false)
  else
    _D_SUSPENDED=$(jq -r 'if .exists then (.suspended // false) else false end' <<< "$_CURRENT")
  fi

  if [[ -n "$_CRON" || -n "$_TYPE" || -n "$_ENABLED" ]]; then
    if [[ -z "$_D_CRON" ]]; then
      fail_task "INVALID_INPUT" \
        "no schedule exists yet — creating one requires the schedule input (cron expression, e.g. '0 2 * * *')"
    fi
    _DESIRED=$(jq -nc --arg cron "$_D_CRON" --arg type "$_D_TYPE" --argjson suspended "$_D_SUSPENDED" \
      '{schedule: $cron, backup_type: $type, suspended: $suspended}')
    if [[ "$_EXISTS" == "true" ]] \
        && jq -e --argjson d "$_DESIRED" \
          '.schedule == $d.schedule and (.backup_type // "logical") == $d.backup_type and (.suspended // false) == $d.suspended' \
          <<< "$_CURRENT" >/dev/null 2>&1; then
      _ACTION="none"
    elif [[ "$_EXISTS" == "true" ]]; then
      _ACTION="update"
    else
      _ACTION="create"
    fi
  fi
fi
log_debug "pbm-schedule" "action=${_ACTION} desired=${_DESIRED}"

if bool_enabled "$DRY_RUN"; then
  log_info "pbm-schedule" "dry-run: action=${_ACTION} — no changes made"
  jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg sts "$PBM_STS" \
    --arg cronjob "$_CJ_NAME" \
    --arg aqsh_url "$_AQSH_URL" \
    --arg action "$_ACTION" \
    --argjson current "$_CURRENT" \
    --argjson desired "$_DESIRED" \
    '{dry_run: true, namespace: $namespace, sts: $sts,
      cronjob: $cronjob, aqsh_url: $aqsh_url,
      current: $current, desired: $desired, action: $action}
     + (if $action == "none" and $desired == null and ($current.exists | not) then
          {note: "no schedule exists — pass schedule=<cron> to create one"} else {} end)
     + (if ($desired.backup_type // "logical") != "logical" then
          {note: "physical/incremental prerequisites (PSMDB engine, agent data volume) are re-checked by pbm/backup at every scheduled run"} else {} end)' \
    > "$AQSH_RESULT_FILE"
  exit 0
fi

# ── confirm: execute ─────────────────────────────────────────────────────────
case "$_ACTION" in
  remove)
    _OUT=$(pbm_schedule_delete "$_CJ_NAME") \
      || fail_task "SCHEDULE_APPLY_FAILED" "could not delete CronJob ${_CJ_NAME}" \
        "$(jq -nc --arg raw "${_OUT:0:500}" '{raw_output:$raw, hint:"check RBAC: batch cronjobs delete"}')"
    jq -n --arg namespace "$DB_NAMESPACE" --arg cronjob "$_CJ_NAME" \
      '{namespace: $namespace, status: "done", cronjob: $cronjob, applied: true, action: "remove"}' \
      > "$AQSH_RESULT_FILE"
    ;;
  create | update)
    _OUT=$(pbm_schedule_apply "$DB_NAMESPACE" "$_CJ_NAME" \
      "$(jq -r '.schedule' <<< "$_DESIRED")" \
      "$(jq -r '.backup_type' <<< "$_DESIRED")" \
      "$(jq -r '.suspended' <<< "$_DESIRED")") \
      || fail_task "SCHEDULE_APPLY_FAILED" "could not apply CronJob ${_CJ_NAME}" \
        "$(jq -nc --arg raw "${_OUT:0:500}" '{raw_output:$raw, hint:"check RBAC: batch cronjobs create/patch"}')"
    log_info "pbm-schedule" "schedule ${_ACTION} confirmed: $(jq -c . <<< "$_DESIRED")"
    jq -n \
      --arg namespace "$DB_NAMESPACE" \
      --arg cronjob "$_CJ_NAME" \
      --arg aqsh_url "$_AQSH_URL" \
      --arg action "$_ACTION" \
      --argjson desired "$_DESIRED" \
      '{namespace: $namespace, status: "done", cronjob: $cronjob, applied: true,
        action: $action, schedule: $desired.schedule, backup_type: $desired.backup_type,
        suspended: $desired.suspended, aqsh_url: $aqsh_url,
        note: "each scheduled run submits pbm/backup wait=false — follow results with pbm/list"}' \
      > "$AQSH_RESULT_FILE"
    ;;
  none)
    # remove of a non-existent schedule, or inputs identical to the live
    # state — a reported no-op, not an error.
    jq -n --arg namespace "$DB_NAMESPACE" --arg cronjob "$_CJ_NAME" --argjson current "$_CURRENT" \
      '{namespace: $namespace, status: "done", cronjob: $cronjob, applied: false,
        reason: "already-in-desired-state", current: $current}' \
      > "$AQSH_RESULT_FILE"
    ;;
esac
