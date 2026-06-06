#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi

# shellcheck source=aqsh-tasks/lib/mariadb-blue-green.sh
source "${LIB_DIR}/mariadb-blue-green.sh"

PRIMARY="${BLUE_GREEN_PRIMARY:-}"

bg_init_target
bg_require_confirm "blue-green/set-primary"

if [[ -z "$PRIMARY" ]]; then
  bg_fail "blue-green/set-primary" "primary is required" '{}'
fi

_kubectl patch "$BG_RESOURCE" "$BG_MDB" --type merge \
  -p "{\"spec\":{\"multiCluster\":{\"primary\":$(bg_json_string "$PRIMARY")}}}" >/dev/null

bg_write_result "$(response_ok "blue-green/set-primary" "multiCluster primary updated" "$(bg_status_data "$(bg_get_mariadb_json)")")"
