#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# secrets/get.sh
# aqsh task: read-side of the secrets family. Reports the live Secret's
# metadata, key names and per-key sha256 fingerprints of the DECODED values —
# enough to verify drift ("is the deployed password still mine?") without a
# value ever entering a task result or gateway log.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE — target namespace
#   SECRET_NAME  — Secret to describe
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
export K8S_NAMESPACE="${DB_NAMESPACE}"

log_info "secrets-get" "namespace=${DB_NAMESPACE} secret=${SECRET_NAME}"

# Protected secrets are refused even read-only: their value fingerprints
# would enable offline dictionary checks against a weak root password.
if secrets_is_protected "$SECRET_NAME"; then
  secrets_fail "PROTECTED_SECRET" \
    "refusing to describe a protected secret (root credentials); no per-call override exists" \
    "$(jq -nc --arg name "$SECRET_NAME" '{secret_name: $name}')"
fi

existing=$(secrets_get_existing "$SECRET_NAME") \
  || secrets_fail "OPERATION_FAILED" "cannot read live secret state (API error or RBAC denial)"
[[ -z "$existing" ]] \
  && secrets_fail "NOT_FOUND" "secret does not exist" \
       "$(jq -nc --arg ns "$DB_NAMESPACE" --arg name "$SECRET_NAME" '{namespace: $ns, secret_name: $name}')"

secrets_write_result "$(secrets_describe "$existing")"
