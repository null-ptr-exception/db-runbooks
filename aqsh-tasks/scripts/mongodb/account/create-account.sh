#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="${LIB_DIR:-/tasks/lib}"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb-account.sh"

DB_NAMESPACE="${DB_NAMESPACE:?DB_NAMESPACE is required}"
MONGO_STS_NAME="${MONGO_STS_NAME:-mongodb}"
MONGO_CRED_SECRET="${MONGO_CRED_SECRET:-mongodb-credentials}"
MONGO_CRED_USER_KEY="${MONGO_CRED_USER_KEY:-MONGO_ROOT_USER}"
MONGO_CRED_PASS_KEY="${MONGO_CRED_PASS_KEY:-MONGO_ROOT_PASS}"
ACCOUNT_AUTH_DB="${ACCOUNT_AUTH_DB:-admin}"
ACCOUNT_USERNAME="${ACCOUNT_USERNAME:?ACCOUNT_USERNAME is required}"
ACCOUNT_ROLES_JSON="${ACCOUNT_ROLES_JSON:-}"
ACCOUNT_DATABASE="${ACCOUNT_DATABASE:-$ACCOUNT_AUTH_DB}"
TEMP_DAYS="${TEMP_DAYS:-14}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"
ALLOW_EXISTING="${ALLOW_EXISTING:-false}"
PASSWORD_LENGTH="${PASSWORD_LENGTH:-24}"
PASSWORD_SPECIAL_CHARS="${PASSWORD_SPECIAL_CHARS:-!@#%^*_-+=.}"
PASSWORD_SPECIAL_MAX="${PASSWORD_SPECIAL_MAX:-4}"
REQUEST_ID="${REQUEST_ID:-}"
REQUESTED_BY="${REQUESTED_BY:-}"
PASSWORD_DELIVERY_MODE="${PASSWORD_DELIVERY_MODE:-one_time_plaintext}"
RECIPIENT_PGP_PUBKEY="${RECIPIENT_PGP_PUBKEY:-}"

if [[ -z "$ACCOUNT_ROLES_JSON" ]]; then
  ACCOUNT_ROLES_JSON=$(jq -nc --arg db "$ACCOUNT_DATABASE" '[{"role":"readWrite","db":$db}]')
fi

if ! [[ "$TEMP_DAYS" =~ ^[0-9]+$ ]] || [[ "$TEMP_DAYS" -lt 1 ]]; then
  fail_task "INVALID_INPUT" "temp_days must be a positive integer"
fi

if ! echo "$ACCOUNT_ROLES_JSON" | jq -e 'type == "array" and length > 0 and all(.[]; has("role") and has("db"))' >/dev/null 2>&1; then
  fail_task "INVALID_INPUT" "roles_json must be a non-empty role array"
fi

if [[ "$PASSWORD_DELIVERY_MODE" != "one_time_plaintext" && "$PASSWORD_DELIVERY_MODE" != "encrypted_payload" ]]; then
  fail_task "INVALID_INPUT" "unsupported password_delivery_mode"
fi

generate_password() {
  python3 - "$PASSWORD_LENGTH" "$PASSWORD_SPECIAL_CHARS" "$PASSWORD_SPECIAL_MAX" <<'PY'
import secrets
import string
import sys

length = int(sys.argv[1])
special = sys.argv[2]
special_max = int(sys.argv[3])

if length < 12:
    raise SystemExit("length must be >= 12")

alpha_num = string.ascii_letters + string.digits
special = ''.join(dict.fromkeys(special))
if any(ch in "'\"\\ \t\n\r" for ch in special):
    raise SystemExit("unsupported special charset")

while True:
    chars = []
    specials_used = 0
    for _ in range(length):
      if special and specials_used < special_max and secrets.randbelow(100) < 20:
          chars.append(secrets.choice(special))
          specials_used += 1
      else:
          chars.append(secrets.choice(alpha_num))
    if any(c.islower() for c in chars) and any(c.isupper() for c in chars) and any(c.isdigit() for c in chars):
        print(''.join(chars))
        break
PY
}

