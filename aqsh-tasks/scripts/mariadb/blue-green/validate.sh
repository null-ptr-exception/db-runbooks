#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi

# shellcheck source=aqsh-tasks/lib/mariadb-blue-green.sh
source "${LIB_DIR}/mariadb-blue-green.sh"

EXPECTED_VERSION="${EXPECTED_VERSION:-}"
EXPECTED_PRIMARY="${EXPECTED_PRIMARY:-}"
CHECK_REPLICATION="${CHECK_REPLICATION:-true}"
LAG_THRESHOLD="${LAG_THRESHOLD:-0}"

bg_init_target

cr_json="$(bg_get_mariadb_json)"
primary="$(bg_current_primary_pod "$cr_json" "blue-green/validate")"
password="$(bg_read_root_password "$primary")"
version="$(mariadb_sql "$primary" "$password" 'SELECT @@version')"
status_data="$(bg_status_data "$cr_json")"
replication_data="$(bg_replication_check "$cr_json" "$LAG_THRESHOLD")"

if [[ -n "$EXPECTED_VERSION" && "$version" != *"$EXPECTED_VERSION"* ]]; then
  bg_fail "blue-green/validate" "MariaDB version did not match expected_version" \
    "$(jq --arg version "$version" --arg expected "$EXPECTED_VERSION" '. + {version: $version, expectedVersion: $expected}' <<<"$status_data")"
fi

if [[ -n "$EXPECTED_PRIMARY" ]]; then
  actual_primary="$(jq -r '.currentMultiClusterPrimary // empty' <<<"$status_data")"
  if [[ "$actual_primary" != "$EXPECTED_PRIMARY" ]]; then
    bg_fail "blue-green/validate" "currentMultiClusterPrimary did not match expected_primary" \
      "$(jq --arg expected "$EXPECTED_PRIMARY" '. + {expectedPrimary: $expected}' <<<"$status_data")"
  fi
fi

if [[ "$CHECK_REPLICATION" != "false" ]] && [[ "$(jq -r '.ok' <<<"$replication_data")" != "true" ]]; then
  bg_fail "blue-green/validate" "replication is not caught up" \
    "$(jq --arg version "$version" --argjson replication "$replication_data" '. + {version: $version, replicationCheck: $replication}' <<<"$status_data")"
fi

bg_write_result "$(response_ok "blue-green/validate" "MariaDB blue/green validation passed" \
  "$(jq --arg version "$version" --argjson replication "$replication_data" '. + {version: $version, replicationCheck: $replication}' <<<"$status_data")")"
