#!/usr/bin/env bash

# MariaDB create-account helpers. The caller owns request state in the globals
# referenced below and must source logging/response/k8s/mariadb,
# mongodb-account (password delivery), and secrets before this file.

mariadb_account_encrypt_password_payload() {
  local status=0
  encrypt_password_payload "$@" || status=$?
  trap - RETURN EXIT
  unset GNUPGHOME
  return "$status"
}

mariadb_account_add_error() { ERRORS+=("$1"); }

mariadb_account_is_valid_bool() {
  case "${1:-}" in
    1 | 0 | true | false | TRUE | FALSE | yes | no | YES | NO | on | off | ON | OFF) return 0 ;;
    *) return 1 ;;
  esac
}

mariadb_account_is_admin_privilege() {
  case "$1" in
    ALL | "ALL PRIVILEGES" | SUPER | FILE | PROCESS | RELOAD | SHUTDOWN | "GRANT OPTION") return 0 ;;
    *) return 1 ;;
  esac
}

mariadb_account_is_allowed_privilege() {
  case "$1" in
    SELECT | INSERT | UPDATE | DELETE | CREATE | ALTER | INDEX | EXECUTE | "SHOW VIEW") return 0 ;;
    *) mariadb_account_is_admin_privilege "$1" && bool_enabled "$ALLOW_ADMIN_PRIVILEGES" ;;
  esac
}

mariadb_account_normalize_privilege() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' |
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g'
}

mariadb_account_contains_control_chars() {
  [[ "$1" =~ [[:cntrl:]] ]]
}

mariadb_account_validate_inputs() {
  [[ -n "$NAMESPACE" ]] || mariadb_account_add_error "namespace is required"
  [[ -n "$USERNAME" ]] || mariadb_account_add_error "username is required"
  [[ -n "$PRIVILEGES_RAW" ]] || mariadb_account_add_error "privileges is required"

  if [[ -n "$NAMESPACE" && ! "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    mariadb_account_add_error "namespace must be a valid Kubernetes namespace"
  fi
  if [[ -n "$USERNAME" ]]; then
    [[ "$USERNAME" =~ ^[A-Za-z0-9_.-]+$ ]] || mariadb_account_add_error "username may only contain letters, numbers, underscore, dot, and dash"
    case "$(printf '%s' "$USERNAME" | tr '[:upper:]' '[:lower:]')" in
      root | mysql | mariadb | admin | administrator | system | sys) mariadb_account_add_error "reserved username is not allowed" ;;
    esac
  fi
  if [[ -n "$ACCOUNT_HOST_VALUE" ]] && { mariadb_account_contains_control_chars "$ACCOUNT_HOST_VALUE" || [[ "$ACCOUNT_HOST_VALUE" == *"'"* ]]; }; then
    mariadb_account_add_error "host contains unsupported characters"
  fi

  if [[ -z "$DATABASE" ]]; then
    SCOPE_KIND="all_databases_read_only"
    GRANT_SCOPE="*.*"
  elif [[ "$DATABASE" == "*" || "$DATABASE" == "*.*" ]]; then
    mariadb_account_add_error "omit database to request the all-database read-only scope"
  elif [[ ! "$DATABASE" =~ ^[A-Za-z0-9_-]+$ ]]; then
    mariadb_account_add_error "database may only contain letters, numbers, underscore, and dash"
  else
    SCOPE_KIND="database"
    GRANT_SCOPE="\`${DATABASE}\`.*"
  fi

  local item normalized sep=""
  local -a privilege_items=()
  IFS=',' read -r -a privilege_items <<< "$PRIVILEGES_RAW"
  for item in "${privilege_items[@]}"; do
    normalized="$(mariadb_account_normalize_privilege "$item")"
    [[ -z "$normalized" ]] && continue
    if ! mariadb_account_is_allowed_privilege "$normalized"; then
      mariadb_account_add_error "privilege '${normalized}' is not allowed"
      continue
    fi
    PRIVILEGES+=("$normalized")
  done
  [[ "${#PRIVILEGES[@]}" -gt 0 ]] || mariadb_account_add_error "at least one valid privilege is required"
  if [[ -z "$DATABASE" && ( "${#PRIVILEGES[@]}" -ne 1 || "${PRIVILEGES[0]:-}" != "SELECT" ) ]]; then
    mariadb_account_add_error "all-database scope permits exactly SELECT"
  fi
  for item in "${PRIVILEGES[@]}"; do
    PRIVILEGES_SQL="${PRIVILEGES_SQL}${sep}${item}"
    sep=", "
  done

  local bool_var
  for bool_var in ALLOW_EXISTING ALLOW_ADMIN_PRIVILEGES DRY_RUN CONFIRM; do
    mariadb_account_is_valid_bool "${!bool_var}" || mariadb_account_add_error "${bool_var} must be a boolean-like value"
  done

  [[ "$PASSWORD_LENGTH" =~ ^[0-9]+$ ]] || mariadb_account_add_error "password_length must be an integer"
  if [[ "$PASSWORD_LENGTH" =~ ^[0-9]+$ && "$PASSWORD_LENGTH" -lt 12 ]]; then
    mariadb_account_add_error "password_length must be at least 12"
  fi
  [[ "$PASSWORD_SPECIAL_MAX" =~ ^[0-9]+$ ]] || mariadb_account_add_error "password_special_max must be a non-negative integer"
  if [[ "$PASSWORD_SPECIAL_CHARS" == *"'"* || "$PASSWORD_SPECIAL_CHARS" == *'"'* || "$PASSWORD_SPECIAL_CHARS" == *\\* || "$PASSWORD_SPECIAL_CHARS" =~ [[:space:]] ]]; then
    mariadb_account_add_error "password_special_chars contains unsupported characters"
  fi
  case "$PASSWORD_DELIVERY_MODE" in
    one_time_plaintext | encrypted_payload) ;;
    *) mariadb_account_add_error "unsupported password_delivery_mode" ;;
  esac
  if [[ "$PASSWORD_DELIVERY_MODE" == "encrypted_payload" && -z "$RECIPIENT_PGP_PUBKEY" ]]; then
    mariadb_account_add_error "recipient_pgp_pubkey is required when password_delivery_mode=encrypted_payload"
  fi

  if [[ -n "$PASSWORD_SECRET_NAME" ]]; then
    [[ "$PASSWORD_SECRET_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || mariadb_account_add_error "password_secret_name must be a valid Kubernetes Secret name"
    [[ "$PASSWORD_SECRET_KEY" =~ ^[A-Za-z0-9._-]+$ ]] || mariadb_account_add_error "password_secret_key contains unsupported characters"
    if [[ "$PASSWORD_DELIVERY_MODE" != "one_time_plaintext" || -n "$RECIPIENT_PGP_PUBKEY" ]]; then
      mariadb_account_add_error "password_delivery_mode/recipient_pgp_pubkey are not applicable when password_secret_name is set"
    fi
  fi

  case "$PASSWORD_EXPIRE_MODE" in
    first_login) EXPIRY_SQL="PASSWORD EXPIRE" ;;
    interval)
      EXPIRY_SQL="PASSWORD EXPIRE INTERVAL ${VALIDITY_DAYS} DAY"
      if [[ ! "$VALIDITY_DAYS" =~ ^[1-9][0-9]*$ ]]; then
        mariadb_account_add_error "validity_days must be a positive integer when password_expire_mode=interval"
      fi
      ;;
    never) EXPIRY_SQL="PASSWORD EXPIRE NEVER" ;;
    default) EXPIRY_SQL="PASSWORD EXPIRE DEFAULT" ;;
    *) mariadb_account_add_error "unsupported password_expire_mode" ;;
  esac
  if [[ "$PASSWORD_EXPIRE_MODE" != "interval" && -n "$VALIDITY_DAYS" ]]; then
    mariadb_account_add_error "validity_days is only valid when password_expire_mode=interval"
  fi
}

