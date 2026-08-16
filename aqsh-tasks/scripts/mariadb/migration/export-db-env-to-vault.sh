#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/migration/export-db-env-to-vault.sh
# Read values from a MariaDB pod's environment and/or an existing Kubernetes
# Secret, and write them to a HashiCorp Vault KV-v2 path — never returned in
# the task result or logged.
#
# This exists for cross-cluster migration: a caller needs credentials read off
# one side (root password from the pod env, or a dedicated account's password
# from the Secret create-account generates) delivered usably to the other
# side, without those values ever appearing in this task's JSON response or
# logs. This task is reachable by any service account in
# `system:serviceaccounts`, so a value must never be observable there — only
# whichever principal Vault's ACL grants read access to vault_path sees it.
#
# Vault auth is AppRole (VAULT_ROLE_ID/VAULT_SECRET_ID), sourced only from
# deploy-time internal config (/etc/aqsh/config/mariadb.env) — never a task
# input. A per-call override would let a caller redirect writes under a
# different Vault identity than the one this deployment was provisioned with.
#
# Two independent, combinable source modes — at least one must be given:
#   --envs <VAR1[=vault_key1],VAR2,...>   Read from the MariaDB pod's own
#     environment via kubectl exec (works for MARIADB_ROOT_PASSWORD, which
#     the operator injects). Requires --mdb: this task reads credentials off
#     a specific instance on purpose, so the caller must name it explicitly
#     rather than risk a silently-wrong target if the namespace's instance
#     set changes.
#   --secret-keys <KEY1[=vault_key1],KEY2,...>   Read from an existing
#     Kubernetes Secret (e.g. the mariadb-account-<username> Secret
#     create-account generates for a non-root account, which never appears
#     as a pod env var). Requires --secret-name.
# Both may be given in one call; all found values land in a single Vault
# write. Each entry's "=vault_key" renames the Vault key independently of the
# source name; omit it to keep the pod-env-var / Secret-key name as-is.
# =============================================================================

# Capture the raw 'mdb' input BEFORE sourcing mariadb.sh — it defaults
# MARIADB_NAME to "mariadb" at load time, which would otherwise make a
# missing --mdb/MARIADB_NAME look like a valid explicit value below.
MDB_INPUT="${MARIADB_NAME:-${MARIADB_STS_NAME:-}}"

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
# shellcheck source=../../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"
# shellcheck source=../../../lib/vault.sh
source "${LIB_DIR}/vault.sh"

# Deploy-time config: VAULT_ADDR / VAULT_MOUNT / VAULT_ROLE_ID / VAULT_SECRET_ID.
[[ -f /etc/aqsh/config/mariadb.env ]] && source /etc/aqsh/config/mariadb.env

CONTEXT="${K8S_CONTEXT:-${CONTEXT:-}}"
NAMESPACE="$NAMESPACE_INPUT"
RESOURCE="${MARIADB_RESOURCE:-mariadb}"
MDB="$MDB_INPUT"
CONTAINER="${MARIADB_CONTAINER:-mariadb}"
ENVS_STR="${ENVS_STR:-}"
SECRET_NAME="${SECRET_NAME:-}"
SECRET_KEYS_STR="${SECRET_KEYS_STR:-}"
VAULT_PATH="${VAULT_PATH:-}"
RESULT_FILE="${AQSH_RESULT_FILE:-}"
JSON_ONLY=0