encrypt_password_payload() {
  local plaintext_password="${1:?password is required}"
  local pubkey_input="${2:?recipient pgp public key is required}"
  local gnupg_home raw_import_ok fingerprint ciphertext decoded_key

  gnupg_home=$(mktemp -d)
  chmod 700 "$gnupg_home"

  export GNUPGHOME="$gnupg_home"

  if printf '%s' "$pubkey_input" | gpg --batch --import >/dev/null 2>&1; then
    raw_import_ok="true"
  else
    raw_import_ok="false"
  fi

  if [[ "$raw_import_ok" != "true" ]]; then
    decoded_key=$(printf '%s' "$pubkey_input" | base64 -d 2>/dev/null || true)
    if [[ -z "$decoded_key" ]]; then
      rm -rf "$gnupg_home"
      return 1
    fi
    printf '%s' "$decoded_key" | gpg --batch --import >/dev/null 2>&1 || {
      rm -rf "$gnupg_home"
      return 1
    }
  fi

  fingerprint=$(gpg --batch --with-colons --list-keys | awk -F: '$1=="fpr"{print $10; exit}')
  if [[ -z "$fingerprint" ]]; then
    rm -rf "$gnupg_home"
    return 1
  fi

  ciphertext=$(printf '%s' "$plaintext_password" | gpg --batch --yes --trust-model always --armor --recipient "$fingerprint" --encrypt 2>/dev/null) || {
    rm -rf "$gnupg_home"
    return 1
  }

  rm -rf "$gnupg_home"

  jq -nc \
    --arg recipient_key_fingerprint "$fingerprint" \
    --arg ciphertext "$ciphertext" \
    '{mode:"encrypted_payload", recipient_key_fingerprint:$recipient_key_fingerprint, content_type:"application/pgp-encrypted", ciphertext:$ciphertext}'
}

if bool_enabled "$DRY_RUN" && ! bool_enabled "$CONFIRM"; then
  expires_at=$(iso_utc_after_days "$TEMP_DAYS")
  write_task_result "$(jq -n \
    --arg status "READY" \
    --arg reason_code "DRY_RUN_READY" \
    --arg summary "Dry-run only. No account changes applied." \
    --arg namespace "$DB_NAMESPACE" \
    --arg auth_db "$ACCOUNT_AUTH_DB" \
    --arg username "$ACCOUNT_USERNAME" \
    --arg expires_at "$expires_at" \
    --argjson roles "$ACCOUNT_ROLES_JSON" \
    '{status:$status, reason_code:$reason_code, summary:$summary, namespace:$namespace, auth_db:$auth_db, username:$username, expires_at:$expires_at, roles:$roles}')"
  exit 0
fi

if bool_enabled "$DRY_RUN" && bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true with dry_run=true is not supported"
fi

if ! bool_enabled "$DRY_RUN" && ! bool_enabled "$CONFIRM"; then
  fail_task "INVALID_INPUT" "confirm=true is required when dry_run=false"
fi

mongo_account_set_connection_from_root_secret "$DB_NAMESPACE" "$MONGO_STS_NAME" "$MONGO_CRED_SECRET" "$MONGO_CRED_USER_KEY" "$MONGO_CRED_PASS_KEY" \
  || fail_task "ROOT_SECRET_UNAVAILABLE" "cannot read mongo root credentials or resolve primary"
mongo_account_connection_check || fail_task "CONNECTIVITY_FAILED" "cannot connect to mongo primary"

account_exists="false"
if mongo_account_exists "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME"; then
  account_exists="true"
fi

if [[ "$account_exists" == "true" ]] && ! bool_enabled "$ALLOW_EXISTING"; then
  fail_task "ACCOUNT_ALREADY_EXISTS" "account already exists"
fi

if [[ "$PASSWORD_DELIVERY_MODE" == "encrypted_payload" ]] && [[ -z "$RECIPIENT_PGP_PUBKEY" ]]; then
  fail_task "INVALID_INPUT" "recipient_pgp_pubkey is required when password_delivery_mode=encrypted_payload"
fi

password="$(generate_password)"
esc_db=$(_escape_js_string "$ACCOUNT_AUTH_DB")
esc_user=$(_escape_js_string "$ACCOUNT_USERNAME")
esc_pass=$(_escape_js_string "$password")
esc_roles=$(_escape_js_string "$ACCOUNT_ROLES_JSON")
expires_at="$(iso_utc_after_days "$TEMP_DAYS")"
now_utc="$(iso_utc_now)"
esc_expires=$(_escape_js_string "$expires_at")
esc_now=$(_escape_js_string "$now_utc")
esc_req_id=$(_escape_js_string "$REQUEST_ID")

if [[ "$account_exists" == "true" ]]; then
  js="const roles = JSON.parse('${esc_roles}'); db.getSiblingDB('${esc_db}').updateUser('${esc_user}', {pwd:'${esc_pass}', roles:roles, customData:{temp_account:true, expires_at:'${esc_expires}', request_id:'${esc_req_id}', issued_at:'${esc_now}'}}); JSON.stringify({ok:1, action:'recreated'})"