mariadb_account_sql_string_literal() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

mariadb_account_build_sql_plan_json() {
  local account create_stmt grant_stmt
  account="$(mariadb_account_sql_string_literal "$USERNAME")@$(mariadb_account_sql_string_literal "$ACCOUNT_HOST_VALUE")"
  create_stmt="CREATE USER ${account} IDENTIFIED BY '<redacted>' ${EXPIRY_SQL}"
  grant_stmt="GRANT ${PRIVILEGES_SQL} ON ${GRANT_SCOPE} TO ${account}"
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

mariadb_account_errors_json() {
  if [[ "${#ERRORS[@]}" -eq 0 ]]; then
    printf '[]'
  else
    printf '%s\n' "${ERRORS[@]}" | jq -Rsc 'split("\n")[:-1]'
  fi
}

mariadb_account_result_json() {
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

mariadb_account_emit_result() {
  local json="$1" status="$2" summary="$3"
  [[ -z "$RESULT_FILE" ]] || printf '%s\n' "$json" > "$RESULT_FILE"
  if [[ "$JSON_ONLY" -eq 1 || -z "$RESULT_FILE" ]]; then printf '%s\n' "$json"; else printf '=== CREATE ACCOUNT: %s ===\n%s\n' "$status" "$summary"; fi
  if [[ "$STRICT_EXIT" -eq 1 ]]; then
    case "$status" in READY | CREATED | RECREATED) exit 0 ;; BLOCKED) exit 1 ;; ERROR) exit 2 ;; esac
  fi
  exit 0
}

mariadb_account_read_secret_password() {
  local encoded
  encoded="$(_kubectl get secret "$PASSWORD_SECRET_NAME" -o "jsonpath={.data['${PASSWORD_SECRET_KEY}']}" 2>/dev/null)" || return 1
  [[ -n "$encoded" ]] || return 1
  printf '%s' "$encoded" | base64 -d
}

mariadb_account_grants_match() {
  local show_grants="$1" grants_upper scope_upper scope_line granted_clause item granted_item
  local privilege_found
  local -a granted_privileges=()
  grants_upper="$(printf '%s\n' "$show_grants" | tr '[:lower:]' '[:upper:]')"
  scope_upper="$(printf '%s' " ON ${GRANT_SCOPE} TO" | tr '[:lower:]' '[:upper:]')"
  scope_line="$(printf '%s\n' "$grants_upper" | grep -F "$scope_upper" | head -n 1 || true)"
  [[ -n "$scope_line" ]] || return 1
  granted_clause="${scope_line#GRANT }"
  granted_clause="${granted_clause%% ON *}"
  IFS=',' read -r -a granted_privileges <<< "$granted_clause"
  for item in "${PRIVILEGES[@]}"; do
    [[ "$item" != ALL ]] || item="ALL PRIVILEGES"
    privilege_found=false
    for granted_item in "${granted_privileges[@]}"; do
      if [[ "$(mariadb_account_normalize_privilege "$granted_item")" == "$item" ]]; then
        privilege_found=true
        break
      fi
    done
    [[ "$privilege_found" == true ]] || return 1
  done
}
