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
# Required environment:
#   VAULT_ADDR       - e.g. https://vault.internal:8200
#   VAULT_MOUNT       - KV-v2 mount name, e.g. "secret" (no leading/trailing slash)
#   VAULT_ROLE_ID     - AppRole role_id
#   VAULT_SECRET_ID   - AppRole secret_id (sensitive)
# =============================================================================

# vault_login
# Exchange VAULT_ROLE_ID/VAULT_SECRET_ID for a client token.
# stdout: the client token (rc 0), or nothing (rc 1) on any failure.
vault_login() {
  if [[ -z "${VAULT_ADDR:-}" || -z "${VAULT_ROLE_ID:-}" || -z "${VAULT_SECRET_ID:-}" ]]; then
    return 1
  fi

  local resp token
  resp="$(curl -sf --request POST \
    --data "$(jq -nc --arg r "$VAULT_ROLE_ID" --arg s "$VAULT_SECRET_ID" '{role_id:$r, secret_id:$s}')" \
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

  curl -sf --header "X-Vault-Token: ${VAULT_TOKEN}" --request POST \
    --data "$(jq -nc --argjson d "$data" '{data: $d}')" \
    "${VAULT_ADDR}/v1/${VAULT_MOUNT}/data/${path}" >/dev/null 2>&1
}

# vault_logout
# Best-effort revoke of the current VAULT_TOKEN. Never fails the caller.
vault_logout() {
  [[ -n "${VAULT_TOKEN:-}" ]] || return 0
  curl -sf --header "X-Vault-Token: ${VAULT_TOKEN}" --request POST \
    "${VAULT_ADDR}/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
}
