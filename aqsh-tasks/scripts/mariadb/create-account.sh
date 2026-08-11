#!/usr/bin/env bash
set -euo pipefail

# Create or recreate a MariaDB account. The public password and delivery
# contract intentionally matches MongoDB create-account; expiry remains native
# MariaDB state and has no reconciliation lifecycle.

MDB_INPUT="${MARIADB_NAME:-${MARIADB_STS_NAME:-}}"

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi

# shellcheck source=../../lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=../../lib/response.sh
source "${LIB_DIR}/response.sh"
# shellcheck source=../../lib/k8s.sh
source "${LIB_DIR}/k8s.sh"
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"
# Reuse the generator and outbound PGP payload implementation used by MongoDB.
# shellcheck source=../../lib/mongodb-account.sh
source "${LIB_DIR}/mongodb-account.sh"
# Reuse the deployment protected-Secret resolver.
# shellcheck source=../../lib/secrets.sh
source "${LIB_DIR}/secrets.sh"
# shellcheck source=../../lib/mariadb-account.sh
source "${LIB_DIR}/mariadb-account.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  create-account.sh --namespace <namespace> --username <user> [options]

Scope:
  --database <database>            Database-scoped grants. Omit for SELECT ON *.*.
  --privileges <list>              Comma-separated privileges. Default: SELECT
  --host <host>                    MariaDB account host. Default: %
  --allow-admin-privileges <bool>  Allow broad/admin privileges on a database.
  --allow-existing <bool>          Recreate credentials and replace all grants.

Password delivery:
  --password-length <n>            Generated password length. Default: 24; min: 12
  --password-special-chars <text>  Allowed generated special characters.
  --password-special-max <n>       Maximum generated special characters. Default: 4
  --password-delivery-mode <mode>  one_time_plaintext or encrypted_payload.
  --recipient-pgp-pubkey <key>     Required for encrypted_payload.
  --password-secret-name <name>    Read a fixed password from an existing Secret.
  --password-secret-key <key>      Existing Secret key. Default: password

Native expiry:
  --password-expire-mode <mode>    first_login, interval, never, or default.
  --validity-days <n>              Positive integer; only valid with interval.

Safety and target:
  --dry-run <bool>                 Default: true
  --confirm <bool>                 Required true when dry_run=false.
  --context <context>              Optional for in-cluster AQSH.
  --resource <kind>                Default: mariadb
  --mdb <name>                     Default: auto-detected.
  --container <name>               Default: mariadb
  --json                           Print JSON to stdout.
  --result-file <path>             Write JSON to this file.
  --strict-exit                    Non-zero exit on BLOCKED or ERROR.
EOF
}

require_value() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo "error: $1 requires a value" >&2
    exit 2
  fi
}

CONTEXT="${K8S_CONTEXT:-${CONTEXT:-}}"
NAMESPACE="${DB_NAMESPACE:-${K8S_NAMESPACE:-}}"
RESOURCE="${MARIADB_RESOURCE:-mariadb}"
MDB="$MDB_INPUT"
CONTAINER="${MARIADB_CONTAINER:-mariadb}"
DATABASE="${ACCOUNT_DATABASE:-}"
USERNAME="${ACCOUNT_USERNAME:-}"
ACCOUNT_HOST_VALUE="${ACCOUNT_HOST:-%}"
PRIVILEGES_RAW="${ACCOUNT_PRIVILEGES:-SELECT}"
ALLOW_EXISTING="${ALLOW_EXISTING:-false}"
ALLOW_ADMIN_PRIVILEGES="${ALLOW_ADMIN_PRIVILEGES:-false}"
PASSWORD_LENGTH="${PASSWORD_LENGTH:-24}"
PASSWORD_SPECIAL_CHARS="${PASSWORD_SPECIAL_CHARS:-!@#%^*_-+=.}"
PASSWORD_SPECIAL_MAX="${PASSWORD_SPECIAL_MAX:-4}"
PASSWORD_DELIVERY_MODE="${PASSWORD_DELIVERY_MODE:-one_time_plaintext}"
RECIPIENT_PGP_PUBKEY="${RECIPIENT_PGP_PUBKEY:-}"
PASSWORD_SECRET_NAME="${PASSWORD_SECRET_NAME:-}"
PASSWORD_SECRET_KEY="${PASSWORD_SECRET_KEY:-password}"
PASSWORD_EXPIRE_MODE="${PASSWORD_EXPIRE_MODE:-first_login}"
VALIDITY_DAYS="${VALIDITY_DAYS:-}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"
JSON_ONLY=0
STRICT_EXIT=0
RESULT_FILE="${AQSH_RESULT_FILE:-}"

