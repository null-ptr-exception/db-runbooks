#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/create-account.sh
# Safely create a MariaDB account and grant scoped database privileges.
#
# AQSH injects inputs as environment variables and reads $AQSH_RESULT_FILE.
# Rundeck/local users can pass the same values as CLI flags.
# =============================================================================

# Capture the caller-supplied target name BEFORE sourcing libs — lib/mariadb.sh
# defaults MARIADB_NAME to "mariadb" at load time. Empty here means auto-detect.
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

usage() {
  cat >&2 <<'EOF'
Usage:
  create-account.sh --namespace <namespace> --database <database> --username <user> --privileges <list> [options]

Required:
  --namespace <namespace>          Kubernetes namespace.
  --database <database>            Database name to grant on. Use * or *.* only with --allow-global true.
  --username <user>                MariaDB username.
  --privileges <list>              Comma-separated privileges, e.g. SELECT,INSERT.

Target options:
  --context <context>              Kubernetes context. Optional for in-cluster AQSH.
  --resource <kind>                MariaDB CR kind. Default: mariadb
  --mdb <name>                     MariaDB CR / StatefulSet name. Default: auto-detected from the namespace.
  --container <name>               MariaDB container name. Default: mariadb
  --host <host>                    MariaDB account host. Default: %

Password options:
  --password-secret-name <name>    Secret used for generated or provided password.
  --password-secret-key <key>      Secret key holding the password. Default: password
  --password-secret-prefix <text>  Required Secret name prefix. Default: mariadb-account-
  --generate-password <bool>       Generate password for new accounts. Default: true

Safety options:
  --dry-run <bool>                 Return redacted SQL plan without changes. Default: true
  --confirm <bool>                 Required true when dry_run=false. Default: false
  --allow-global <bool>            Allow *.* grant scope. Default: false
  --allow-admin-privileges <bool>  Allow broad/admin privileges. Default: false

Output:
  --json                           Print only JSON result to stdout.
  --result-file <path>             Write JSON result to this file.
  --strict-exit                    Exit non-zero on BLOCKED or ERROR.

Environment equivalents:
  DB_NAMESPACE, K8S_CONTEXT, MARIADB_RESOURCE, MARIADB_NAME,
  MARIADB_CONTAINER, ACCOUNT_DATABASE, ACCOUNT_USERNAME, ACCOUNT_HOST,
  ACCOUNT_PRIVILEGES, ACCOUNT_PASSWORD_SECRET_NAME, ACCOUNT_PASSWORD_SECRET_KEY,
  ACCOUNT_PASSWORD_SECRET_PREFIX, GENERATE_PASSWORD, DRY_RUN, CONFIRM, ALLOW_GLOBAL,
  ALLOW_ADMIN_PRIVILEGES, AQSH_RESULT_FILE.
EOF
}

require_value() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo "error: $1 requires a value" >&2
    exit 2
  fi
}

bool_enabled() {
  case "${1:-false}" in
    1 | true | TRUE | yes | YES | on | ON) return 0 ;;
    *) return 1 ;;
  esac
}

json_escape() {
  _escape_json_string "$1"
}

