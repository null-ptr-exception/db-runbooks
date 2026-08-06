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
PRIVILEGES=()
PRIVILEGES_SQL=""
GRANT_SCOPE=""
SCOPE_KIND=""
EXPIRY_SQL=""
MUTATION_APPLIED=false

add_error() { ERRORS+=("$1"); }

is_valid_bool() {
  case "${1:-}" in
    1 | 0 | true | false | TRUE | FALSE | yes | no | YES | NO | on | off | ON | OFF) return 0 ;;
    *) return 1 ;;
  esac
}

is_admin_privilege() {
  case "$1" in
    ALL | "ALL PRIVILEGES" | SUPER | FILE | PROCESS | RELOAD | SHUTDOWN | "GRANT OPTION") return 0 ;;
    *) return 1 ;;
  esac
}

is_allowed_privilege() {
  case "$1" in
    SELECT | INSERT | UPDATE | DELETE | CREATE | ALTER | INDEX | EXECUTE | "SHOW VIEW") return 0 ;;
    *) is_admin_privilege "$1" && bool_enabled "$ALLOW_ADMIN_PRIVILEGES" ;;
  esac
}

normalize_privilege() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' |
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g'
}

contains_control_chars() {
  [[ "$1" =~ [[:cntrl:]] ]]
}

