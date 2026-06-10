#!/usr/bin/env bash
# Shared helpers for MongoDB account lifecycle tasks.

[[ -n "${_MONGODB_ACCOUNT_LIB_LOADED:-}" ]] && return 0
_MONGODB_ACCOUNT_LIB_LOADED=1

MONGO_POLICY_DB="${MONGO_POLICY_DB:-admin}"
MONGO_POLICY_COLLECTION="${MONGO_POLICY_COLLECTION:-run_account_policies}"

bool_enabled() {
  case "${1:-false}" in
    1 | true | TRUE | yes | YES | on | ON) return 0 ;;
    *) return 1 ;;
  esac
}

iso_utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

iso_utc_after_days() {
  local days="${1:?days is required}"
  date -u -d "+${days} days" +"%Y-%m-%dT%H:%M:%SZ"
}

write_task_result() {
  local json_payload="${1:?json payload is required}"
  if [[ -n "${AQSH_RESULT_FILE:-}" ]]; then
    printf '%s\n' "$json_payload" > "$AQSH_RESULT_FILE"
  else
    printf '%s\n' "$json_payload"
  fi
}

fail_task() {
  local reason="${1:-ERROR}"
  local summary="${2:-operation failed}"
  local details_raw="${3-}"
  local details

  [[ -n "$details_raw" ]] || details_raw='{}'

  details=$(jq -nc --arg raw "$details_raw" 'try ($raw | fromjson) catch {raw_detail:$raw}')
  write_task_result "$(jq -n \
    --arg status "ERROR" \
    --arg reason_code "$reason" \
    --arg summary "$summary" \
    --argjson details "$details" \
    '{status: $status, reason_code: $reason_code, summary: $summary, details: $details}')"
  exit 1
}

extract_secret_value() {
  local namespace="${1:?namespace is required}"
  local secret_name="${2:?secret name is required}"
  local key="${3:?secret key is required}"
  local encoded

  encoded=$(kubectl -n "$namespace" get secret "$secret_name" -o "jsonpath={.data.${key}}" 2>/dev/null) || return 1
  [[ -n "$encoded" ]] || return 1
  printf '%s' "$encoded" | base64 -d
}

mongo_account_set_connection_from_root_secret() {
  local namespace="${1:?namespace is required}"
  local sts_name="${2:-mongodb}"
  local cred_secret="${3:-mongodb-credentials}"
  local user_key="${4:-MONGO_ROOT_USER}"
  local pass_key="${5:-MONGO_ROOT_PASS}"

  local root_user root_pass seed_host primary_out primary_host primary_port
  root_user=$(extract_secret_value "$namespace" "$cred_secret" "$user_key") || return 1
  root_pass=$(extract_secret_value "$namespace" "$cred_secret" "$pass_key") || return 1

  seed_host="${sts_name}-0.${sts_name}.${namespace}.svc.cluster.local"
  primary_out=$(mongo_resolve_primary "$seed_host" "27017" "$root_user" "$root_pass" "admin") || return 1
  primary_host=$(echo "$primary_out" | sed -n '1p')
  primary_port=$(echo "$primary_out" | sed -n '2p')

  [[ -n "$primary_host" ]] || return 1

  export MONGO_HOST="$primary_host"
  export MONGO_PORT="${primary_port:-27017}"
  export MONGO_AUTHDB="admin"
  export MONGO_USER="$root_user"
  export MONGO_PASS="$root_pass"
}

mongo_account_connection_check() {
  local r
  r=$(mongo_check 2>/dev/null) || return 1
  [[ "$(_json_status "$r")" == "success" ]]
}

mongo_account_get_user_json() {
  local auth_db="${1:?auth db is required}"
  local username="${2:?username is required}"
  local esc_db esc_user

  esc_db=$(_escape_js_string "$auth_db")
  esc_user=$(_escape_js_string "$username")

  _mongosh_eval "admin" "JSON.stringify(db.getSiblingDB('${esc_db}').getUser('${esc_user}', {showCredentials:true, showPrivileges:true}))"
}

mongo_account_exists() {
  local auth_db="${1:?auth db is required}"
  local username="${2:?username is required}"
  local out

  out=$(mongo_account_get_user_json "$auth_db" "$username" 2>/dev/null) || return 1
  [[ "$(printf '%s' "$out" | tr -d '[:space:]')" != "null" ]]
}

mongo_account_credentials_fingerprint() {
  local auth_db="${1:?auth db is required}"
  local username="${2:?username is required}"
  local user_json cred_json

  user_json=$(mongo_account_get_user_json "$auth_db" "$username" 2>/dev/null) || return 1
  [[ "$(printf '%s' "$user_json" | tr -d '[:space:]')" == "null" ]] && return 1

  cred_json=$(printf '%s' "$user_json" | jq -c '.credentials // {}')
  printf '%s' "$cred_json" | sha256sum | awk '{print $1}'
}

