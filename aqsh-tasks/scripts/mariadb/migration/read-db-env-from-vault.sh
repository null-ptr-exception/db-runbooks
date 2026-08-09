#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/migration/read-db-env-from-vault.sh
# Read a HashiCorp Vault KV-v2 path and materialize its values as a
# Kubernetes Secret — the read-side counterpart to write-db-env-to-vault.
#
# This exists for cross-cluster migration: a value pushed to Vault by
# write-db-env-to-vault on the source cluster (root password, a dedicated
# replication user's password, ...) needs to land somewhere usable on the
# target cluster — e.g. as the --repl-password-secret migration/setup-replication
# expects. This task is reachable by any service account in
# system:serviceaccounts, so the value must never be observable in this
# task's own JSON response or logs, only in the Secret it writes.
#
# Vault auth is AppRole (VAULT_ROLE_ID/VAULT_SECRET_ID), sourced only from
# deploy-time internal config (/etc/aqsh/config/mariadb.env) — never a task
# input, for the same reason write-db-env-to-vault keeps it deploy-time-only.
#
# The Secret write is idempotent (create --dry-run=client -o yaml | apply),
# not a randomly-suffixed temp Secret: unlike restore.sh's short-lived
# credential Secret, this one is meant to persist and be re-fetched by
# setup-replication, and re-running this task to pick up a rotated Vault
# value should update the Secret in place rather than collide.
#
# --keys entries may rename a Vault key to a different Secret key:
# "root_password=repl_password" reads "root_password" from the Vault entry
# and writes it into the Secret under the key "repl_password". Omit "=..."
# to keep the Vault key's name. Omit --keys entirely to take every key in
# the Vault entry as-is.
# =============================================================================

# Capture the raw namespace input BEFORE sourcing k8s.sh — it defaults
# K8S_NAMESPACE to "default" at load time, which would otherwise make a
# missing --namespace/DB_NAMESPACE look like a valid explicit value below.
NAMESPACE_INPUT="${DB_NAMESPACE:-${K8S_NAMESPACE:-}}"

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi

# shellcheck source=../../../lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=../../../lib/response.sh
source "${LIB_DIR}/response.sh"
# shellcheck source=../../../lib/k8s.sh
source "${LIB_DIR}/k8s.sh"
# shellcheck source=../../../lib/vault.sh
source "${LIB_DIR}/vault.sh"

# Deploy-time config: VAULT_ADDR / VAULT_MOUNT / VAULT_ROLE_ID / VAULT_SECRET_ID.
[[ -f /etc/aqsh/config/mariadb.env ]] && source /etc/aqsh/config/mariadb.env

CONTEXT="${K8S_CONTEXT:-${CONTEXT:-}}"
NAMESPACE="$NAMESPACE_INPUT"
VAULT_PATH="${VAULT_PATH:-}"
SECRET_NAME="${SECRET_NAME:-}"
KEYS_STR="${KEYS_STR:-}"
RESULT_FILE="${AQSH_RESULT_FILE:-}"
JSON_ONLY=0

usage() {
  cat >&2 <<'EOF'
Usage:
  read-db-env-from-vault.sh --namespace <namespace> --vault-path <path> \
                             --secret-name <name> [options]

Options:
  --context <context>      Kubernetes context. Optional for in-cluster AQSH.
  --vault-path <path>      KV-v2 path (under this deploy's configured mount)
                            to read.
  --secret-name <name>     Kubernetes Secret to create/update in --namespace
                            with the retrieved values. Required.
  --keys <spec>            Comma-separated subset of the Vault entry's keys to
                            include. Each entry may be VAULT_KEY or
                            VAULT_KEY=secret_key to store it under a different
                            Secret key name. Omit to include every key.
  --json                   Print only JSON to stdout.
  --result-file <path>     Write JSON result to this file.
EOF
}

require_value() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo "error: $1 requires a value" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)     require_value "$1" "${2:-}"; CONTEXT="$2";     shift 2 ;;
    --namespace)   require_value "$1" "${2:-}"; NAMESPACE="$2";   shift 2 ;;
    --vault-path)  require_value "$1" "${2:-}"; VAULT_PATH="$2";  shift 2 ;;
    --secret-name) require_value "$1" "${2:-}"; SECRET_NAME="$2"; shift 2 ;;
    --keys)        require_value "$1" "${2:-}"; KEYS_STR="$2";    shift 2 ;;
    --json)        JSON_ONLY=1; shift ;;
    --result-file) require_value "$1" "${2:-}"; RESULT_FILE="$2"; shift 2 ;;
    -h | --help)   usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$NAMESPACE" ]]; then
  echo "error: --namespace is required" >&2
  usage
  exit 2
