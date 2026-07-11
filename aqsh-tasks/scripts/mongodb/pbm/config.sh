#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/pbm/config.sh
# aqsh task: PBM storage configuration gateway, gated dry_run -> confirm.
# dry-run shows the diff between what PBM currently has and what this
# deployment's internal config resolves to; confirm applies the resolved
# location (+ force-resync). This is the ONE sanctioned path for re-pointing
# storage (e.g. a MinIO endpoint migration): update the internal-config
# ConfigMap, verify with dry_run, apply with confirm — the implicit
# auto-ensure in backup/pitr/restore never overwrites an existing config
# (STORAGE_CONFIG_MISMATCH points here). Credentials are always redacted in
# results and logs. See docs/mongodb/pbm.md.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE — target namespace
#   DRY_RUN      — default "true": report diff, change nothing
#   CONFIRM      — must be "true" when DRY_RUN is "false"
#   LOG_LEVEL    — optional per-call log verbosity
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-recovery.sh"
source "${LIB_DIR}/mongodb-account.sh"
source "${LIB_DIR}/minio-client.sh"
source "${LIB_DIR}/mongodb-pbm.sh"

export K8S_NAMESPACE="${DB_NAMESPACE}"
log_set_level "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT:-INFO}}"

DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"

# ── Gate ─────────────────────────────────────────────────────────────────────
if bool_enabled "$DRY_RUN" && bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true with dry_run=true is not supported"
fi
if ! bool_enabled "$DRY_RUN" && ! bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true is required when dry_run=false"
fi

pbm_task_init "pbm-config"
pbm_resolve_backup_location "$DB_NAMESPACE"

_CONFIGURED=false
_IN_SYNC=false
_CURRENT_STORAGE=null
if _CONFIG_JSON=$(pbm_get_config_json "$PBM_POD" "$PBM_AGENT_CONTAINER") \
    && printf '%s' "$_CONFIG_JSON" | jq -e '.storage.s3.bucket // empty' >/dev/null 2>&1; then
  _CONFIGURED=true
  _CURRENT_STORAGE=$(pbm_redact_config "$_CONFIG_JSON" | jq -c '.storage.s3 | {endpointUrl, bucket, prefix, region}')
  pbm_storage_matches "$_CONFIG_JSON" && _IN_SYNC=true
fi

_ACTION="would_apply"
[[ "$_IN_SYNC" == "true" ]] && _ACTION="none"
log_debug "pbm-config" "configured=${_CONFIGURED} in_sync=${_IN_SYNC} action=${_ACTION}"

_RESOLVED=$(jq -nc \
  --arg endpoint "$PBM_ENDPOINT" --arg bucket "$PBM_BUCKET" \
  --arg prefix "$PBM_PREFIX" --arg region "$PBM_REGION" \
  --arg secret "${PBM_S3_CREDENTIALS_SECRET_DEFAULT:-minio}" \
  '{endpointUrl: $endpoint, bucket: $bucket, prefix: $prefix, region: $region,
    credentials_secret: $secret}')

if bool_enabled "$DRY_RUN"; then
  log_info "pbm-config" "dry-run: configured=${_CONFIGURED} in_sync=${_IN_SYNC} — no changes made"
  jq -n \
    --arg namespace "$DB_NAMESPACE" \
    --arg sts "$PBM_STS" \
    --arg action "$_ACTION" \
    --argjson configured "$_CONFIGURED" \
    --argjson in_sync "$_IN_SYNC" \
    --argjson current "$_CURRENT_STORAGE" \
    --argjson resolved "$_RESOLVED" \
    '{dry_run: true, namespace: $namespace, sts: $sts,
      storage: {configured: $configured, in_sync: $in_sync, current: $current, resolved: $resolved},
      action: $action}
     + (if $action == "none" then {note: "PBM already points at the resolved location"} else {note: "confirm=true applies the resolved location and force-resyncs the agents (backups already under the new prefix become visible)"} end)' \
    > "$AQSH_RESULT_FILE"
  exit 0
fi

# ── confirm: execute ─────────────────────────────────────────────────────────
if [[ "$_IN_SYNC" == "true" ]]; then
  log_info "pbm-config" "already in sync — nothing to apply"
  jq -n \
    --arg namespace "$DB_NAMESPACE" --arg sts "$PBM_STS" --argjson resolved "$_RESOLVED" \
    '{namespace: $namespace, sts: $sts, status: "done", applied: false,
      reason: "already-in-sync", storage: $resolved}' \
    > "$AQSH_RESULT_FILE"
  exit 0
fi

_OUT=$(pbm_apply_storage_config "$DB_NAMESPACE" "$PBM_POD" "$PBM_AGENT_CONTAINER") \
  || fail_task "STORAGE_CONFIG_FAILED" "could not apply PBM storage config" \
    "$(jq -nc --arg raw "${_OUT:0:1000}" '{raw_output:$raw}')"

log_info "pbm-config" "storage config applied: endpoint=${PBM_ENDPOINT} bucket=${PBM_BUCKET} prefix=${PBM_PREFIX}"

jq -n \
  --arg namespace "$DB_NAMESPACE" \
  --arg sts "$PBM_STS" \
  --argjson previous "$_CURRENT_STORAGE" \
  --argjson resolved "$_RESOLVED" \
  '{namespace: $namespace, sts: $sts, status: "done", applied: true,
    previous: $previous, storage: $resolved, resync: "triggered",
    note: "agents re-scan the storage; pbm/list shows the inventory under the new location once resync finishes"}' \
  > "$AQSH_RESULT_FILE"
