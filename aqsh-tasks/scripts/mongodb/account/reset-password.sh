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
TEMP_DAYS="${TEMP_DAYS:-14}"
RESET_OVERRIDE="${RESET_OVERRIDE:-false}"
PASSWORD_LENGTH="${PASSWORD_LENGTH:-24}"
PASSWORD_SPECIAL_CHARS="${PASSWORD_SPECIAL_CHARS:-!@#%^*_-+=.}"
PASSWORD_SPECIAL_MAX="${PASSWORD_SPECIAL_MAX:-4}"
PASSWORD_DELIVERY_MODE="${PASSWORD_DELIVERY_MODE:-one_time_plaintext}"
RECIPIENT_PGP_PUBKEY="${RECIPIENT_PGP_PUBKEY:-}"

if ! [[ "$TEMP_DAYS" =~ ^[0-9]+$ ]] || [[ "$TEMP_DAYS" -lt 1 ]]; then
  fail_task "INVALID_INPUT" "temp_days must be a positive integer"
fi

if [[ "$PASSWORD_DELIVERY_MODE" != "one_time_plaintext" && "$PASSWORD_DELIVERY_MODE" != "encrypted_payload" ]]; then
  fail_task "INVALID_INPUT" "unsupported password_delivery_mode"
fi

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

generate_password() {
  python3 - "$PASSWORD_LENGTH" "$PASSWORD_SPECIAL_CHARS" "$PASSWORD_SPECIAL_MAX" <<'PY'
import secrets
import string
import sys

length = int(sys.argv[1])
special = ''.join(dict.fromkeys(sys.argv[2]))
special_max = int(sys.argv[3])

if length < 12:
    raise SystemExit("length must be >= 12")
if any(ch in "'\"\\ \t\n\r" for ch in special):
    raise SystemExit("unsupported special charset")

alpha_num = string.ascii_letters + string.digits
while True:
    out = []
    s_used = 0
    for _ in range(length):
        if special and s_used < special_max and secrets.randbelow(100) < 20:
            out.append(secrets.choice(special))
            s_used += 1
        else:
            out.append(secrets.choice(alpha_num))
    if any(c.islower() for c in out) and any(c.isupper() for c in out) and any(c.isdigit() for c in out):
        print(''.join(out))
        break
PY
}

precheck_rc=0
mongo_account_shared_precheck "true" "$DB_NAMESPACE" "$MONGO_STS_NAME" "$MONGO_CRED_SECRET" "$MONGO_CRED_USER_KEY" "$MONGO_CRED_PASS_KEY" "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME" || precheck_rc=$?
case "$precheck_rc" in
  0) ;;
  1) fail_task "PRECHECK_FAILED" "precheck failed" ;;
  2) fail_task "NOT_FOUND" "account not found" ;;
esac

policy_status=""
if policy_status=$(mongo_policy_status "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME" 2>/dev/null); then
  if [[ "$policy_status" == "CHANGED" || "$policy_status" == "PERMANENT" ]] && ! bool_enabled "$RESET_OVERRIDE"; then
    fail_task "STATE_BLOCKED" "reset-password blocked for changed/permanent account without override"
  fi
  if [[ "$policy_status" == "EXPIRED_DELETED" || "$policy_status" == "CANCELLED" ]]; then
    fail_task "STATE_BLOCKED" "cannot reset password for terminal policy state"
  fi
fi

if [[ "$PASSWORD_DELIVERY_MODE" == "encrypted_payload" ]] && [[ -z "$RECIPIENT_PGP_PUBKEY" ]]; then
  fail_task "INVALID_INPUT" "recipient_pgp_pubkey is required when password_delivery_mode=encrypted_payload"
fi

new_password="$(generate_password)"
mongo_update_user_password "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME" "$new_password" >/dev/null 2>&1 || fail_task "RESET_FAILED" "cannot update account password"

new_fingerprint=$(mongo_account_credentials_fingerprint "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME") || fail_task "FINGERPRINT_FAILED" "cannot compute credentials fingerprint"
now_utc="$(iso_utc_now)"
expires_at="$(iso_utc_after_days "$TEMP_DAYS")"
initial_fingerprint="$new_fingerprint"
if [[ -n "$policy_status" ]]; then
  existing_initial=$(mongo_policy_get_json "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME" | jq -r '.initial_cred_fingerprint // empty' 2>/dev/null || true)
  if [[ -n "$existing_initial" ]]; then
    initial_fingerprint="$existing_initial"
  fi
fi
policy_set=$(jq -nc \
  --arg status "ACTIVE" \
  --arg updated_at "$now_utc" \
  --arg expires_at "$expires_at" \
  --arg initial_cred_fingerprint "$initial_fingerprint" \
  --arg last_cred_fingerprint "$new_fingerprint" \
  '{status:$status, updated_at:$updated_at, expires_at:$expires_at, initial_cred_fingerprint:$initial_cred_fingerprint, last_cred_fingerprint:$last_cred_fingerprint}')
mongo_policy_upsert "$ACCOUNT_AUTH_DB" "$ACCOUNT_USERNAME" "$policy_set" '{}' >/dev/null 2>&1 || fail_task "POLICY_WRITE_FAILED" "cannot update policy"

delivery_payload_json=""
if [[ "$PASSWORD_DELIVERY_MODE" == "one_time_plaintext" ]]; then
  delivery_payload_json=$(jq -nc --arg password "$new_password" '{mode:"one_time_plaintext", password:$password}')
else
  if ! delivery_payload_json=$(encrypt_password_payload "$new_password" "$RECIPIENT_PGP_PUBKEY" 2>/dev/null); then
    fail_task "DELIVERY_ENCRYPT_FAILED" "failed to encrypt password payload with recipient public key"
  fi
fi

write_task_result "$(jq -n \
  --arg status "RESET" \
  --arg reason_code "PASSWORD_RESET" \
  --arg summary "password reset successfully" \
  --arg namespace "$DB_NAMESPACE" \
  --arg auth_db "$ACCOUNT_AUTH_DB" \
  --arg username "$ACCOUNT_USERNAME" \
  --arg expires_at "$expires_at" \
  --argjson delivery_payload "$delivery_payload_json" \
  '{status:$status, reason_code:$reason_code, summary:$summary, namespace:$namespace, auth_db:$auth_db, username:$username, expires_at:$expires_at, delivery_payload:$delivery_payload}')"