usage() {
  cat >&2 <<'EOF'
Usage:
  export-db-env-to-vault.sh --namespace <namespace> --vault-path <path> \
      [--mdb <name> --envs <VAR1[=vault_key1],VAR2,...>] \
      [--secret-name <name> --secret-keys <KEY1[=vault_key1],KEY2,...>] \
      [options]

At least one of (--mdb + --envs) or (--secret-name + --secret-keys) is
required; both may be given together.

Options:
  --context <context>      Kubernetes context. Optional for in-cluster AQSH.
  --resource <kind>        MariaDB CR kind. Default: mariadb.
  --mdb <name>             MariaDB CR / StatefulSet name. Required if --envs is given.
  --container <name>       MariaDB container name. Default: mariadb.
  --envs <spec>            Comma-separated env var names to read from the pod.
                            Each entry may be VAR or VAR=vault_key to store it
                            under a different name than the pod's env var.
  --secret-name <name>     Kubernetes Secret to read from. Required if --secret-keys is given.
  --secret-keys <spec>     Comma-separated Secret data keys to read. Each entry
                            may be KEY or KEY=vault_key to store it under a
                            different name than the Secret's key.
  --vault-path <path>      KV-v2 path (under this deploy's configured mount)
                            to write the retrieved values to. Values are never
                            returned here — read them back from Vault.
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
    --context)     require_value "$1" "${2:-}"; CONTEXT="$2";    shift 2 ;;
    --namespace)   require_value "$1" "${2:-}"; NAMESPACE="$2";  shift 2 ;;
    --resource)    require_value "$1" "${2:-}"; RESOURCE="$2";   shift 2 ;;
    --mdb | --name) require_value "$1" "${2:-}"; MDB="$2";       shift 2 ;;
    --container)   require_value "$1" "${2:-}"; CONTAINER="$2";  shift 2 ;;
    --envs)        require_value "$1" "${2:-}"; ENVS_STR="$2";   shift 2 ;;
    --secret-name) require_value "$1" "${2:-}"; SECRET_NAME="$2"; shift 2 ;;
    --secret-keys) require_value "$1" "${2:-}"; SECRET_KEYS_STR="$2"; shift 2 ;;
    --vault-path)  require_value "$1" "${2:-}"; VAULT_PATH="$2"; shift 2 ;;
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

if [[ -z "$ENVS_STR" && -z "$SECRET_KEYS_STR" ]]; then
  echo "error: at least one of --envs or --secret-keys is required" >&2
  usage
  exit 2
fi

if [[ -n "$ENVS_STR" && -z "$MDB" ]]; then
  echo "error: --mdb is required when --envs is given" >&2
  usage
  exit 2
fi

if [[ -n "$SECRET_KEYS_STR" && -z "$SECRET_NAME" ]]; then
  echo "error: --secret-name is required when --secret-keys is given" >&2
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

mariadb_set_target "$CONTEXT" "$NAMESPACE" "$RESOURCE" "$MDB" "$CONTAINER"

[[ "$JSON_ONLY" -ne 1 ]] && log_info "export-db-env-to-vault" \
  "namespace=${NAMESPACE} mdb=${MDB} envs=${ENVS_STR} secret_name=${SECRET_NAME} secret_keys=${SECRET_KEYS_STR} vault_path=${VAULT_PATH}"

_emit_result() {
  local json="$1"
  [[ -n "$RESULT_FILE" ]] && printf '%s\n' "$json" > "$RESULT_FILE"
  printf '%s\n' "$json"
}

# _fail_result <reason_code> <summary> [pod]
# Every failure path returns vault:null — nothing was ever written.
_fail_result() {
  local reason="$1" summary="$2" pod="${3:-}"
  _emit_result "$(jq -nc \
    --arg context "${CONTEXT:-}" \
    --arg namespace "$NAMESPACE" \
    --arg resource "$RESOURCE" \
    --arg mdb "$MDB" \
    --arg reason "$reason" \
    --arg summary "$summary" \
    --arg pod "$pod" \
    '{status:"CRITICAL", reason_code:$reason, summary:$summary,
      target:{context:$context, namespace:$namespace, resource:$resource, mdb:$mdb,
              pod:(if $pod == "" then null else $pod end)},
      vault:null}')"
  exit 0
}

