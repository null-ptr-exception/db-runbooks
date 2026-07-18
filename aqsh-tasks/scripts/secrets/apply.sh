#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# secrets/apply.sh
# aqsh task: execute a planned secret upsert. Recomputes the plan_hash from
# LIVE state (decrypted payload digest + the Secret's current
# resourceVersion) and refuses on mismatch — any external edit, delete or
# create between plan and apply invalidates the plan (PLAN_STALE), exactly
# like reconfig/apply's CAS. Merge-only: keys absent from the payload are
# left untouched. Values travel stdin-only into kubectl (create -f - /
# patch --patch-file /dev/stdin), never argv, never logs.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE, SECRET_NAME, SECRETS_PAYLOAD — same as secrets/plan
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
REQUESTED_BY="${REQUESTED_BY:-}"
REQUEST_ID="${REQUEST_ID:-}"
export K8S_NAMESPACE="${DB_NAMESPACE}"

log_info "secrets-apply" "namespace=${DB_NAMESPACE} secret=${SECRET_NAME} plan_hash=${SECRETS_PLAN_HASH}"

if secrets_is_protected "$SECRET_NAME"; then
  secrets_fail "PROTECTED_SECRET" \
    "refusing to write a protected secret (root credentials); no per-call override exists" \
    "$(jq -nc --arg name "$SECRET_NAME" '{secret_name: $name}')"
fi

plaintext=$(secrets_decrypt_payload "$SECRETS_PAYLOAD") && rc=0 || rc=$?
if (( rc == 1 )); then
  secrets_fail "PGP_KEY_UNAVAILABLE" "deployment PGP private key is missing or unreadable"
elif (( rc != 0 )); then
  secrets_fail "DECRYPT_FAILED" \
    "payload does not decrypt with the deployment key — fetch the current key via secrets/pubkey"
fi

canonical=$(secrets_validate_payload "$plaintext") && rc=0 || rc=$?
unset plaintext
if (( rc == 2 )); then
  secrets_fail "INVALID_INPUT" "payload contains a data key name outside [-._a-zA-Z0-9]"
elif (( rc != 0 )); then
  secrets_fail "PAYLOAD_INVALID" \
    'decrypted payload is not {"keys": {name: string-value, ...}} with at least one entry'
fi

existing=$(secrets_get_existing "$SECRET_NAME") \
  || secrets_fail "OPERATION_FAILED" "cannot read live secret state (API error or RBAC denial)"

payload_digest=$(secrets_payload_digest "$canonical")
resource_version=$(secrets_resource_version_of "$existing")
live_hash=$(secrets_plan_hash "$DB_NAMESPACE" "$SECRET_NAME" "$payload_digest" "$resource_version")

if [[ "$live_hash" != "$SECRETS_PLAN_HASH" ]]; then
  secrets_fail "PLAN_STALE" \
    "live state or payload changed since secrets/plan — re-run plan and retry with the new plan_hash" \
    "$(jq -nc --arg given "$SECRETS_PLAN_HASH" --arg live "$live_hash" \
        '{given_plan_hash: $given, live_plan_hash: $live}')"
fi

diff=$(secrets_diff "$existing" "$canonical")

if [[ "$(printf '%s' "$diff" | jq -r '.summary.create + .summary.update')" == "0" ]]; then
  action="unchanged"
  log_info "secrets-apply" "all keys already match — nothing to write"
else
  action=$(secrets_write "$DB_NAMESPACE" "$SECRET_NAME" "$canonical" \
    "$([[ -n "$existing" ]] && echo true || echo false)") \
    || secrets_fail "APPLY_FAILED" "kubectl write failed (see task logs)" \
         "$(jq -nc --arg name "$SECRET_NAME" '{secret_name: $name}')"
fi

secrets_write_result "$(jq -nc \
  --arg namespace "$DB_NAMESPACE" \
  --arg secret_name "$SECRET_NAME" \
  --arg action "$action" \
  --argjson diff "$diff" \
  --arg plan_hash "$SECRETS_PLAN_HASH" \
  --arg requested_by "$REQUESTED_BY" \
  --arg request_id "$REQUEST_ID" \
  '{namespace: $namespace, secret_name: $secret_name, action: $action,
    plan_hash: $plan_hash, requested_by: $requested_by, request_id: $request_id} + $diff')"
