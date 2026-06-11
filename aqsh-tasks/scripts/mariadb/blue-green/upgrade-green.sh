#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi

# shellcheck source=aqsh-tasks/lib/mariadb-blue-green.sh
source "${LIB_DIR}/mariadb-blue-green.sh"

TARGET_IMAGE="${TARGET_IMAGE:?TARGET_IMAGE is required}"
WAIT_READY="${WAIT_READY:-true}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"

bg_init_target
bg_require_confirm "blue-green/upgrade-green"

bg_validate_dns_label "namespace" "$BG_NAMESPACE" "blue-green/upgrade-green"
bg_validate_dns_label "mariadb" "$BG_MDB" "blue-green/upgrade-green"
bg_validate_image "target_image" "$TARGET_IMAGE" "blue-green/upgrade-green"

_kubectl patch "$BG_RESOURCE" "$BG_MDB" --type merge \
  -p "{\"spec\":{\"image\":$(bg_json_string "$TARGET_IMAGE")}}" >/dev/null

if [[ "$WAIT_READY" != "false" ]]; then
  bg_wait_mariadb_ready "$BG_MDB" "$WAIT_TIMEOUT"
fi

bg_write_result "$(response_ok "blue-green/upgrade-green" "green MariaDB image updated" "$(bg_status_data "$(bg_get_mariadb_json)")")"
