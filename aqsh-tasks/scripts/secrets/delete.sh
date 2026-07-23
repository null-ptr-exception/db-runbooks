#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# secrets/delete.sh
# aqsh task: delete a Secret behind the family's confirm gate (the repo's
# destructive-op convention — fcv/set, pbm/config): confirm=false (default)
# returns a read-only preview (metadata + key names + value fingerprints,
# never values); confirm=true deletes. Protected root-credential secrets are
# refused outright, same as plan/apply.
#
# Inputs (injected from tasks.yaml):
#   DB_NAMESPACE — target namespace
#   SECRET_NAME  — Secret to delete
#   CONFIRM      — "true" to actually delete (default "false" = preview)
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
CONFIRM="${CONFIRM:-false}"
export K8S_NAMESPACE="${DB_NAMESPACE}"

log_info "secrets-delete" "namespace=${DB_NAMESPACE} secret=${SECRET_NAME} confirm=${CONFIRM}"

if secrets_is_protected "$SECRET_NAME"; then
  secrets_fail "PROTECTED_SECRET" \
    "refusing to delete a protected secret (root credentials); no per-call override exists" \
    "$(jq -nc --arg name "$SECRET_NAME" '{secret_name: $name}')"
fi

existing=$(secrets_get_existing "$SECRET_NAME") \
  || secrets_fail "OPERATION_FAILED" "cannot read live secret state (API error or RBAC denial)"
[[ -z "$existing" ]] \
  && secrets_fail "NOT_FOUND" "secret does not exist" \
       "$(jq -nc --arg ns "$DB_NAMESPACE" --arg name "$SECRET_NAME" '{namespace: $ns, secret_name: $name}')"

description=$(secrets_describe "$existing")

if ! secrets_bool_enabled "$CONFIRM"; then
  secrets_write_result "$(printf '%s' "$description" \
    | jq -c '. + {deleted: false, confirm_required: true}')"
  exit 0
fi

secrets_delete "$SECRET_NAME" \
  || secrets_fail "OPERATION_FAILED" "kubectl delete failed (see task logs)" \
       "$(jq -nc --arg name "$SECRET_NAME" '{secret_name: $name}')"

secrets_write_result "$(printf '%s' "$description" | jq -c '. + {deleted: true}')"