# Request globals assigned while parsing are consumed by mariadb-account.sh.
# shellcheck disable=SC2034
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) require_value "$1" "${2:-}"; CONTEXT="$2"; shift 2 ;;
    --namespace) require_value "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
    --resource) require_value "$1" "${2:-}"; RESOURCE="$2"; shift 2 ;;
    --mdb | --name) require_value "$1" "${2:-}"; MDB="$2"; shift 2 ;;
    --container) require_value "$1" "${2:-}"; CONTAINER="$2"; shift 2 ;;
    --database) require_value "$1" "${2:-}"; DATABASE="$2"; shift 2 ;;
    --username) require_value "$1" "${2:-}"; USERNAME="$2"; shift 2 ;;
    --host) require_value "$1" "${2:-}"; ACCOUNT_HOST_VALUE="$2"; shift 2 ;;
    --privileges) require_value "$1" "${2:-}"; PRIVILEGES_RAW="$2"; shift 2 ;;
    --allow-existing) require_value "$1" "${2:-}"; ALLOW_EXISTING="$2"; shift 2 ;;
    --allow-admin-privileges) require_value "$1" "${2:-}"; ALLOW_ADMIN_PRIVILEGES="$2"; shift 2 ;;
    --password-length) require_value "$1" "${2:-}"; PASSWORD_LENGTH="$2"; shift 2 ;;
    --password-special-chars) require_value "$1" "${2:-}"; PASSWORD_SPECIAL_CHARS="$2"; shift 2 ;;
    --password-special-max) require_value "$1" "${2:-}"; PASSWORD_SPECIAL_MAX="$2"; shift 2 ;;
    --password-delivery-mode) require_value "$1" "${2:-}"; PASSWORD_DELIVERY_MODE="$2"; shift 2 ;;
    --recipient-pgp-pubkey) require_value "$1" "${2:-}"; RECIPIENT_PGP_PUBKEY="$2"; shift 2 ;;
    --password-secret-name) require_value "$1" "${2:-}"; PASSWORD_SECRET_NAME="$2"; shift 2 ;;
    --password-secret-key) require_value "$1" "${2:-}"; PASSWORD_SECRET_KEY="$2"; shift 2 ;;
    --password-expire-mode) require_value "$1" "${2:-}"; PASSWORD_EXPIRE_MODE="$2"; shift 2 ;;
    --validity-days) require_value "$1" "${2:-}"; VALIDITY_DAYS="$2"; shift 2 ;;
    --dry-run) require_value "$1" "${2:-}"; DRY_RUN="$2"; shift 2 ;;
    --confirm) require_value "$1" "${2:-}"; CONFIRM="$2"; shift 2 ;;
    --json) JSON_ONLY=1; shift ;;
    --result-file) require_value "$1" "${2:-}"; RESULT_FILE="$2"; shift 2 ;;
    --strict-exit) STRICT_EXIT=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

ERRORS=()
# shellcheck disable=SC2034  # Consumed by mariadb-account.sh.
PRIVILEGES=()
PRIVILEGES_SQL=""
GRANT_SCOPE=""
# shellcheck disable=SC2034  # Consumed by mariadb-account.sh.
SCOPE_KIND=""
EXPIRY_SQL=""
MUTATION_APPLIED=false

mariadb_account_validate_inputs
SQL_PLAN_JSON="$(mariadb_account_build_sql_plan_json)"
if [[ "${#ERRORS[@]}" -gt 0 ]]; then
  SUMMARY="Invalid create-account request"
  mariadb_account_emit_result "$(mariadb_account_result_json ERROR INVALID_INPUT "$SUMMARY" "" false "$SQL_PLAN_JSON" "$(mariadb_account_errors_json)")" ERROR "$SUMMARY"
fi

if bool_enabled "$DRY_RUN"; then
  SUMMARY="Dry-run ready; no Kubernetes or SQL changes were made"
  mariadb_account_emit_result "$(mariadb_account_result_json READY DRY_RUN_READY "$SUMMARY" "" false "$SQL_PLAN_JSON")" READY "$SUMMARY"
fi
if ! bool_enabled "$CONFIRM"; then
  SUMMARY="confirm=true is required when dry_run=false"
  mariadb_account_emit_result "$(mariadb_account_result_json BLOCKED CONFIRM_REQUIRED "$SUMMARY" "" false "$SQL_PLAN_JSON")" BLOCKED "$SUMMARY"
fi