else
  js="const roles = JSON.parse('${esc_roles}'); db.getSiblingDB('${esc_db}').createUser({user:'${esc_user}', pwd:'${esc_pass}', roles:roles, customData:{temp_account:true, expires_at:'${esc_expires}', request_id:'${esc_req_id}', issued_at:'${esc_now}'}}); JSON.stringify({ok:1, action:'created'})"
fi

_mongosh_eval "admin" "$js" >/dev/null 2>&1 || fail_task "CREATE_FAILED" "failed to create or recreate account"

fingerprint=$(mongo_account_credentials_fingerprint "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME") || fail_task "FINGERPRINT_FAILED" "cannot compute credentials fingerprint"
policy_set=$(jq -nc \
  --arg policy_id "${REQUEST_ID:-$(date +%s)-${ACCOUNT_USERNAME}}" \
  --arg username "$ACCOUNT_USERNAME" \
  --arg auth_db "$ACCOUNT_AUTH_DB" \
  --argjson roles "$ACCOUNT_ROLES_JSON" \
  --arg status "ACTIVE" \
  --arg expires_at "$expires_at" \
  --arg initial_cred_fingerprint "$fingerprint" \
  --arg last_cred_fingerprint "$fingerprint" \
  --arg password_delivery_mode "$PASSWORD_DELIVERY_MODE" \
  --arg request_id "$REQUEST_ID" \
  --arg requested_by "$REQUESTED_BY" \
  --arg target_namespace "$DB_NAMESPACE" \
  --arg sts_name "$MONGO_STS_NAME" \
  --arg updated_at "$now_utc" \
  '{policy_id:$policy_id, username:$username, auth_db:$auth_db, roles:$roles, status:$status, expires_at:$expires_at, initial_cred_fingerprint:$initial_cred_fingerprint, last_cred_fingerprint:$last_cred_fingerprint, password_delivery_mode:$password_delivery_mode, request_id:$request_id, requested_by:$requested_by, target_namespace:$target_namespace, sts_name:$sts_name, updated_at:$updated_at}')
policy_insert=$(jq -nc --arg created_at "$now_utc" '{created_at:$created_at}')
policy_upsert_out=""
if ! policy_upsert_out=$(mongo_policy_upsert "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME" "$policy_set" "$policy_insert" 2>&1); then
  fail_task "POLICY_WRITE_FAILED" "cannot persist policy record" "$(jq -nc --arg error "$policy_upsert_out" '{error:$error}')"
fi

result_status="CREATED"
reason_code="ACCOUNT_CREATED"
if [[ "$account_exists" == "true" ]]; then
  result_status="RECREATED"
  reason_code="ACCOUNT_RECREATED"
fi

delivery_payload_json=""
if [[ "$PASSWORD_DELIVERY_MODE" == "one_time_plaintext" ]]; then
  delivery_payload_json=$(jq -nc --arg password "$password" '{mode:"one_time_plaintext", password:$password}')
elif [[ "$PASSWORD_DELIVERY_MODE" == "encrypted_payload" ]]; then
  if ! delivery_payload_json=$(encrypt_password_payload "$password" "$RECIPIENT_PGP_PUBKEY" 2>/dev/null); then
    fail_task "DELIVERY_ENCRYPT_FAILED" "failed to encrypt password payload with recipient public key"
  fi
else
  fail_task "INVALID_INPUT" "unsupported password_delivery_mode"
fi

write_task_result "$(jq -n \
  --arg status "$result_status" \
  --arg reason_code "$reason_code" \
  --arg summary "account processed successfully" \
  --arg namespace "$DB_NAMESPACE" \
  --arg auth_db "$ACCOUNT_AUTH_DB" \
  --arg username "$ACCOUNT_USERNAME" \
  --arg expires_at "$expires_at" \
  --arg primary "$MONGO_HOST:$MONGO_PORT" \
  --arg request_id "$REQUEST_ID" \
  --argjson delivery_payload "$delivery_payload_json" \
  --argjson roles "$ACCOUNT_ROLES_JSON" \
  '{status:$status, reason_code:$reason_code, summary:$summary, namespace:$namespace, auth_db:$auth_db, username:$username, roles:$roles, expires_at:$expires_at, primary:$primary, request_id:$request_id, delivery_payload:$delivery_payload}')"