validate_inputs() {
  [[ -n "$NAMESPACE" ]] || add_error "namespace is required"
  [[ -n "$USERNAME" ]] || add_error "username is required"
  [[ -n "$PRIVILEGES_RAW" ]] || add_error "privileges is required"

  if [[ -n "$NAMESPACE" && ! "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    add_error "namespace must be a valid Kubernetes namespace"
  fi
  if [[ -n "$USERNAME" ]]; then
    [[ "$USERNAME" =~ ^[A-Za-z0-9_.-]+$ ]] || add_error "username may only contain letters, numbers, underscore, dot, and dash"
    case "$(printf '%s' "$USERNAME" | tr '[:upper:]' '[:lower:]')" in
      root | mysql | mariadb | admin | administrator | system | sys) add_error "reserved username is not allowed" ;;
    esac
  fi
  if [[ -n "$ACCOUNT_HOST_VALUE" ]] && { contains_control_chars "$ACCOUNT_HOST_VALUE" || [[ "$ACCOUNT_HOST_VALUE" == *"'"* ]]; }; then
    add_error "host contains unsupported characters"
  fi

  if [[ -z "$DATABASE" ]]; then
    SCOPE_KIND="all_databases_read_only"
    GRANT_SCOPE="*.*"
  elif [[ "$DATABASE" == "*" || "$DATABASE" == "*.*" ]]; then
    add_error "omit database to request the all-database read-only scope"
  elif [[ ! "$DATABASE" =~ ^[A-Za-z0-9_-]+$ ]]; then
    add_error "database may only contain letters, numbers, underscore, and dash"
  else
    SCOPE_KIND="database"
    GRANT_SCOPE="\`${DATABASE}\`.*"
  fi

  local item normalized sep=""
  IFS=',' read -r -a privilege_items <<< "$PRIVILEGES_RAW"
  for item in "${privilege_items[@]}"; do
    normalized="$(normalize_privilege "$item")"
    [[ -z "$normalized" ]] && continue
    if ! is_allowed_privilege "$normalized"; then
      add_error "privilege '${normalized}' is not allowed"
      continue
    fi
    PRIVILEGES+=("$normalized")
  done
  [[ "${#PRIVILEGES[@]}" -gt 0 ]] || add_error "at least one valid privilege is required"
  if [[ -z "$DATABASE" && ( "${#PRIVILEGES[@]}" -ne 1 || "${PRIVILEGES[0]:-}" != "SELECT" ) ]]; then
    add_error "all-database scope permits exactly SELECT"
  fi
  for item in "${PRIVILEGES[@]}"; do
    PRIVILEGES_SQL="${PRIVILEGES_SQL}${sep}${item}"
    sep=", "
  done

  local bool_var
  for bool_var in ALLOW_EXISTING ALLOW_ADMIN_PRIVILEGES DRY_RUN CONFIRM; do
    is_valid_bool "${!bool_var}" || add_error "${bool_var} must be a boolean-like value"
  done

  [[ "$PASSWORD_LENGTH" =~ ^[0-9]+$ ]] || add_error "password_length must be an integer"
  if [[ "$PASSWORD_LENGTH" =~ ^[0-9]+$ && "$PASSWORD_LENGTH" -lt 12 ]]; then
    add_error "password_length must be at least 12"
  fi
  [[ "$PASSWORD_SPECIAL_MAX" =~ ^[0-9]+$ ]] || add_error "password_special_max must be a non-negative integer"
  if [[ "$PASSWORD_SPECIAL_CHARS" == *"'"* || "$PASSWORD_SPECIAL_CHARS" == *'"'* || "$PASSWORD_SPECIAL_CHARS" == *\\* || "$PASSWORD_SPECIAL_CHARS" =~ [[:space:]] ]]; then
    add_error "password_special_chars contains unsupported characters"
  fi
  case "$PASSWORD_DELIVERY_MODE" in
    one_time_plaintext | encrypted_payload) ;;
    *) add_error "unsupported password_delivery_mode" ;;
  esac
  if [[ "$PASSWORD_DELIVERY_MODE" == "encrypted_payload" && -z "$RECIPIENT_PGP_PUBKEY" ]]; then
    add_error "recipient_pgp_pubkey is required when password_delivery_mode=encrypted_payload"
  fi

  if [[ -n "$PASSWORD_SECRET_NAME" ]]; then
    [[ "$PASSWORD_SECRET_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || add_error "password_secret_name must be a valid Kubernetes Secret name"
    [[ "$PASSWORD_SECRET_KEY" =~ ^[A-Za-z0-9._-]+$ ]] || add_error "password_secret_key contains unsupported characters"
    if [[ "$PASSWORD_DELIVERY_MODE" != "one_time_plaintext" || -n "$RECIPIENT_PGP_PUBKEY" ]]; then
      add_error "password_delivery_mode/recipient_pgp_pubkey are not applicable when password_secret_name is set"
    fi
  fi

  case "$PASSWORD_EXPIRE_MODE" in
    first_login) EXPIRY_SQL="PASSWORD EXPIRE" ;;
    interval)
      EXPIRY_SQL="PASSWORD EXPIRE INTERVAL ${VALIDITY_DAYS} DAY"
      if [[ ! "$VALIDITY_DAYS" =~ ^[1-9][0-9]*$ ]]; then
        add_error "validity_days must be a positive integer when password_expire_mode=interval"
      fi
      ;;
    never) EXPIRY_SQL="PASSWORD EXPIRE NEVER" ;;
    default) EXPIRY_SQL="PASSWORD EXPIRE DEFAULT" ;;
    *) add_error "unsupported password_expire_mode" ;;
  esac
  if [[ "$PASSWORD_EXPIRE_MODE" != "interval" && -n "$VALIDITY_DAYS" ]]; then
    add_error "validity_days is only valid when password_expire_mode=interval"
  fi
}

sql_string_literal() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

build_sql_plan_json() {
  local account
  account="$(sql_string_literal "$USERNAME")@$(sql_string_literal "$ACCOUNT_HOST_VALUE")"
  local create_stmt="CREATE USER ${account} IDENTIFIED BY '<redacted>' ${EXPIRY_SQL}"
  local grant_stmt="GRANT ${PRIVILEGES_SQL} ON ${GRANT_SCOPE} TO ${account}"
  if bool_enabled "$ALLOW_EXISTING"; then
    jq -nc --arg alter "ALTER USER ${account} IDENTIFIED BY '<redacted>' ${EXPIRY_SQL}" \
      --arg revoke "REVOKE ALL PRIVILEGES, GRANT OPTION FROM ${account}" \
      --arg grant "$grant_stmt" --arg verify "SHOW GRANTS FOR ${account}" \
      '[$alter,$revoke,$grant,$verify]'
  else
    jq -nc --arg create "$create_stmt" --arg grant "$grant_stmt" \
      --arg verify "SHOW GRANTS FOR ${account}" '[$create,$grant,$verify]'
  fi
}