CONTEXT="${K8S_CONTEXT:-${CONTEXT:-}}"
NAMESPACE="${DB_NAMESPACE:-${K8S_NAMESPACE:-}}"
RESOURCE="${MARIADB_RESOURCE:-mariadb}"
# Empty when the caller gave no name → auto-detected from the namespace below.
MDB="$MDB_INPUT"
CONTAINER="${MARIADB_CONTAINER:-mariadb}"
DATABASE="${ACCOUNT_DATABASE:-}"
USERNAME="${ACCOUNT_USERNAME:-}"
ACCOUNT_HOST_VALUE="${ACCOUNT_HOST:-%}"
PRIVILEGES_RAW="${ACCOUNT_PRIVILEGES:-}"
PASSWORD_SECRET_NAME="${ACCOUNT_PASSWORD_SECRET_NAME:-}"
PASSWORD_SECRET_KEY="${ACCOUNT_PASSWORD_SECRET_KEY:-password}"
PASSWORD_SECRET_PREFIX="${ACCOUNT_PASSWORD_SECRET_PREFIX:-mariadb-account-}"
GENERATE_PASSWORD="${GENERATE_PASSWORD:-true}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"
ALLOW_GLOBAL="${ALLOW_GLOBAL:-false}"
ALLOW_ADMIN_PRIVILEGES="${ALLOW_ADMIN_PRIVILEGES:-false}"
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
    --password-secret-name) require_value "$1" "${2:-}"; PASSWORD_SECRET_NAME="$2"; shift 2 ;;
    --password-secret-key) require_value "$1" "${2:-}"; PASSWORD_SECRET_KEY="$2"; shift 2 ;;
    --password-secret-prefix) require_value "$1" "${2:-}"; PASSWORD_SECRET_PREFIX="$2"; shift 2 ;;
    --generate-password) require_value "$1" "${2:-}"; GENERATE_PASSWORD="$2"; shift 2 ;;
    --dry-run) require_value "$1" "${2:-}"; DRY_RUN="$2"; shift 2 ;;
    --confirm) require_value "$1" "${2:-}"; CONFIRM="$2"; shift 2 ;;
    --allow-global) require_value "$1" "${2:-}"; ALLOW_GLOBAL="$2"; shift 2 ;;
    --allow-admin-privileges) require_value "$1" "${2:-}"; ALLOW_ADMIN_PRIVILEGES="$2"; shift 2 ;;
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
PRIVILEGES_JSON=""
GRANT_SCOPE=""

add_error() {
  ERRORS+=("$1")
}

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

contains_unsafe_literal_chars() {
  local value="$1"
  [[ "$value" == *"'"* || "$value" == *'"'* || "$value" == *";"* || "$value" =~ [[:cntrl:]] ]]
}

normalize_privilege() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:lower:]' '[:upper:]')"
  value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')"
  printf '%s' "$value"
}

