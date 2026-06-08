#!/usr/bin/env bash
set -euo pipefail

# blue-green/delete
#
# Single-cluster cleanup of a Green deployment after a successful switchover (or
# of a failed bootstrap). Runs against its own cluster only: deletes the Green
# MariaDB CR and the ExternalMariaDB references created by bootstrap-green, and
# optionally the PhysicalBackup CR. Mutating: requires confirm=true.

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi

# shellcheck source=aqsh-tasks/lib/mariadb-blue-green.sh
source "${LIB_DIR}/mariadb-blue-green.sh"

OP="blue-green/delete"

BLUE_NAME="${BLUE_NAME:-}"
DELETE_EXTERNAL="${DELETE_EXTERNAL:-true}"
BACKUP_NAME="${BACKUP_NAME:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-5m}"

bg_init_target
bg_require_confirm "$OP"

bg_validate_dns_label "namespace" "$BG_NAMESPACE" "$OP"
bg_validate_dns_label "mdb" "$BG_MDB" "$OP"
[[ -n "$BLUE_NAME" ]] && bg_validate_dns_label "blue_name" "$BLUE_NAME" "$OP"
[[ -n "$BACKUP_NAME" ]] && bg_validate_dns_label "backup_name" "$BACKUP_NAME" "$OP"

deleted=()

# Delete the Green MariaDB CR and wait for it to be gone.
_kubectl delete "$BG_RESOURCE" "$BG_MDB" --ignore-not-found --wait=true --timeout="$WAIT_TIMEOUT" >/dev/null
deleted+=("mariadb/${BG_MDB}")

if [[ "$DELETE_EXTERNAL" != "false" ]]; then
  _kubectl delete externalmariadb "$BG_MDB" --ignore-not-found >/dev/null
  deleted+=("externalmariadb/${BG_MDB}")
  if [[ -n "$BLUE_NAME" ]]; then
    _kubectl delete externalmariadb "$BLUE_NAME" --ignore-not-found >/dev/null
    deleted+=("externalmariadb/${BLUE_NAME}")
  fi
fi

if [[ -n "$BACKUP_NAME" ]]; then
  _kubectl delete physicalbackup "$BACKUP_NAME" --ignore-not-found >/dev/null
  deleted+=("physicalbackup/${BACKUP_NAME}")
fi

data="$(jq -n \
  --arg namespace "$BG_NAMESPACE" \
  --arg green "$BG_MDB" \
  --argjson deleted "$(printf '%s\n' "${deleted[@]}" | jq -R . | jq -s .)" \
  '{namespace: $namespace, green: $green, deleted: $deleted}')"

bg_write_result "$(response_ok "$OP" "green deployment deleted" "$data")"
