#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi

# shellcheck source=aqsh-tasks/lib/mariadb-blue-green.sh
source "${LIB_DIR}/mariadb-blue-green.sh"

READ_ONLY="${READ_ONLY:-true}"
CORDON="${CORDON:-true}"
DRAIN_CONNECTIONS="${DRAIN_CONNECTIONS:-true}"
DRAIN_GRACE_PERIOD_SECONDS="${DRAIN_GRACE_PERIOD_SECONDS:-30}"

bg_init_target
bg_require_confirm "blue-green/maintenance"

read_only="$(bg_bool_json "$READ_ONLY")"
cordon="$(bg_bool_json "$CORDON")"
drain="$(bg_bool_json "$DRAIN_CONNECTIONS")"

_kubectl patch "$BG_RESOURCE" "$BG_MDB" --type merge -p "{
  \"spec\": {
    \"maintenance\": {
      \"enabled\": true,
      \"cordon\": ${cordon},
      \"drainConnections\": ${drain},
      \"drainGracePeriodSeconds\": ${DRAIN_GRACE_PERIOD_SECONDS},
      \"readOnly\": ${read_only}
    }
  }
}" >/dev/null

bg_write_result "$(response_ok "blue-green/maintenance" "maintenance mode enabled" "$(bg_status_data "$(bg_get_mariadb_json)")")"
