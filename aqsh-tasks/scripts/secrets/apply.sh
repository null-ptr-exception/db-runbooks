#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# secrets/apply.sh
# aqsh task: execute a planned secret upsert. Recomputes the plan_hash from
# LIVE state (decrypted payload digest + the Secret's current
# resourceVersion + mode) and refuses on mismatch — any external edit,
# delete or create between plan and apply invalidates the plan
# (PLAN_STALE), exactly like reconfig/apply's CAS; so does switching mode.
# Merge-only: keys absent from the payload are left untouched; under
# mode=add_only existing values may not change at all (KEY_CONFLICT);
# under mode=skip_existing existing keys are silently skipped (INSERT
# IGNORE) and only new keys are written.
# Values travel stdin-only into kubectl (create -f - / patch --patch-file
# /dev/stdin), never argv, never logs.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE, SECRET_NAME, SECRETS_PAYLOAD, SECRETS_MODE — as secrets/plan
#   SECRETS_PLAN_HASH        — token returned by secrets/plan
#   REQUESTED_BY, REQUEST_ID — optional audit passthrough
# =============================================================================

LIB_DIR="/tasks/lib"
# shellcheck source=aqsh-tasks/lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=aqsh-tasks/lib/response.sh
source "${LIB_DIR}/response.sh"
# shellcheck source=aqsh-tasks/lib/k8s.sh
source "${LIB_DIR}/k8s.sh"
# shellcheck source=aqsh-tasks/lib/secrets.sh
source "${LIB_DIR}/secrets.sh"

log_set_level "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT:-INFO}}"

DB_NAMESPACE="${DB_NAMESPACE:?DB_NAMESPACE is required}"
SECRET_NAME="${SECRET_NAME:?SECRET_NAME is required}"
SECRETS_PAYLOAD="${SECRETS_PAYLOAD:?SECRETS_PAYLOAD is required}"
SECRETS_PLAN_HASH="${SECRETS_PLAN_HASH:?SECRETS_PLAN_HASH is required}"
MODE="${SECRETS_MODE:-upsert}"
REQUESTED_BY="${REQUESTED_BY:-}"
REQUEST_ID="${REQUEST_ID:-}"
export K8S_NAMESPACE="${DB_NAMESPACE}"

log_info "secrets-apply" "namespace=${DB_NAMESPACE} secret=${SECRET_NAME} mode=${MODE} plan_hash=${SECRETS_PLAN_HASH}"

secrets_load_payload_or_fail "$SECRET_NAME" "$SECRETS_PAYLOAD"

payload_digest=$(secrets_payload_digest "$SECRETS_CANONICAL")
resource_version=$(secrets_resource_version_of "$SECRETS_EXISTING")
live_hash=$(secrets_plan_hash "$DB_NAMESPACE" "$SECRET_NAME" "$payload_digest" "$resource_version" "$MODE")

if [[ "$live_hash" != "$SECRETS_PLAN_HASH" ]]; then
  secrets_fail "PLAN_STALE" \
    "live state, payload or mode changed since secrets/plan — re-run plan and retry with the new plan_hash" \
    "$(jq -nc --arg given "$SECRETS_PLAN_HASH" --arg live "$live_hash" \
        '{given_plan_hash: $given, live_plan_hash: $live}')"
fi

diff=$(secrets_diff "$SECRETS_EXISTING" "$SECRETS_CANONICAL")

secrets_enforce_mode "$MODE" "$diff"
diff=$(secrets_effective_diff "$MODE" "$diff")

if [[ "$(printf '%s' "$diff" | jq -r '.summary.create + .summary.update')" == "0" ]]; then
  action="unchanged"
  log_info "secrets-apply" "nothing to write (all keys already match or are skipped)"
else
  write_canonical=$(secrets_filter_canonical "$MODE" "$SECRETS_CANONICAL" "$diff")
  action=$(secrets_write "$DB_NAMESPACE" "$SECRET_NAME" "$write_canonical" "$SECRETS_EXISTS") \
    || secrets_fail "APPLY_FAILED" "kubectl write failed (see task logs)" \
         "$(jq -nc --arg name "$SECRET_NAME" '{secret_name: $name}')"
fi

secrets_write_result "$(jq -nc \
  --arg namespace "$DB_NAMESPACE" \
  --arg secret_name "$SECRET_NAME" \
  --arg mode "$MODE" \
  --arg action "$action" \
  --argjson diff "$diff" \
  --arg plan_hash "$SECRETS_PLAN_HASH" \
  --arg requested_by "$REQUESTED_BY" \
  --arg request_id "$REQUEST_ID" \
  '{namespace: $namespace, secret_name: $secret_name, mode: $mode,
    action: $action, plan_hash: $plan_hash,
    requested_by: $requested_by, request_id: $request_id} + $diff')"
