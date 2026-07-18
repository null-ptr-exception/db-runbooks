#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# secrets/plan.sh
# aqsh task: read-only upsert preview for a PGP-encrypted secret payload.
# Decrypts in-pod, diffs against the live Secret (per-key
# create/update/unchanged via base64 comparison — values never appear in the
# result), and returns the plan_hash that secrets/apply requires. Executes
# nothing.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE    — target namespace
#   SECRET_NAME     — Secret to create/merge into
#   SECRETS_PAYLOAD — PGP ciphertext (armored or base64(armored)) of
#                     {"keys": {"KEY": "value", ...}}, encrypted against the
#                     key secrets/pubkey returns
#
# The deployment PGP key path and the protected-secret list are NOT task
# inputs (see CLAUDE.md "Configuration Layers") — internal config +
# live-cluster auto-detect only.
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
export K8S_NAMESPACE="${DB_NAMESPACE}"

log_info "secrets-plan" "namespace=${DB_NAMESPACE} secret=${SECRET_NAME}"

if secrets_is_protected "$SECRET_NAME"; then
  secrets_fail "PROTECTED_SECRET" \
    "refusing to plan writes to a protected secret (root credentials); no per-call override exists" \
    "$(jq -nc --arg name "$SECRET_NAME" '{secret_name: $name}')"
fi

plaintext=$(secrets_decrypt_payload "$SECRETS_PAYLOAD") && rc=0 || rc=$?
if (( rc == 1 )); then
  secrets_fail "PGP_KEY_UNAVAILABLE" "deployment PGP private key is missing or unreadable"
elif (( rc != 0 )); then
  secrets_fail "DECRYPT_FAILED" \
    "payload does not decrypt with the deployment key (wrong recipient key, corrupt message, or not PGP at all) — fetch the current key via secrets/pubkey"
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
plan_hash=$(secrets_plan_hash "$DB_NAMESPACE" "$SECRET_NAME" "$payload_digest" "$resource_version")
diff=$(secrets_diff "$existing" "$canonical")

secrets_write_result "$(jq -nc \
  --arg namespace "$DB_NAMESPACE" \
  --arg secret_name "$SECRET_NAME" \
  --argjson secret_exists "$([[ -n "$existing" ]] && echo true || echo false)" \
  --argjson diff "$diff" \
  --arg payload_digest "sha256:${payload_digest}" \
  --arg plan_hash "$plan_hash" \
  '{namespace: $namespace, secret_name: $secret_name, secret_exists: $secret_exists,
    payload_digest: $payload_digest, plan_hash: $plan_hash} + $diff')"