# Vault must be usable before we touch anything: if the values can't be
# delivered safely, there is no point reading them at all.
if [[ -z "${VAULT_ADDR:-}" || -z "${VAULT_MOUNT:-}" || -z "${VAULT_ROLE_ID:-}" || -z "${VAULT_SECRET_ID:-}" ]]; then
  _fail_result "VAULT_NOT_CONFIGURED" \
    "Vault AppRole is not configured for this deployment (VAULT_ADDR/VAULT_MOUNT/VAULT_ROLE_ID/VAULT_SECRET_ID)"
fi

if ! k8s_check >/dev/null; then
  _fail_result "KUBECTL_UNAVAILABLE" "Kubernetes API is not reachable"
fi

FOUND_JSON="{}"
MISSING_JSON="[]"
POD=""
ENV_SPECS=()
SECRET_KEY_SPECS=()

if [[ -n "$ENVS_STR" ]]; then
  # Resolve pod list via CR replicas first, then StatefulSet replicas.
  CR_REPLICAS=""
  if CR_JSON=$(_kubectl get "$RESOURCE" "$MDB" -o json 2>/dev/null); then
    CR_REPLICAS=$(printf '%s' "$CR_JSON" | jq -r '.spec.replicas // ""')
  fi

  STS_REPLICAS=""
  if STS_JSON=$(_kubectl get statefulset "$MDB" -o json 2>/dev/null); then
    STS_REPLICAS=$(printf '%s' "$STS_JSON" | jq -r '.spec.replicas // ""')
  fi

  REPLICAS="${CR_REPLICAS:-$STS_REPLICAS}"
  mapfile -t PODS < <(mariadb_list_pods "$REPLICAS")

  if [[ "${#PODS[@]}" -eq 0 ]]; then
    _fail_result "NO_PODS_FOUND" "No MariaDB pods found in namespace"
  fi

  POD="${PODS[0]}"
  [[ "$JSON_ONLY" -ne 1 ]] && log_info "export-db-env-to-vault" "reading env vars from pod=${POD}"

  # Fetch each requested env var via kubectl exec printenv. Branch on the
  # command's exit status, not on whether the captured value is non-empty — a
  # variable set to an empty string is still "found"; only a failed lookup
  # (unset) is "missing". Each entry is VAR or VAR=vault_key; the Vault key
  # defaults to the env var name when no override is given.
  IFS=',' read -ra ENV_SPECS <<< "$ENVS_STR"
  for raw_spec in "${ENV_SPECS[@]}"; do
    spec="${raw_spec// /}"
    [[ -z "$spec" ]] && continue
    name="${spec%%=*}"
    if [[ "$spec" == *=* ]]; then
      vault_key="${spec#*=}"
    else
      vault_key="$name"
    fi

    if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || [[ ! "$vault_key" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      MISSING_JSON=$(printf '%s' "$MISSING_JSON" | jq --arg n "$name" '. + [$n]')
      continue
    fi

    if value=$(mariadb_exec "$POD" printenv "$name" 2>/dev/null); then
      FOUND_JSON=$(printf '%s' "$FOUND_JSON" | jq --arg k "$vault_key" --arg v "$value" '. + {($k): $v}')
    else
      MISSING_JSON=$(printf '%s' "$MISSING_JSON" | jq --arg n "$name" '. + [$n]')
    fi
  done
fi

if [[ -n "$SECRET_KEYS_STR" ]]; then
  [[ "$JSON_ONLY" -ne 1 ]] && log_info "export-db-env-to-vault" "reading keys from secret=${SECRET_NAME}"

  # Each entry is KEY or KEY=vault_key; Secret data keys use a wider charset
  # than shell identifiers (dots/hyphens are common, e.g. "root-password"),
  # so this validates against the Secret-key/vault-key charset, not the
  # shell-identifier charset --envs entries use.
  IFS=',' read -ra SECRET_KEY_SPECS <<< "$SECRET_KEYS_STR"
  for raw_spec in "${SECRET_KEY_SPECS[@]}"; do
    spec="${raw_spec// /}"
    [[ -z "$spec" ]] && continue
    name="${spec%%=*}"
    if [[ "$spec" == *=* ]]; then
      vault_key="${spec#*=}"
    else
      vault_key="$name"
    fi

    if [[ ! "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || [[ ! "$vault_key" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      MISSING_JSON=$(printf '%s' "$MISSING_JSON" | jq --arg n "$name" '. + [$n]')
      continue
    fi

    if value=$(k8s_secret_value "$SECRET_NAME" "$name"); then
      FOUND_JSON=$(printf '%s' "$FOUND_JSON" | jq --arg k "$vault_key" --arg v "$value" '. + {($k): $v}')
    else
      MISSING_JSON=$(printf '%s' "$MISSING_JSON" | jq --arg n "$name" '. + [$n]')
    fi
  done
fi

WRITTEN_COUNT="$(jq 'length' <<<"$FOUND_JSON")"
TOTAL="$(( ${#ENV_SPECS[@]} + ${#SECRET_KEY_SPECS[@]} ))"

if [[ "$WRITTEN_COUNT" -eq 0 ]]; then
  _emit_result "$(jq -nc \
    --arg context "${CONTEXT:-}" \
    --arg namespace "$NAMESPACE" \
    --arg resource "$RESOURCE" \
    --arg mdb "$MDB" \
    --arg pod "$POD" \
    --argjson missing "$MISSING_JSON" \
    '{status:"OK", reason_code:"NO_VARS_FOUND",
      summary:"None of the requested values were found",
      target:{context:$context, namespace:$namespace, resource:$resource, mdb:$mdb,
              pod:(if $pod == "" then null else $pod end)},
      vault:{path:null, keysWritten:[], keysMissing:$missing}}')"
  exit 0
fi

if ! VAULT_TOKEN="$(vault_login)"; then
  _fail_result "VAULT_LOGIN_FAILED" "Failed to authenticate to Vault" "$POD"
fi
export VAULT_TOKEN

if ! vault_kv_put "$VAULT_PATH" "$FOUND_JSON"; then
  vault_logout
  _fail_result "VAULT_WRITE_FAILED" "Failed to write values to vault path '${VAULT_PATH}'" "$POD"
fi
vault_logout

# Describe where the written values came from for the summary line — pod,
# Secret, or both when a call combines the two source modes.
SOURCE_DESC=""
[[ -n "$POD" ]] && SOURCE_DESC="pod=${POD}"
if [[ -n "$SECRET_NAME" && -n "$SECRET_KEYS_STR" ]]; then
  [[ -n "$SOURCE_DESC" ]] && SOURCE_DESC="${SOURCE_DESC}, "
  SOURCE_DESC="${SOURCE_DESC}secret=${SECRET_NAME}"
fi

WRITTEN_KEYS="$(jq -c 'keys' <<<"$FOUND_JSON")"
RESULT_JSON=$(jq -nc \
  --arg status "OK" \
  --arg reason "ENV_EXPORTED_TO_VAULT" \
  --arg summary "Wrote ${WRITTEN_COUNT}/${TOTAL} value(s) from ${SOURCE_DESC} to vault path '${VAULT_PATH}'" \
  --arg context "${CONTEXT:-}" \
  --arg namespace "$NAMESPACE" \
  --arg resource "$RESOURCE" \
  --arg mdb "$MDB" \
  --arg pod "$POD" \
  --arg path "$VAULT_PATH" \
  --argjson written "$WRITTEN_KEYS" \
  --argjson missing "$MISSING_JSON" \
  '{status:$status, reason_code:$reason, summary:$summary,
    target:{context:$context, namespace:$namespace, resource:$resource, mdb:$mdb,
            pod:(if $pod == "" then null else $pod end)},
    vault:{path:$path, keysWritten:$written, keysMissing:$missing}}')

_emit_result "$RESULT_JSON"
