#!/usr/bin/env bash
# =============================================================================
# lib/vault.sh
# Minimal HashiCorp Vault client via curl — the aqsh image ships curl + jq but
# no `vault` CLI, and AppRole login / KV-v2 writes are both a single HTTP call.
#
# Auth: AppRole (role_id + secret_id), deploy-time internal config only — see
# the "Deploy-time config" section of the calling script for how these are
# sourced. Never accept role_id/secret_id as task inputs: a per-call override
# would let a caller write under a different Vault identity than the one this
# deployment was provisioned with.
#
# Every curl call is time-bounded (a stalled Vault endpoint must not hang the
# task forever) and keeps secrets out of process argv: request bodies go via
# stdin (`--data-binary @-`) instead of `--data "$json"`, and the auth token
# goes in a mode-600 temp curl config file (`--config`) instead of `--header
# "X-Vault-Token: ..."` — both would otherwise be readable by any same-UID
# process via /proc/<pid>/cmdline (e.g. `ps -ef`) for the life of the call.
#
# Required environment:
#   VAULT_ADDR       - e.g. https://vault.internal:8200
#   VAULT_MOUNT       - KV-v2 mount name, e.g. "secret" (no leading/trailing slash)
#   VAULT_ROLE_ID     - AppRole role_id
#   VAULT_SECRET_ID   - AppRole secret_id (sensitive)
# =============================================================================

_VAULT_CURL_TIMEOUTS=(--connect-timeout 5 --max-time 15)

# _vault_token_config_file
# Writes a mode-600 temp curl config file containing the X-Vault-Token header
# and prints its path. Callers must `rm -f` it once the call returns.
_vault_token_config_file() {
  local cfg
  cfg="$(mktemp)" || return 1
  chmod 600 "$cfg"
  printf 'header = "X-Vault-Token: %s"\n' "${VAULT_TOKEN:-}" > "$cfg"
  printf '%s' "$cfg"
}

# vault_login
# Exchange VAULT_ROLE_ID/VAULT_SECRET_ID for a client token.
# stdout: the client token (rc 0), or nothing (rc 1) on any failure.
vault_login() {
  if [[ -z "${VAULT_ADDR:-}" || -z "${VAULT_ROLE_ID:-}" || -z "${VAULT_SECRET_ID:-}" ]]; then
    return 1
  fi

  local resp token
  # role_id/secret_id reach jq via env.* (not --arg) so they never appear in
  # jq's argv either, then flow to curl entirely over the pipe.
  resp="$(_VAULT_LOGIN_ROLE_ID="$VAULT_ROLE_ID" _VAULT_LOGIN_SECRET_ID="$VAULT_SECRET_ID" \
    jq -nc '{role_id: env._VAULT_LOGIN_ROLE_ID, secret_id: env._VAULT_LOGIN_SECRET_ID}' | \
    curl -sf "${_VAULT_CURL_TIMEOUTS[@]}" --request POST --data-binary @- \
    "${VAULT_ADDR}/v1/auth/approle/login" 2>/dev/null)" || return 1

  token="$(jq -r '.auth.client_token // empty' <<<"$resp" 2>/dev/null)"
  [[ -n "$token" ]] || return 1
  printf '%s' "$token"
}

# vault_kv_put <path> <json-object>
# Write <json-object> (a flat JSON object of string values) to the KV-v2
# <path> under VAULT_MOUNT. Requires VAULT_TOKEN (from vault_login) to be set.
# Never logs or echoes <json-object> — callers must not either.
vault_kv_put() {
  local path="$1" data="$2"
  [[ -n "${VAULT_TOKEN:-}" ]] || return 1

  local cfg rc
  cfg="$(_vault_token_config_file)" || return 1
  # $data is already a valid JSON object (produced by the caller with jq),
  # so wrapping it needs no further JSON escaping/jq invocation here.
  printf '{"data":%s}' "$data" | curl -sf "${_VAULT_CURL_TIMEOUTS[@]}" \
    --config "$cfg" --request POST --data-binary @- \
    "${VAULT_ADDR}/v1/${VAULT_MOUNT}/data/${path}" >/dev/null 2>&1
  rc=$?
  rm -f "$cfg"
  return $rc
}

# vault_kv_get <path>
# Read the KV-v2 <path> under VAULT_MOUNT and print its data object (the
# unwrapped {key: value, ...} payload, not the full Vault response envelope)
# to stdout. Requires VAULT_TOKEN (from vault_login) to be set. Returns 1 on
# any failure: unreachable Vault, missing/empty path, or malformed response.
vault_kv_get() {
  local path="$1"
  [[ -n "${VAULT_TOKEN:-}" ]] || return 1

  local cfg resp rc
  cfg="$(_vault_token_config_file)" || return 1
  resp="$(curl -sf "${_VAULT_CURL_TIMEOUTS[@]}" --config "$cfg" \
    "${VAULT_ADDR}/v1/${VAULT_MOUNT}/data/${path}" 2>/dev/null)"
  rc=$?
  rm -f "$cfg"
  [[ $rc -eq 0 ]] || return 1

  jq -e '.data.data' <<<"$resp" 2>/dev/null
}

# vault_logout
# Best-effort revoke of the current VAULT_TOKEN. Never fails the caller.
vault_logout() {
  [[ -n "${VAULT_TOKEN:-}" ]] || return 0

  local cfg
  cfg="$(_vault_token_config_file)" || return 0
  curl -sf "${_VAULT_CURL_TIMEOUTS[@]}" --config "$cfg" --request POST \
    "${VAULT_ADDR}/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
  rm -f "$cfg"
}
