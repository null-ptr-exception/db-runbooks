#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# secrets/pubkey.sh
# aqsh task: return the deployment PGP public key callers must encrypt
# secrets/plan|apply payloads against. Read-only, no cluster access, no
# inputs beyond log verbosity. Shared verbatim by the aqsh-mongodb and
# aqsh-mariadb gateways (see docs/<db>/secrets.md).
# =============================================================================

LIB_DIR="/tasks/lib"
# shellcheck source=aqsh-tasks/lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=aqsh-tasks/lib/response.sh
source "${LIB_DIR}/response.sh"
# shellcheck source=aqsh-tasks/lib/k8s.sh
source "${LIB_DIR}/k8s.sh"
# shellcheck source=aqsh-tasks/lib/secrets.sh
source "${LIB_DIR}/secrets.sh"

log_set_level "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT:-INFO}}"

result=$(secrets_export_pubkey) \
  || secrets_fail "PGP_KEY_UNAVAILABLE" \
       "deployment PGP private key is missing or unreadable" \
       "$(jq -nc --arg path "$_SECRETS_PGP_KEY_PATH" '{key_path: $path}')"

secrets_write_result "$result"