mongo_policy_get_json() {
  local auth_db="${1:?auth db is required}"
  local username="${2:?username is required}"
  local esc_db esc_coll esc_user esc_auth

  esc_db=$(_escape_js_string "$MONGO_POLICY_DB")
  esc_coll=$(_escape_js_string "$MONGO_POLICY_COLLECTION")
  esc_user=$(_escape_js_string "$username")
  esc_auth=$(_escape_js_string "$auth_db")

  _mongosh_eval "admin" "JSON.stringify(db.getSiblingDB('${esc_db}').getCollection('${esc_coll}').findOne({username:'${esc_user}', auth_db:'${esc_auth}'}) || null)"
}

mongo_policy_upsert() {
  local auth_db="${1:?auth db is required}"
  local username="${2:?username is required}"
  local set_json="${3:?set json is required}"
  local set_on_insert_json="${4-}"
  local esc_db esc_coll esc_user esc_auth

  [[ -n "$set_on_insert_json" ]] || set_on_insert_json='{}'

  esc_db=$(_escape_js_string "$MONGO_POLICY_DB")
  esc_coll=$(_escape_js_string "$MONGO_POLICY_COLLECTION")
  esc_user=$(_escape_js_string "$username")
  esc_auth=$(_escape_js_string "$auth_db")

  _mongosh_eval "admin" "const setDoc = ${set_json}; const setOnInsert = ${set_on_insert_json}; const r = db.getSiblingDB('${esc_db}').getCollection('${esc_coll}').updateOne({username:'${esc_user}', auth_db:'${esc_auth}'}, {\$set: setDoc, \$setOnInsert: setOnInsert}, {upsert:true}); JSON.stringify({ok:1, matched:r.matchedCount, modified:r.modifiedCount, upserted:r.upsertedCount});"
}

mongo_policy_status() {
  local auth_db="${1:?auth db is required}"
  local username="${2:?username is required}"
  local policy_json

  policy_json=$(mongo_policy_get_json "$auth_db" "$username" 2>/dev/null) || return 1
  [[ "$(printf '%s' "$policy_json" | tr -d '[:space:]')" == "null" ]] && return 1
  printf '%s' "$policy_json" | jq -r '.status // empty'
}

mongo_account_shared_precheck() {
  local require_exists="${1:?require_exists is required}"
  local namespace="${2:?namespace is required}"
  local sts_name="${3:-mongodb}"
  local cred_secret="${4:-mongodb-credentials}"
  local user_key="${5:-MONGO_ROOT_USER}"
  local pass_key="${6:-MONGO_ROOT_PASS}"
  local auth_db="${7:?auth_db is required}"
  local username="${8:?username is required}"

  mongo_account_set_connection_from_root_secret "$namespace" "$sts_name" "$cred_secret" "$user_key" "$pass_key" || return 1
  mongo_account_connection_check || return 1

  if bool_enabled "$require_exists"; then
    mongo_account_exists "$auth_db" "$username" || return 2
  fi

  return 0
}

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
if any(ch in "'\"\\  \t\n\r" for ch in special):
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
  trap 'rm -rf "$gnupg_home"' RETURN EXIT

  export GNUPGHOME="$gnupg_home"

  if printf '%s' "$pubkey_input" | gpg --batch --import >/dev/null 2>&1; then
    raw_import_ok="true"
  else
    raw_import_ok="false"
  fi

  if [[ "$raw_import_ok" != "true" ]]; then
    decoded_key=$(printf '%s' "$pubkey_input" | base64 -d 2>/dev/null || true)
    if [[ -z "$decoded_key" ]]; then
      return 1
    fi
    printf '%s' "$decoded_key" | gpg --batch --import >/dev/null 2>&1 || return 1
  fi

  fingerprint=$(gpg --batch --with-colons --list-keys | awk -F: '$1=="fpr"{print $10; exit}')
  if [[ -z "$fingerprint" ]]; then
    return 1
  fi

  ciphertext=$(printf '%s' "$plaintext_password" | gpg --batch --yes --trust-model always --armor --recipient "$fingerprint" --encrypt 2>/dev/null) || return 1

  jq -nc \
    --arg recipient_key_fingerprint "$fingerprint" \
    --arg ciphertext "$ciphertext" \
    '{mode:"encrypted_payload", recipient_key_fingerprint:$recipient_key_fingerprint, content_type:"application/pgp-encrypted", ciphertext:$ciphertext}'
}
