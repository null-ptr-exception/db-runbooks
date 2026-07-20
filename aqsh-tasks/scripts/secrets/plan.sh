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
#   SECRETS_MODE    — "" / "upsert" (default): insert + overwrite;
#                     "add_only": overwriting an existing value fails
#                     KEY_CONFLICT; "skip_existing": existing keys are
#                     silently skipped (INSERT IGNORE), only new keys are
#                     written. mode is plan_hash material so it cannot
#                     change between plan and apply.
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
MODE="${SECRETS_MODE:-upsert}"
export K8S_NAMESPACE="${DB_NAMESPACE}"

secrets_validate_mode "$MODE"

log_info "secrets-plan" "namespace=${DB_NAMESPACE} secret=${SECRET_NAME} mode=${MODE}"

secrets_load_payload_or_fail "$SECRET_NAME" "$SECRETS_PAYLOAD"

payload_digest=$(secrets_payload_digest "$SECRETS_CANONICAL")
resource_version=$(secrets_resource_version_of "$SECRETS_EXISTING")
plan_hash=$(secrets_plan_hash "$DB_NAMESPACE" "$SECRET_NAME" "$payload_digest" "$resource_version" "$MODE")
diff=$(secrets_diff "$SECRETS_EXISTING" "$SECRETS_CANONICAL")

secrets_enforce_mode "$MODE" "$diff"
diff=$(secrets_effective_diff "$MODE" "$diff")

secrets_write_result "$(jq -nc \
  --arg namespace "$DB_NAMESPACE" \
  --arg secret_name "$SECRET_NAME" \
  --arg mode "$MODE" \
  --argjson secret_exists "$SECRETS_EXISTS" \
  --argjson diff "$diff" \
  --arg payload_digest "sha256:${payload_digest}" \
  --arg plan_hash "$plan_hash" \
  '{namespace: $namespace, secret_name: $secret_name, mode: $mode,
    secret_exists: $secret_exists, payload_digest: $payload_digest,
    plan_hash: $plan_hash} + $diff')"