validate_inputs() {
  [[ -n "$NAMESPACE" ]] || add_error "namespace is required"
  [[ -n "$DATABASE" ]] || add_error "database is required"
  [[ -n "$USERNAME" ]] || add_error "username is required"
  [[ -n "$PRIVILEGES_RAW" ]] || add_error "privileges is required"

  if [[ -n "$NAMESPACE" && ! "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    add_error "namespace must be a valid Kubernetes namespace"
  fi

  if [[ -n "$USERNAME" ]]; then
    if [[ ! "$USERNAME" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      add_error "username may only contain letters, numbers, underscore, dot, and dash"
    fi
    case "$(printf '%s' "$USERNAME" | tr '[:upper:]' '[:lower:]')" in
      root | mysql | mariadb | admin | administrator | system | sys)
        add_error "reserved username is not allowed"
        ;;
    esac
  fi

  if [[ -n "$ACCOUNT_HOST_VALUE" ]] && { contains_unsafe_literal_chars "$ACCOUNT_HOST_VALUE" || [[ "$ACCOUNT_HOST_VALUE" =~ [[:space:]] ]]; }; then
    add_error "host contains unsupported characters"
  fi

  if [[ "$DATABASE" == "*" || "$DATABASE" == "*.*" ]]; then
    bool_enabled "$ALLOW_GLOBAL" || add_error "global database scope requires allow_global=true"
    GRANT_SCOPE="*.*"
  elif [[ -n "$DATABASE" ]]; then
    if [[ ! "$DATABASE" =~ ^[A-Za-z0-9_-]+$ ]]; then
      add_error "database may only contain letters, numbers, underscore, and dash"
    fi
    GRANT_SCOPE="\`${DATABASE}\`.*"
  fi

  if [[ -n "$PASSWORD_SECRET_NAME" && ! "$PASSWORD_SECRET_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    add_error "password_secret_name must be a valid Kubernetes Secret name"
  fi
  if [[ -n "$PASSWORD_SECRET_NAME" && -n "$PASSWORD_SECRET_PREFIX" && "$PASSWORD_SECRET_NAME" != "$PASSWORD_SECRET_PREFIX"* ]]; then
    add_error "password_secret_name must start with ${PASSWORD_SECRET_PREFIX}"
  fi
  if [[ -n "$PASSWORD_SECRET_KEY" && ! "$PASSWORD_SECRET_KEY" =~ ^[A-Za-z0-9._-]+$ ]]; then
    add_error "password_secret_key contains unsupported characters"
  fi

  for bool_var in GENERATE_PASSWORD DRY_RUN CONFIRM ALLOW_GLOBAL ALLOW_ADMIN_PRIVILEGES; do
    if ! is_valid_bool "${!bool_var}"; then
      add_error "${bool_var} must be a boolean-like value"
    fi
  done

  local item normalized
  IFS=',' read -r -a PRIVILEGE_ITEMS <<< "$PRIVILEGES_RAW"
  for item in "${PRIVILEGE_ITEMS[@]}"; do
    normalized="$(normalize_privilege "$item")"
    [[ -z "$normalized" ]] && continue
    if ! is_allowed_privilege "$normalized"; then
      add_error "privilege '${normalized}' is not allowed"
      continue
    fi
    PRIVILEGES+=("$normalized")
  done
  [[ "${#PRIVILEGES[@]}" -gt 0 ]] || add_error "at least one valid privilege is required"

  local sep=""
  local json_sep=""
  for item in "${PRIVILEGES[@]}"; do
    PRIVILEGES_SQL="${PRIVILEGES_SQL}${sep}${item}"
    PRIVILEGES_JSON="${PRIVILEGES_JSON}${json_sep}\"$(json_escape "$item")\""
    sep=", "
    json_sep=","
  done
}

sql_string_literal() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

build_sql_plan_json() {
  local create_stmt grant_stmt flush_stmt show_stmt
  create_stmt="CREATE USER IF NOT EXISTS $(sql_string_literal "$USERNAME")@$(sql_string_literal "$ACCOUNT_HOST_VALUE") IDENTIFIED BY '<redacted>'"
  grant_stmt="GRANT ${PRIVILEGES_SQL} ON ${GRANT_SCOPE} TO $(sql_string_literal "$USERNAME")@$(sql_string_literal "$ACCOUNT_HOST_VALUE")"
  flush_stmt="FLUSH PRIVILEGES"
  show_stmt="SHOW GRANTS FOR $(sql_string_literal "$USERNAME")@$(sql_string_literal "$ACCOUNT_HOST_VALUE")"
  printf '["%s","%s","%s","%s"]' \
    "$(json_escape "$create_stmt")" \
    "$(json_escape "$grant_stmt")" \
    "$(json_escape "$flush_stmt")" \
    "$(json_escape "$show_stmt")"
}

result_json() {
  local status="$1"
  local reason_code="$2"
  local summary="$3"
  local primary="${4:-}"
  local existing="${5:-false}"
  local sql_plan_json="${6:-[]}"
  local error_json="${7:-[]}"
  local secret_managed="${8:-false}"

  printf '{"status":"%s","reason_code":"%s","summary":"%s","target":{"context":"%s","namespace":"%s","resource":"%s","mdb":"%s"},"database":"%s","username":"%s","host":"%s","privileges":[%s],"primary":"%s","dry_run":%s,"account_exists":%s,"password_secret":{"name":"%s","key":"%s","managed":%s},"sql_plan":%s,"errors":%s}\n' \
    "$status" \
    "$(json_escape "$reason_code")" \
    "$(json_escape "$summary")" \
    "$(json_escape "${CONTEXT:-}")" \
    "$(json_escape "$NAMESPACE")" \
    "$(json_escape "$RESOURCE")" \
    "$(json_escape "$MDB")" \
    "$(json_escape "$DATABASE")" \
    "$(json_escape "$USERNAME")" \
    "$(json_escape "$ACCOUNT_HOST_VALUE")" \
    "$PRIVILEGES_JSON" \
    "$(json_escape "$primary")" \
    "$(bool_enabled "$DRY_RUN" && printf true || printf false)" \
    "$existing" \
    "$(json_escape "$PASSWORD_SECRET_NAME")" \
    "$(json_escape "$PASSWORD_SECRET_KEY")" \
    "$secret_managed" \
    "$sql_plan_json" \
    "$error_json"
}

errors_json() {
  local out="" sep="" item
  for item in "${ERRORS[@]}"; do
    out="${out}${sep}\"$(json_escape "$item")\""
    sep=","
  done
  printf '[%s]' "$out"
}

emit_result() {
  local json="$1"
  local status_value="$2"
  local summary="$3"

  if [[ -n "$RESULT_FILE" ]]; then
    printf '%s' "$json" > "$RESULT_FILE"
  fi

  if [[ "$JSON_ONLY" -eq 1 || -z "$RESULT_FILE" ]]; then
    printf '%s' "$json"
  else
    echo "=== CREATE ACCOUNT: ${status_value} ==="
    echo "$summary"
  fi

  if [[ "$STRICT_EXIT" -eq 1 ]]; then
    case "$status_value" in
      READY | CREATED | UNCHANGED) exit 0 ;;
      BLOCKED) exit 1 ;;
      ERROR) exit 2 ;;
    esac
  fi
  exit 0
}

read_secret_password() {
  local encoded
  encoded=$(_kubectl get secret "$PASSWORD_SECRET_NAME" -o "jsonpath={.data.${PASSWORD_SECRET_KEY}}" 2>/dev/null) || return 1
  [[ -n "$encoded" ]] || return 1
  printf '%s' "$encoded" | base64 -d
}

generate_password() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
}

create_password_secret() {
  local password="$1"
  _kubectl create secret generic "$PASSWORD_SECRET_NAME" \
    "--from-literal=${PASSWORD_SECRET_KEY}=${password}" >/dev/null
}

validate_inputs
SQL_PLAN_JSON="$(build_sql_plan_json)"

if [[ "${#ERRORS[@]}" -gt 0 ]]; then
  SUMMARY="Invalid create-account request"
  RESULT_JSON="$(result_json ERROR INVALID_INPUT "$SUMMARY" "" false "$SQL_PLAN_JSON" "$(errors_json)" false)"
  emit_result "$RESULT_JSON" ERROR "$SUMMARY"
fi

if bool_enabled "$DRY_RUN"; then
  SUMMARY="Dry-run ready; no Kubernetes or SQL changes were made"
  RESULT_JSON="$(result_json READY DRY_RUN_READY "$SUMMARY" "" false "$SQL_PLAN_JSON" "[]" false)"
  emit_result "$RESULT_JSON" READY "$SUMMARY"
fi

if ! bool_enabled "$CONFIRM"; then
  SUMMARY="confirm=true is required when dry_run=false"
  RESULT_JSON="$(result_json BLOCKED CONFIRM_REQUIRED "$SUMMARY" "" false "$SQL_PLAN_JSON" "[]" false)"
  emit_result "$RESULT_JSON" BLOCKED "$SUMMARY"
fi

mariadb_set_target "$CONTEXT" "$NAMESPACE" "$RESOURCE" "$MDB" "$CONTAINER"

if ! k8s_check >/dev/null; then
  SUMMARY="kubectl is unavailable or cannot reach the target cluster"
  RESULT_JSON="$(result_json ERROR KUBECTL_UNAVAILABLE "$SUMMARY" "" false "$SQL_PLAN_JSON" "[]" false)"
  emit_result "$RESULT_JSON" ERROR "$SUMMARY"
fi

# Auto-detect the target when --mdb / MARIADB_NAME was not supplied (CR first,
# then StatefulSet). None or several → a structured error rather than a guess.
if [[ -z "$MDB" ]]; then
  resolve_rc=0
  resolved=$(mariadb_resolve_name true) || resolve_rc=$?
  if [[ "$resolve_rc" -eq 0 ]]; then
    MDB="$resolved"
    MARIADB_NAME="$MDB"
  elif [[ "$resolve_rc" -eq 2 ]]; then
    SUMMARY="Multiple MariaDB targets in namespace (${resolved}); specify --mdb"
    RESULT_JSON="$(result_json ERROR MARIADB_AMBIGUOUS "$SUMMARY" "" false "$SQL_PLAN_JSON" "[]" false)"
    emit_result "$RESULT_JSON" ERROR "$SUMMARY"
  else
    SUMMARY="No MariaDB CR or StatefulSet found in namespace"
    RESULT_JSON="$(result_json ERROR MARIADB_NOT_FOUND "$SUMMARY" "" false "$SQL_PLAN_JSON" "[]" false)"
    emit_result "$RESULT_JSON" ERROR "$SUMMARY"
  fi
fi

CURRENT_PRIMARY="$(mariadb_jsonpath "$RESOURCE" "$MDB" '{.status.currentPrimary}' || true)"
REPLICAS="$(mariadb_cr_replicas || true)"
if [[ -z "$REPLICAS" ]]; then
  REPLICAS="$(mariadb_sts_replicas || true)"
fi
mapfile -t PODS < <(mariadb_list_pods "$REPLICAS")
if [[ -z "$CURRENT_PRIMARY" && "${#PODS[@]}" -gt 0 ]]; then
  CURRENT_PRIMARY="${PODS[0]}"
fi
if [[ -z "$CURRENT_PRIMARY" ]]; then
  SUMMARY="Cannot determine MariaDB primary pod"
  RESULT_JSON="$(result_json ERROR CURRENT_PRIMARY_EMPTY "$SUMMARY" "" false "$SQL_PLAN_JSON" "[]" false)"
  emit_result "$RESULT_JSON" ERROR "$SUMMARY"
fi

if ! ROOT_PASSWORD="$(mariadb_read_root_password "$CURRENT_PRIMARY" "${PODS[@]}")"; then
  SUMMARY="Cannot read MariaDB root password from target pods"
  RESULT_JSON="$(result_json ERROR ROOT_PASSWORD_UNAVAILABLE "$SUMMARY" "$CURRENT_PRIMARY" false "$SQL_PLAN_JSON" "[]" false)"
  emit_result "$RESULT_JSON" ERROR "$SUMMARY"
fi

USER_LITERAL="$(sql_string_literal "$USERNAME")"
HOST_LITERAL="$(sql_string_literal "$ACCOUNT_HOST_VALUE")"
if ! ACCOUNT_COUNT="$(mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "SELECT COUNT(*) FROM mysql.user WHERE User=${USER_LITERAL} AND Host=${HOST_LITERAL}")"; then
  SUMMARY="Failed to check whether MariaDB account already exists"
  RESULT_JSON="$(result_json ERROR SQL_FAILED "$SUMMARY" "$CURRENT_PRIMARY" false "$SQL_PLAN_JSON" "[]" false)"
  emit_result "$RESULT_JSON" ERROR "$SUMMARY"
fi
if [[ ! "$ACCOUNT_COUNT" =~ ^[0-9]+$ ]]; then
  SUMMARY="MariaDB account existence check returned an unexpected result"
  RESULT_JSON="$(result_json ERROR SQL_FAILED "$SUMMARY" "$CURRENT_PRIMARY" false "$SQL_PLAN_JSON" "[]" false)"
  emit_result "$RESULT_JSON" ERROR "$SUMMARY"
fi
if [[ "$ACCOUNT_COUNT" -gt 0 ]]; then
  ACCOUNT_EXISTS=true
else
  ACCOUNT_EXISTS=false
fi

if [[ "$ACCOUNT_EXISTS" == "true" ]]; then
  SUMMARY="MariaDB account already exists; no password Secret or grants were changed"
  RESULT_JSON="$(result_json UNCHANGED ACCOUNT_EXISTS "$SUMMARY" "$CURRENT_PRIMARY" true "$SQL_PLAN_JSON" "[]" false)"
  emit_result "$RESULT_JSON" UNCHANGED "$SUMMARY"
fi

PASSWORD_VALUE=""
SECRET_MANAGED=false
if [[ -z "$PASSWORD_SECRET_NAME" ]]; then
  SUMMARY="password_secret_name is required when creating a new account"
  RESULT_JSON="$(result_json BLOCKED PASSWORD_SECRET_REQUIRED "$SUMMARY" "$CURRENT_PRIMARY" false "$SQL_PLAN_JSON" "[]" false)"
  emit_result "$RESULT_JSON" BLOCKED "$SUMMARY"
fi

if bool_enabled "$GENERATE_PASSWORD"; then
  PASSWORD_VALUE="$(generate_password)"
  if create_password_secret "$PASSWORD_VALUE" 2>/dev/null; then
    SECRET_MANAGED=true
  else
    # A concurrent run may have created the Secret first; reuse it instead of overwriting it.
    if ! PASSWORD_VALUE="$(read_secret_password)"; then
      SUMMARY="Failed to create password Secret"
      RESULT_JSON="$(result_json ERROR PASSWORD_SECRET_WRITE_FAILED "$SUMMARY" "$CURRENT_PRIMARY" false "$SQL_PLAN_JSON" "[]" false)"
      emit_result "$RESULT_JSON" ERROR "$SUMMARY"
    fi
    SECRET_MANAGED=false
  fi
fi
if ! bool_enabled "$GENERATE_PASSWORD"; then
  if ! PASSWORD_VALUE="$(read_secret_password)"; then
    SUMMARY="Failed to read password Secret"
    RESULT_JSON="$(result_json BLOCKED PASSWORD_SECRET_UNAVAILABLE "$SUMMARY" "$CURRENT_PRIMARY" false "$SQL_PLAN_JSON" "[]" false)"
    emit_result "$RESULT_JSON" BLOCKED "$SUMMARY"
  fi
fi
if contains_unsafe_literal_chars "$PASSWORD_VALUE"; then
  SUMMARY="Password Secret value contains unsupported characters"
  RESULT_JSON="$(result_json BLOCKED PASSWORD_SECRET_INVALID "$SUMMARY" "$CURRENT_PRIMARY" false "$SQL_PLAN_JSON" "[]" false)"
  emit_result "$RESULT_JSON" BLOCKED "$SUMMARY"
fi

PASSWORD_LITERAL="$(sql_string_literal "$PASSWORD_VALUE")"
CREATE_SQL="CREATE USER IF NOT EXISTS ${USER_LITERAL}@${HOST_LITERAL} IDENTIFIED BY ${PASSWORD_LITERAL};"
GRANT_SQL="GRANT ${PRIVILEGES_SQL} ON ${GRANT_SCOPE} TO ${USER_LITERAL}@${HOST_LITERAL}; FLUSH PRIVILEGES;"

if ! mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "$CREATE_SQL" >/dev/null; then
  SUMMARY="Failed to create MariaDB account"
  RESULT_JSON="$(result_json ERROR SQL_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON" "[]" "$SECRET_MANAGED")"
  emit_result "$RESULT_JSON" ERROR "$SUMMARY"