errors_json() {
  if [[ "${#ERRORS[@]}" -eq 0 ]]; then
    printf '[]'
  else
    printf '%s\n' "${ERRORS[@]}" | jq -Rsc 'split("\n")[:-1]'
  fi
}

result_json() {
  local status="$1" reason="$2" summary="$3" primary="${4:-}" existing="${5:-false}"
  local plan="${6:-[]}" errors="${7:-[]}" delivery="${8:-null}" candidates="${9:-[]}"
  local privileges_json
  if [[ "${#PRIVILEGES[@]}" -eq 0 ]]; then
    privileges_json='[]'
  else
    privileges_json="$(printf '%s\n' "${PRIVILEGES[@]}" | jq -Rsc 'split("\n")[:-1]')"
  fi
  jq -nc \
    --arg status "$status" --arg reason_code "$reason" --arg summary "$summary" \
    --arg context "${CONTEXT:-}" --arg namespace "$NAMESPACE" --arg resource "$RESOURCE" --arg mdb "$MDB" \
    --arg database "$DATABASE" --arg scope "$SCOPE_KIND" --arg grant_scope "$GRANT_SCOPE" \
    --arg username "$USERNAME" --arg host "$ACCOUNT_HOST_VALUE" --arg primary "$primary" \
    --arg password_expire_mode "$PASSWORD_EXPIRE_MODE" --arg validity_days "$VALIDITY_DAYS" \
    --argjson privileges "$privileges_json" --argjson dry_run "$(bool_enabled "$DRY_RUN" && printf true || printf false)" \
    --argjson account_exists "$existing" --argjson mutation_applied "$MUTATION_APPLIED" \
    --argjson sql_plan "$plan" --argjson errors "$errors" \
    --argjson delivery_payload "$delivery" --argjson candidates "$candidates" \
    '{status:$status,reason_code:$reason_code,summary:$summary,
      target:{context:$context,namespace:$namespace,resource:$resource,mdb:$mdb},
      database:(if $database == "" then null else $database end),
      scope:{kind:$scope,grant:$grant_scope},username:$username,host:$host,
      privileges:$privileges,password_expire_mode:$password_expire_mode,
      validity_days:(if $validity_days == "" then null else (try ($validity_days|tonumber) catch $validity_days) end),
      primary:$primary,dry_run:$dry_run,account_exists:$account_exists,
      mutation_applied:$mutation_applied,
      delivery_payload:$delivery_payload,sql_plan:$sql_plan,errors:$errors,candidates:$candidates}'
}

emit_result() {
  local json="$1" status="$2" summary="$3"
  [[ -z "$RESULT_FILE" ]] || printf '%s\n' "$json" > "$RESULT_FILE"
  if [[ "$JSON_ONLY" -eq 1 || -z "$RESULT_FILE" ]]; then printf '%s\n' "$json"; else printf '=== CREATE ACCOUNT: %s ===\n%s\n' "$status" "$summary"; fi
  if [[ "$STRICT_EXIT" -eq 1 ]]; then
    case "$status" in READY | CREATED | RECREATED) exit 0 ;; BLOCKED) exit 1 ;; ERROR) exit 2 ;; esac
  fi
  exit 0
}

read_secret_password() {
  local encoded
  encoded="$(_kubectl get secret "$PASSWORD_SECRET_NAME" -o "jsonpath={.data['${PASSWORD_SECRET_KEY}']}" 2>/dev/null)" || return 1
  [[ -n "$encoded" ]] || return 1
  printf '%s' "$encoded" | base64 -d
}

validate_inputs
SQL_PLAN_JSON="$(build_sql_plan_json)"
if [[ "${#ERRORS[@]}" -gt 0 ]]; then
  SUMMARY="Invalid create-account request"
  emit_result "$(result_json ERROR INVALID_INPUT "$SUMMARY" "" false "$SQL_PLAN_JSON" "$(errors_json)")" ERROR "$SUMMARY"
fi

if bool_enabled "$DRY_RUN"; then
  SUMMARY="Dry-run ready; no Kubernetes or SQL changes were made"
  emit_result "$(result_json READY DRY_RUN_READY "$SUMMARY" "" false "$SQL_PLAN_JSON")" READY "$SUMMARY"