mariadb_set_target "$CONTEXT" "$NAMESPACE" "$RESOURCE" "$MDB" "$CONTAINER"
if ! k8s_check >/dev/null; then
  SUMMARY="kubectl is unavailable or cannot reach the target cluster"
  mariadb_account_emit_result "$(mariadb_account_result_json ERROR KUBECTL_UNAVAILABLE "$SUMMARY" "" false "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi

_on_ambiguous() {
  local summary="Multiple MariaDB targets in namespace ($1); specify --mdb" candidates
  candidates="$(printf '%s' "$1" | tr ',' '\n' | jq -Rsc 'split("\n")[:-1]')"
  mariadb_account_emit_result "$(mariadb_account_result_json ERROR MARIADB_AMBIGUOUS "$summary" "" false "$SQL_PLAN_JSON" '[]' null "$candidates")" ERROR "$summary"
}
_on_none() {
  local summary="No MariaDB CR or StatefulSet found in namespace"
  mariadb_account_emit_result "$(mariadb_account_result_json ERROR MARIADB_NOT_FOUND "$summary" "" false "$SQL_PLAN_JSON")" ERROR "$summary"
}
if [[ -z "$MDB" ]]; then mariadb_autodetect_target true _on_ambiguous _on_none; MDB="$MARIADB_NAME"; fi

CURRENT_PRIMARY="$(mariadb_jsonpath "$RESOURCE" "$MDB" '{.status.currentPrimary}' || true)"
REPLICAS="$(mariadb_cr_replicas || true)"
[[ -n "$REPLICAS" ]] || REPLICAS="$(mariadb_sts_replicas || true)"
mapfile -t PODS < <(mariadb_list_pods "$REPLICAS")
[[ -n "$CURRENT_PRIMARY" || "${#PODS[@]}" -eq 0 ]] || CURRENT_PRIMARY="${PODS[0]}"
if [[ -z "$CURRENT_PRIMARY" ]]; then
  SUMMARY="Cannot determine MariaDB primary pod"
  mariadb_account_emit_result "$(mariadb_account_result_json ERROR CURRENT_PRIMARY_EMPTY "$SUMMARY" "" false "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi
if ! ROOT_PASSWORD="$(mariadb_read_root_password "$CURRENT_PRIMARY" "${PODS[@]}")"; then
  SUMMARY="Cannot read MariaDB root password from target pods"
  mariadb_account_emit_result "$(mariadb_account_result_json ERROR ROOT_PASSWORD_UNAVAILABLE "$SUMMARY" "$CURRENT_PRIMARY" false "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi

USER_LITERAL="$(mariadb_account_sql_string_literal "$USERNAME")"
HOST_LITERAL="$(mariadb_account_sql_string_literal "$ACCOUNT_HOST_VALUE")"
ACCOUNT_REF="${USER_LITERAL}@${HOST_LITERAL}"
if ! ACCOUNT_COUNT="$(mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "SELECT COUNT(*) FROM mysql.user WHERE User=${USER_LITERAL} AND Host=${HOST_LITERAL}")" || [[ ! "$ACCOUNT_COUNT" =~ ^[0-9]+$ ]]; then
  SUMMARY="Failed to check whether MariaDB account already exists"
  mariadb_account_emit_result "$(mariadb_account_result_json ERROR SQL_FAILED "$SUMMARY" "$CURRENT_PRIMARY" false "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi
ACCOUNT_EXISTS=false
[[ "$ACCOUNT_COUNT" -eq 0 ]] || ACCOUNT_EXISTS=true
if [[ "$ACCOUNT_EXISTS" == true ]] && ! bool_enabled "$ALLOW_EXISTING"; then
  SUMMARY="MariaDB account already exists"
  mariadb_account_emit_result "$(mariadb_account_result_json ERROR ACCOUNT_ALREADY_EXISTS "$SUMMARY" "$CURRENT_PRIMARY" true "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi

EFFECTIVE_DELIVERY_MODE="$PASSWORD_DELIVERY_MODE"
if [[ -n "$PASSWORD_SECRET_NAME" ]]; then
  export K8S_NAMESPACE="$NAMESPACE"
  if [[ "$PASSWORD_SECRET_NAME" == "$MDB" || "$PASSWORD_SECRET_NAME" == "mariadb" ]] || secrets_is_protected "$PASSWORD_SECRET_NAME"; then
    SUMMARY="Refusing to read a protected Secret as an account password source"
    mariadb_account_emit_result "$(mariadb_account_result_json ERROR PROTECTED_SECRET "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
  fi
  if ! PASSWORD_VALUE="$(mariadb_account_read_secret_password)" || [[ -z "$PASSWORD_VALUE" ]]; then
    SUMMARY="Cannot read password from the caller-provided Secret"
    mariadb_account_emit_result "$(mariadb_account_result_json ERROR PASSWORD_SECRET_UNAVAILABLE "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
  fi
  EFFECTIVE_DELIVERY_MODE="caller_provided_secret"
