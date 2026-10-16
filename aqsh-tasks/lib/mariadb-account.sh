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

# SQL grammar remains fixed even when deployment profiles change.
mariadb_account_is_database_privilege() {
  case "$1" in
    SELECT | INSERT | UPDATE | DELETE | CREATE | DROP | REFERENCES | INDEX | ALTER | \
    "CREATE TEMPORARY TABLES" | "LOCK TABLES" | EXECUTE | "CREATE VIEW" | "SHOW VIEW" | \
    "CREATE ROUTINE" | "ALTER ROUTINE" | EVENT | TRIGGER | "DELETE HISTORY" | "SHOW CREATE ROUTINE") return 0 ;;
    *) return 1 ;;
  esac
}

mariadb_account_is_global_privilege() {
  mariadb_account_is_database_privilege "$1" && return 0
  case "$1" in
    "CREATE USER" | FILE | PROCESS | RELOAD | SHUTDOWN | SUPER | "SHOW DATABASES" | \
    "REPLICATION SLAVE" | "REPLICATION CLIENT" | "BINLOG MONITOR" | "SLAVE MONITOR" | \
    "BINLOG ADMIN" | "BINLOG REPLAY" | "CONNECTION ADMIN" | "CREATE TABLESPACE" | \
    "FEDERATED ADMIN" | "READ ONLY ADMIN" | "REPLICATION MASTER ADMIN" | \
    "REPLICATION SLAVE ADMIN" | "SET USER") return 0 ;;
    *) return 1 ;;
  esac
}

mariadb_account_add_grant() {
  local scope="$1" raw="$2" item normalized sql="" sep=""
  local -a items=() names=()
  [[ -n "$raw" ]] || return 0
  IFS=',' read -r -a items <<< "$raw"
  for item in "${items[@]}"; do
    normalized="$(mariadb_account_normalize_privilege "$item")"
    [[ "$normalized" != USAGE ]] || continue
    if [[ "$normalized" != "GRANT OPTION" ]] && { ! mariadb_account_is_global_privilege "$normalized" || { [[ "$scope" != '*.*' ]] && ! mariadb_account_is_database_privilege "$normalized"; }; }; then
      mariadb_account_add_error "profile privilege '${normalized}' is not valid for ${scope}"
      continue
    fi
    # Repeating a privilege is harmless, but keep plans/results deterministic.
    if [[ ",${sql//, /,}," == *",${normalized},"* ]]; then continue; fi
    names+=("$normalized")
    PRIVILEGES+=("$normalized")
    sql="${sql}${sep}${normalized}"; sep=", "
  done
  [[ "${#names[@]}" -gt 0 ]] || return 0
  GRANT_SCOPES+=("$scope")
  GRANT_PRIVILEGES_SQL+=("$sql")
  GRANT_OBJECTS+=("$(printf '%s\n' "${names[@]}" | jq -Rsc --arg scope "$scope" '{scope:$scope,privileges:split("\n")[:-1]}')")
}