fi
if ! bool_enabled "$CONFIRM"; then
  SUMMARY="confirm=true is required when dry_run=false"
  emit_result "$(result_json BLOCKED CONFIRM_REQUIRED "$SUMMARY" "" false "$SQL_PLAN_JSON")" BLOCKED "$SUMMARY"
fi

mariadb_set_target "$CONTEXT" "$NAMESPACE" "$RESOURCE" "$MDB" "$CONTAINER"
if ! k8s_check >/dev/null; then
  SUMMARY="kubectl is unavailable or cannot reach the target cluster"
  emit_result "$(result_json ERROR KUBECTL_UNAVAILABLE "$SUMMARY" "" false "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi

_on_ambiguous() {
  local summary="Multiple MariaDB targets in namespace ($1); specify --mdb" candidates
  candidates="$(printf '%s' "$1" | tr ',' '\n' | jq -Rsc 'split("\n")[:-1]')"
  emit_result "$(result_json ERROR MARIADB_AMBIGUOUS "$summary" "" false "$SQL_PLAN_JSON" '[]' null "$candidates")" ERROR "$summary"
}
_on_none() {
  local summary="No MariaDB CR or StatefulSet found in namespace"
  emit_result "$(result_json ERROR MARIADB_NOT_FOUND "$summary" "" false "$SQL_PLAN_JSON")" ERROR "$summary"
}
if [[ -z "$MDB" ]]; then mariadb_autodetect_target true _on_ambiguous _on_none; MDB="$MARIADB_NAME"; fi

CURRENT_PRIMARY="$(mariadb_jsonpath "$RESOURCE" "$MDB" '{.status.currentPrimary}' || true)"
REPLICAS="$(mariadb_cr_replicas || true)"
[[ -n "$REPLICAS" ]] || REPLICAS="$(mariadb_sts_replicas || true)"
mapfile -t PODS < <(mariadb_list_pods "$REPLICAS")
[[ -n "$CURRENT_PRIMARY" || "${#PODS[@]}" -eq 0 ]] || CURRENT_PRIMARY="${PODS[0]}"
if [[ -z "$CURRENT_PRIMARY" ]]; then
  SUMMARY="Cannot determine MariaDB primary pod"
  emit_result "$(result_json ERROR CURRENT_PRIMARY_EMPTY "$SUMMARY" "" false "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi
if ! ROOT_PASSWORD="$(mariadb_read_root_password "$CURRENT_PRIMARY" "${PODS[@]}")"; then
  SUMMARY="Cannot read MariaDB root password from target pods"
  emit_result "$(result_json ERROR ROOT_PASSWORD_UNAVAILABLE "$SUMMARY" "$CURRENT_PRIMARY" false "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi

USER_LITERAL="$(sql_string_literal "$USERNAME")"
HOST_LITERAL="$(sql_string_literal "$ACCOUNT_HOST_VALUE")"
ACCOUNT_REF="${USER_LITERAL}@${HOST_LITERAL}"
if ! ACCOUNT_COUNT="$(mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "SELECT COUNT(*) FROM mysql.user WHERE User=${USER_LITERAL} AND Host=${HOST_LITERAL}")" || [[ ! "$ACCOUNT_COUNT" =~ ^[0-9]+$ ]]; then
  SUMMARY="Failed to check whether MariaDB account already exists"
  emit_result "$(result_json ERROR SQL_FAILED "$SUMMARY" "$CURRENT_PRIMARY" false "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi
ACCOUNT_EXISTS=false
[[ "$ACCOUNT_COUNT" -eq 0 ]] || ACCOUNT_EXISTS=true
if [[ "$ACCOUNT_EXISTS" == true ]] && ! bool_enabled "$ALLOW_EXISTING"; then
  SUMMARY="MariaDB account already exists"
  emit_result "$(result_json ERROR ACCOUNT_ALREADY_EXISTS "$SUMMARY" "$CURRENT_PRIMARY" true "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi

EFFECTIVE_DELIVERY_MODE="$PASSWORD_DELIVERY_MODE"
if [[ -n "$PASSWORD_SECRET_NAME" ]]; then
  export K8S_NAMESPACE="$NAMESPACE"
  if [[ "$PASSWORD_SECRET_NAME" == "$MDB" || "$PASSWORD_SECRET_NAME" == "mariadb" ]] || secrets_is_protected "$PASSWORD_SECRET_NAME"; then
    SUMMARY="Refusing to read a protected Secret as an account password source"
    emit_result "$(result_json ERROR PROTECTED_SECRET "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
  fi
  if ! PASSWORD_VALUE="$(read_secret_password)" || [[ -z "$PASSWORD_VALUE" ]]; then
    SUMMARY="Cannot read password from the caller-provided Secret"
    emit_result "$(result_json ERROR PASSWORD_SECRET_UNAVAILABLE "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
  fi
  EFFECTIVE_DELIVERY_MODE="caller_provided_secret"
else
  if ! PASSWORD_VALUE="$(generate_password 2>/dev/null)"; then
    SUMMARY="Failed to generate a password from the requested policy"
    emit_result "$(result_json ERROR PASSWORD_GENERATION_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
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
    if ! DELIVERY_PAYLOAD="$(encrypt_password_payload "$PASSWORD_VALUE" "$RECIPIENT_PGP_PUBKEY" 2>/dev/null)"; then
      SUMMARY="Failed to encrypt password payload with the recipient public key"
      emit_result "$(result_json ERROR DELIVERY_ENCRYPT_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
    fi
    ;;
esac

PASSWORD_LITERAL="$(sql_string_literal "$PASSWORD_VALUE")"
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
  emit_result "$(result_json ERROR ACCOUNT_MUTATION_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi
MUTATION_APPLIED=true
if [[ -n "$REVOKE_SQL" ]] && ! mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "$REVOKE_SQL" >/dev/null; then
  SUMMARY="Account credential changed but revoking the prior grants failed"
  emit_result "$(result_json ERROR SQL_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi
if ! mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "$GRANT_SQL" >/dev/null; then
  SUMMARY="Account credential changed but applying the requested grant failed"
  emit_result "$(result_json ERROR SQL_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi
if ! SHOW_GRANTS="$(mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "SHOW GRANTS FOR ${ACCOUNT_REF}")"; then
  SUMMARY="Account was changed but SHOW GRANTS verification failed"
  emit_result "$(result_json ERROR SQL_VERIFY_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi
GRANTS_UPPER="$(printf '%s\n' "$SHOW_GRANTS" | tr '[:lower:]' '[:upper:]')"
SCOPE_UPPER="$(printf '%s' " ON ${GRANT_SCOPE} TO" | tr '[:lower:]' '[:upper:]')"
SCOPE_LINE="$(printf '%s\n' "$GRANTS_UPPER" | grep -F "$SCOPE_UPPER" | head -n 1 || true)"
VERIFY_OK=true
[[ -n "$SCOPE_LINE" ]] || VERIFY_OK=false
GRANTED_CLAUSE="${SCOPE_LINE#GRANT }"
GRANTED_CLAUSE="${GRANTED_CLAUSE%% ON *}"
IFS=',' read -r -a GRANTED_PRIVILEGES <<< "$GRANTED_CLAUSE"
for item in "${PRIVILEGES[@]}"; do
  [[ "$item" != ALL ]] || item="ALL PRIVILEGES"
  privilege_found=false
  for granted_item in "${GRANTED_PRIVILEGES[@]}"; do
    if [[ "$(normalize_privilege "$granted_item")" == "$item" ]]; then
      privilege_found=true
      break
    fi
  done
  [[ "$privilege_found" == true ]] || VERIFY_OK=false
done
if [[ "$VERIFY_OK" != true ]]; then
  SUMMARY="SHOW GRANTS did not contain the requested effective grant"
  emit_result "$(result_json ERROR SQL_VERIFY_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON")" ERROR "$SUMMARY"
fi

if [[ "$ACCOUNT_EXISTS" == true ]]; then STATUS="RECREATED"; REASON="ACCOUNT_RECREATED"; SUMMARY="MariaDB account recreated and grants replaced and verified"
else STATUS="CREATED"; REASON="ACCOUNT_CREATED"; SUMMARY="MariaDB account created and grants verified"
fi
emit_result "$(result_json "$STATUS" "$REASON" "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON" '[]' "$DELIVERY_PAYLOAD")" "$STATUS" "$SUMMARY"