else
  if ! PASSWORD_VALUE="$(generate_password 2>/dev/null)"; then
    SUMMARY="Failed to generate a password from the requested policy"
    mariadb_account_emit_result "$(mariadb_account_result_json ERROR PASSWORD_GENERATION_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
  fi
fi

case "$EFFECTIVE_DELIVERY_MODE" in
  caller_provided_secret)
    DELIVERY_PAYLOAD="$(jq -nc --arg secret_name "$PASSWORD_SECRET_NAME" --arg secret_key "$PASSWORD_SECRET_KEY" '{mode:"caller_provided_secret",secret_name:$secret_name,secret_key:$secret_key}')"
    ;;
  one_time_plaintext)
    DELIVERY_PAYLOAD="$(jq -nc --arg password "$PASSWORD_VALUE" '{mode:"one_time_plaintext",password:$password}')"
    ;;
  encrypted_payload)
    if ! DELIVERY_PAYLOAD="$(mariadb_account_encrypt_password_payload "$PASSWORD_VALUE" "$RECIPIENT_PGP_PUBKEY" 2>/dev/null)"; then
      SUMMARY="Failed to encrypt password payload with the recipient public key"
      mariadb_account_emit_result "$(mariadb_account_result_json ERROR DELIVERY_ENCRYPT_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
    fi
    ;;
esac

PASSWORD_LITERAL="$(mariadb_account_sql_string_literal "$PASSWORD_VALUE")"
if [[ "$ACCOUNT_EXISTS" == true ]]; then
  ACCOUNT_SQL="ALTER USER ${ACCOUNT_REF} IDENTIFIED BY ${PASSWORD_LITERAL} ${EXPIRY_SQL};"
  REVOKE_SQL="REVOKE ALL PRIVILEGES, GRANT OPTION FROM ${ACCOUNT_REF};"
else
  ACCOUNT_SQL="CREATE USER ${ACCOUNT_REF} IDENTIFIED BY ${PASSWORD_LITERAL} ${EXPIRY_SQL};"
  REVOKE_SQL=""
fi
GRANT_SQL="GRANT ${PRIVILEGES_SQL} ON ${GRANT_SCOPE} TO ${ACCOUNT_REF};"

if ! mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "$ACCOUNT_SQL" >/dev/null; then
  SUMMARY="Failed to create or recreate MariaDB account"
  mariadb_account_emit_result "$(mariadb_account_result_json ERROR ACCOUNT_MUTATION_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi
# shellcheck disable=SC2034  # Consumed by mariadb-account.sh.
MUTATION_APPLIED=true
if [[ -n "$REVOKE_SQL" ]] && ! mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "$REVOKE_SQL" >/dev/null; then
  SUMMARY="Account credential changed but revoking the prior grants failed"
  mariadb_account_emit_result "$(mariadb_account_result_json ERROR SQL_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi
if ! mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "$GRANT_SQL" >/dev/null; then
  SUMMARY="Account credential changed but applying the requested grant failed"
  mariadb_account_emit_result "$(mariadb_account_result_json ERROR SQL_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi
if ! SHOW_GRANTS="$(mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "SHOW GRANTS FOR ${ACCOUNT_REF}")"; then
  SUMMARY="Account was changed but SHOW GRANTS verification failed"
  mariadb_account_emit_result "$(mariadb_account_result_json ERROR SQL_VERIFY_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi
if ! mariadb_account_grants_match "$SHOW_GRANTS"; then
  SUMMARY="SHOW GRANTS did not contain the requested effective grant"
  mariadb_account_emit_result "$(mariadb_account_result_json ERROR SQL_VERIFY_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi

if [[ "$ACCOUNT_EXISTS" == true ]]; then STATUS="RECREATED"; REASON="ACCOUNT_RECREATED"; SUMMARY="MariaDB account recreated and grants replaced and verified"
else STATUS="CREATED"; REASON="ACCOUNT_CREATED"; SUMMARY="MariaDB account created and grants verified"
fi
mariadb_account_emit_result "$(mariadb_account_result_json "$STATUS" "$REASON" "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON" '[]' "$DELIVERY_PAYLOAD")" "$STATUS" "$SUMMARY"