mariadb_account_resolve_profile() {
  local database_privileges="" global_privileges="" protected username_lower
  local admin_default='SELECT,INSERT,UPDATE,DELETE,CREATE,DROP,REFERENCES,INDEX,ALTER,CREATE TEMPORARY TABLES,LOCK TABLES,EXECUTE,CREATE VIEW,SHOW VIEW,CREATE ROUTINE,ALTER ROUTINE,EVENT,TRIGGER,DELETE HISTORY'
  case "$ACCOUNT_TYPE" in
    admin)
      database_privileges="${MARIADB_ACCOUNT_ADMIN_DATABASE_PRIVILEGES_DEFAULT-$admin_default}"
      global_privileges="${MARIADB_ACCOUNT_ADMIN_GLOBAL_PRIVILEGES_DEFAULT-}"
      ;;
    ro)
      database_privileges="${MARIADB_ACCOUNT_RO_DATABASE_PRIVILEGES_DEFAULT-SELECT}"
      global_privileges="${MARIADB_ACCOUNT_RO_GLOBAL_PRIVILEGES_DEFAULT-}"
      ;;
    monitor)
      database_privileges="${MARIADB_ACCOUNT_MONITOR_DATABASE_PRIVILEGES_DEFAULT-}"
      global_privileges="${MARIADB_ACCOUNT_MONITOR_GLOBAL_PRIVILEGES_DEFAULT-PROCESS,BINLOG MONITOR,SLAVE MONITOR}"
      ;;
    none) ;;
    *) mariadb_account_add_error "account_type must be admin, ro, monitor, or none"; return ;;
  esac
  username_lower="$(printf '%s' "$USERNAME" | tr '[:upper:]' '[:lower:]')"
  protected="root,mysql,mariadb.sys,${MARIADB_ACCOUNT_PROTECTED_USERS_DEFAULT-mariadb,system,sys}"
  protected="$(printf '%s' "$protected" | tr ', ' '\n' | tr '[:upper:]' '[:lower:]')"
  if printf '%s\n' "$protected" | grep -Fxq "$username_lower"; then
    mariadb_account_add_error "protected username is not allowed"
  fi
  if [[ -n "$database_privileges" ]]; then
    if [[ -z "$DATABASE" ]]; then
      mariadb_account_add_error "database is required by the selected account profile"
    elif [[ "$DATABASE" =~ ^[A-Za-z0-9_-]+$ ]]; then
      # Escape database wildcards: backticks alone do not make '_' literal in GRANT.
      local escaped_database="${DATABASE//_/\\_}"
      mariadb_account_add_grant "\`${escaped_database}\`.*" "$database_privileges"
    fi
  elif [[ -n "$DATABASE" ]]; then
    mariadb_account_add_error "database is not used by the selected account profile"
  fi
  mariadb_account_add_grant '*.*' "$global_privileges"
  if [[ "${#GRANT_SCOPES[@]}" -eq 0 ]]; then
    SCOPE_KIND=none; GRANT_SCOPE='*.*'; PRIVILEGES=(USAGE)
    GRANTS_JSON='[{"scope":"*.*","privileges":["USAGE"]}]'
  else
    GRANTS_JSON="$(printf '%s\n' "${GRANT_OBJECTS[@]}" | jq -sc '.')"
    GRANT_SCOPE="${GRANT_SCOPES[0]}"
    if [[ "${#GRANT_SCOPES[@]}" -gt 1 ]]; then SCOPE_KIND=mixed; GRANT_SCOPE=""
    elif [[ "$GRANT_SCOPE" == '*.*' ]]; then SCOPE_KIND=global
    else SCOPE_KIND=database; fi
  fi
}

mariadb_account_grant_statements() {
  local account="$1" i sql suffix
  for i in "${!GRANT_SCOPES[@]}"; do
    sql="${GRANT_PRIVILEGES_SQL[$i]}"; suffix=""
    if [[ ",${sql}," == *"GRANT OPTION"* ]]; then
      suffix=' WITH GRANT OPTION'
      sql="$(printf '%s' "$sql" | sed -E 's/(^|, )GRANT OPTION(, |$)/\1/; s/, $//')"
      [[ -n "$sql" ]] || sql=USAGE
    fi
    printf 'GRANT %s ON %s TO %s%s\n' "$sql" "${GRANT_SCOPES[$i]}" "$account" "$suffix"
  done
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

  if [[ -n "$NAMESPACE" && ! "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    mariadb_account_add_error "namespace must be a valid Kubernetes namespace"
  fi
  if [[ -n "$USERNAME" ]]; then
    [[ "$USERNAME" =~ ^[A-Za-z0-9_.-]+$ ]] || mariadb_account_add_error "username may only contain letters, numbers, underscore, dot, and dash"
  fi
  if [[ -n "$ACCOUNT_HOST_VALUE" ]] && { mariadb_account_contains_control_chars "$ACCOUNT_HOST_VALUE" || [[ "$ACCOUNT_HOST_VALUE" == *"'"* ]]; }; then
    mariadb_account_add_error "host contains unsupported characters"
  fi

  if [[ -n "$DATABASE" && ! "$DATABASE" =~ ^[A-Za-z0-9_-]+$ ]]; then
    mariadb_account_add_error "database may only contain letters, numbers, underscore, and dash; global scope is deployment policy"
  fi
  mariadb_account_resolve_profile
  case "$IF_EXISTS" in
    error | skip | recreate) ;;
    *) mariadb_account_add_error "if_exists must be error, skip, or recreate" ;;
  esac
  if [[ -n "${ACCOUNT_PRIVILEGES+x}${ALLOW_ADMIN_PRIVILEGES+x}${ALLOW_GLOBAL+x}${ALLOW_EXISTING+x}" ]]; then
    mariadb_account_add_error "legacy privileges/allow_admin_privileges/allow_global/allow_existing inputs are unsupported; use account_type and if_exists"
  fi

  local bool_var
  for bool_var in DRY_RUN CONFIRM; do
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
  local account
  account="$(mariadb_account_sql_string_literal "$USERNAME")@$(mariadb_account_sql_string_literal "$ACCOUNT_HOST_VALUE")"
  {
    if [[ "$IF_EXISTS" == recreate && "${ACCOUNT_EXISTS:-true}" == true ]]; then
      printf "ALTER USER %s IDENTIFIED BY '<redacted>' %s\n" "$account" "$EXPIRY_SQL"
      printf 'REVOKE ALL PRIVILEGES, GRANT OPTION FROM %s\n' "$account"
    else
      printf "CREATE USER %s IDENTIFIED BY '<redacted>' %s\n" "$account" "$EXPIRY_SQL"
    fi
    mariadb_account_grant_statements "$account"
    printf 'SHOW GRANTS FOR %s\n' "$account"
  } | jq -Rsc 'split("\n")[:-1]'
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
    --arg account_type "$ACCOUNT_TYPE" --arg if_exists "$IF_EXISTS" --argjson grants "$GRANTS_JSON" \
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
      account_type:$account_type,if_exists:$if_exists,grants:$grants,privileges:$privileges,password_expire_mode:$password_expire_mode,
      validity_days:(if $validity_days == "" then null else (try ($validity_days|tonumber) catch $validity_days) end),
      primary:$primary,dry_run:$dry_run,account_exists:$account_exists,
      mutation_applied:$mutation_applied,
      delivery_payload:$delivery_payload,sql_plan:$sql_plan,errors:$errors,candidates:$candidates}'
}