fi

if [[ ! "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "error: --namespace must be a valid Kubernetes namespace" >&2
  usage
  exit 2
fi

if [[ -z "$VAULT_PATH" ]]; then
  echo "error: --vault-path is required" >&2
  usage
  exit 2
fi

if [[ ! "$VAULT_PATH" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ "$VAULT_PATH" == /* ]] || [[ "$VAULT_PATH" == *..* ]]; then
  echo "error: --vault-path must match ^[A-Za-z0-9._/-]+\$, not start with '/', and not contain '..'" >&2
  usage
  exit 2
fi

if [[ -z "$SECRET_NAME" ]]; then
  echo "error: --secret-name is required" >&2
  usage
  exit 2
fi

if [[ ! "$SECRET_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "error: --secret-name must be a valid Kubernetes object name" >&2
  usage
  exit 2
fi

K8S_CONTEXT="$CONTEXT"
K8S_NAMESPACE="$NAMESPACE"

[[ "$JSON_ONLY" -ne 1 ]] && log_info "read-db-env-from-vault" \
  "namespace=${NAMESPACE} vault_path=${VAULT_PATH} secret_name=${SECRET_NAME}"

_emit_result() {
  local json="$1"
  [[ -n "$RESULT_FILE" ]] && printf '%s\n' "$json" > "$RESULT_FILE"
  printf '%s\n' "$json"
}

# _fail_result <reason_code> <summary>
# Every failure path returns secret:null — nothing was ever written.
_fail_result() {
  local reason="$1" summary="$2"
  _emit_result "$(jq -nc \
    --arg context "${CONTEXT:-}" \
    --arg namespace "$NAMESPACE" \
    --arg reason "$reason" \
    --arg summary "$summary" \
    --arg path "$VAULT_PATH" \
    '{status:"CRITICAL", reason_code:$reason, summary:$summary,
      target:{context:$context, namespace:$namespace},
      vault:{path:$path},
      secret:null}')"
  exit 0
}

# Vault must be usable before anything else.
if [[ -z "${VAULT_ADDR:-}" || -z "${VAULT_MOUNT:-}" || -z "${VAULT_ROLE_ID:-}" || -z "${VAULT_SECRET_ID:-}" ]]; then
  _fail_result "VAULT_NOT_CONFIGURED" \
    "Vault AppRole is not configured for this deployment (VAULT_ADDR/VAULT_MOUNT/VAULT_ROLE_ID/VAULT_SECRET_ID)"
fi

if ! k8s_check >/dev/null; then
  _fail_result "KUBECTL_UNAVAILABLE" "Kubernetes API is not reachable"
fi

if ! VAULT_TOKEN="$(vault_login)"; then
  _fail_result "VAULT_LOGIN_FAILED" "Failed to authenticate to Vault"
fi
export VAULT_TOKEN

VAULT_DATA="$(vault_kv_get "$VAULT_PATH")" || {
  vault_logout
  _fail_result "VAULT_READ_FAILED" "Failed to read vault path '${VAULT_PATH}' (missing, or Vault unreachable)"
}
vault_logout

if [[ "$(jq 'length' <<<"$VAULT_DATA")" -eq 0 ]]; then
  _emit_result "$(jq -nc \
    --arg context "${CONTEXT:-}" \
    --arg namespace "$NAMESPACE" \
    --arg path "$VAULT_PATH" \
    '{status:"OK", reason_code:"VAULT_PATH_EMPTY",
      summary:"Vault path has no keys",
      target:{context:$context, namespace:$namespace},
      vault:{path:$path},
      secret:null}')"
  exit 0
fi

# Select and rename keys. Each --keys entry is VAULT_KEY or
# VAULT_KEY=secret_key; the Secret key defaults to the Vault key name when no
# override is given. No --keys at all means "every key in the Vault entry".
SELECTED_JSON="{}"
MISSING_JSON="[]"
if [[ -n "$KEYS_STR" ]]; then
  IFS=',' read -ra KEY_SPECS <<< "$KEYS_STR"
  for raw_spec in "${KEY_SPECS[@]}"; do
    spec="${raw_spec// /}"
    [[ -z "$spec" ]] && continue
    vault_key="${spec%%=*}"
    if [[ "$spec" == *=* ]]; then
      secret_key="${spec#*=}"
    else
      secret_key="$vault_key"
    fi

    if [[ ! "$vault_key" =~ ^[A-Za-z0-9_.-]+$ ]] || [[ ! "$secret_key" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      MISSING_JSON=$(printf '%s' "$MISSING_JSON" | jq --arg k "$vault_key" '. + [$k]')
      continue
    fi

    value=$(jq -r --arg k "$vault_key" '.[$k] // empty' <<<"$VAULT_DATA")
    if [[ -n "$value" ]]; then
      SELECTED_JSON=$(printf '%s' "$SELECTED_JSON" | jq --arg k "$secret_key" --arg v "$value" '. + {($k): $v}')
    else
      MISSING_JSON=$(printf '%s' "$MISSING_JSON" | jq --arg k "$vault_key" '. + [$k]')
    fi
  done
else
  SELECTED_JSON="$VAULT_DATA"
fi

WRITTEN_COUNT="$(jq 'length' <<<"$SELECTED_JSON")"

if [[ "$WRITTEN_COUNT" -eq 0 ]]; then
  _emit_result "$(jq -nc \
    --arg context "${CONTEXT:-}" \
    --arg namespace "$NAMESPACE" \
    --arg path "$VAULT_PATH" \
    --argjson missing "$MISSING_JSON" \
    '{status:"OK", reason_code:"NO_KEYS_FOUND",
      summary:"None of the requested keys were found at the vault path",
      target:{context:$context, namespace:$namespace},
      vault:{path:$path},
      secret:{namespace:$namespace, name:null, keysWritten:[], keysMissing:$missing}}')"
  exit 0
fi

# Build --from-literal args and apply idempotently.
FROM_LITERAL_ARGS=()
while IFS='=' read -r k v; do
  [[ -z "$k" ]] && continue
  FROM_LITERAL_ARGS+=(--from-literal="${k}=${v}")
done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' <<<"$SELECTED_JSON")

if ! MANIFEST="$(_kubectl create secret generic "$SECRET_NAME" \
    "${FROM_LITERAL_ARGS[@]}" --dry-run=client -o yaml 2>&1)"; then
  _fail_result "SECRET_RENDER_FAILED" "Failed to render Secret manifest for '${SECRET_NAME}': ${MANIFEST}"
fi

if ! apply_out="$(printf '%s\n' "$MANIFEST" | _kubectl apply -f - 2>&1)"; then
  _fail_result "SECRET_WRITE_FAILED" "Failed to write Secret '${SECRET_NAME}' in namespace '${NAMESPACE}': ${apply_out}"
fi

WRITTEN_KEYS="$(jq -c 'keys' <<<"$SELECTED_JSON")"
RESULT_JSON=$(jq -nc \
  --arg status "OK" \
  --arg reason "ENV_IMPORTED_FROM_VAULT" \
  --arg summary "Wrote ${WRITTEN_COUNT} key(s) from vault path '${VAULT_PATH}' to secret '${SECRET_NAME}'" \
  --arg context "${CONTEXT:-}" \
  --arg namespace "$NAMESPACE" \
  --arg path "$VAULT_PATH" \
  --arg name "$SECRET_NAME" \
  --argjson written "$WRITTEN_KEYS" \
  --argjson missing "$MISSING_JSON" \
  '{status:$status, reason_code:$reason, summary:$summary,
    target:{context:$context, namespace:$namespace},
    vault:{path:$path},
    secret:{namespace:$namespace, name:$name, keysWritten:$written, keysMissing:$missing}}')

_emit_result "$RESULT_JSON"