fi
if ! mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "$GRANT_SQL" >/dev/null; then
  SUMMARY="Failed to grant MariaDB privileges"
  RESULT_JSON="$(result_json ERROR SQL_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON" "[]" "$SECRET_MANAGED")"
  emit_result "$RESULT_JSON" ERROR "$SUMMARY"
fi
if ! mariadb_sql "$CURRENT_PRIMARY" "$ROOT_PASSWORD" "SHOW GRANTS FOR ${USER_LITERAL}@${HOST_LITERAL}" >/dev/null; then
  SUMMARY="Account was changed but SHOW GRANTS verification failed"
  RESULT_JSON="$(result_json ERROR SQL_VERIFY_FAILED "$SUMMARY" "$CURRENT_PRIMARY" "$ACCOUNT_EXISTS" "$SQL_PLAN_JSON" "[]" "$SECRET_MANAGED")"
  emit_result "$RESULT_JSON" ERROR "$SUMMARY"
fi

SUMMARY="MariaDB account created and grants verified"
RESULT_JSON="$(result_json CREATED ACCOUNT_CREATED "$SUMMARY" "$CURRENT_PRIMARY" false "$SQL_PLAN_JSON" "[]" "$SECRET_MANAGED")"
emit_result "$RESULT_JSON" CREATED "$SUMMARY"