mariadb_account_emit_result() {
  local json="$1" status="$2" summary="$3"
  [[ -z "$RESULT_FILE" ]] || printf '%s\n' "$json" > "$RESULT_FILE"
  if [[ "$JSON_ONLY" -eq 1 || -z "$RESULT_FILE" ]]; then printf '%s\n' "$json"; else printf '=== CREATE ACCOUNT: %s ===\n%s\n' "$status" "$summary"; fi
  case "$status" in
    READY | CREATED | RECREATED | SKIPPED) exit 0 ;;
    BLOCKED) exit 1 ;;
    *) exit 2 ;;
  esac
}

mariadb_account_read_secret_password() {
  local secret_json encoded
  secret_json="$(_kubectl get secret "$PASSWORD_SECRET_NAME" -o json 2>/dev/null)" || return 1
  encoded="$(printf '%s' "$secret_json" | jq -er --arg key "$PASSWORD_SECRET_KEY" '.data[$key] | select(type == "string" and length > 0)')" || return 1
  printf '%s' "$encoded" | base64 -d
}

mariadb_account_canonical_privilege() {
  local value
  value="$(mariadb_account_normalize_privilege "$1")"
  [[ "$value" != "REPLICATION CLIENT" ]] || value="BINLOG MONITOR"
  printf '%s' "$value"
}

mariadb_account_validate_server_privileges() {
  local supported="$1" privilege available name
  available="$(while IFS=$'\t' read -r name _; do mariadb_account_canonical_privilege "$name"; printf '\n'; done <<< "$supported")"
  for privilege in "${PRIVILEGES[@]}"; do
    [[ "$privilege" != USAGE ]] || continue
    if ! printf '%s\n' "$available" | grep -Fxq "$(mariadb_account_canonical_privilege "$privilege")"; then
      mariadb_account_add_error "privilege '${privilege}' is unavailable on the target MariaDB server"
    fi
  done
}

mariadb_account_password_source_allowed() {
  local refs="${MARIADB_ACCOUNT_PASSWORD_SECRET_REFS_DEFAULT-}"
  if [[ -n "$refs" ]]; then
    # An explicit read policy is independent of secrets/* write protection and
    # permits only exact Secret/key pairs, including co-located application keys.
    printf '%s' "$refs" | tr ', ' '\n' | grep -Fxq "${PASSWORD_SECRET_NAME}/${PASSWORD_SECRET_KEY}"
    return
  fi
  [[ "$PASSWORD_SECRET_NAME" != "$MDB" && "$PASSWORD_SECRET_NAME" != mariadb ]] && ! secrets_is_protected "$PASSWORD_SECRET_NAME"
}

mariadb_account_grants_match() {
  printf '%s\n' "$1" | python3 "${LIB_DIR}/mariadb-account-grants.py" "$GRANTS_JSON" "$SERVER_PRIVILEGES"
}

mariadb_account_read_grants() {
  # Batch mode otherwise doubles the backslashes in escaped database patterns.
  # Keep the SQL representation intact for exact scope verification.
  mariadb_exec "$1" mariadb -u root -p"$2" -N -B --raw -e "SHOW GRANTS FOR $3" 2>/dev/null
}
