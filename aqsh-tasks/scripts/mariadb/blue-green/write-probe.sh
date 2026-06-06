#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi

# shellcheck source=aqsh-tasks/lib/mariadb-blue-green.sh
source "${LIB_DIR}/mariadb-blue-green.sh"

PROBE_DATABASE="${PROBE_DATABASE:-bgtest}"
PROBE_TABLE="${PROBE_TABLE:-events}"
PROBE_ID="${PROBE_ID:-1}"
PROBE_NOTE="${PROBE_NOTE:-aqsh-write-probe}"

bg_init_target
bg_require_confirm "blue-green/write-probe"

cr_json="$(bg_get_mariadb_json)"
primary="$(bg_current_primary_pod "$cr_json" "blue-green/write-probe")"
password="$(bg_read_root_password "$primary")"

mariadb_sql "$primary" "$password" "CREATE DATABASE IF NOT EXISTS \`${PROBE_DATABASE}\`" >/dev/null
mariadb_sql "$primary" "$password" "CREATE TABLE IF NOT EXISTS \`${PROBE_DATABASE}\`.\`${PROBE_TABLE}\` (id INT PRIMARY KEY, note VARCHAR(128))" >/dev/null
mariadb_sql "$primary" "$password" "INSERT INTO \`${PROBE_DATABASE}\`.\`${PROBE_TABLE}\` VALUES (${PROBE_ID}, $(bg_json_string "$PROBE_NOTE")) ON DUPLICATE KEY UPDATE note = VALUES(note)" >/dev/null
count="$(mariadb_sql "$primary" "$password" "SELECT COUNT(*) FROM \`${PROBE_DATABASE}\`.\`${PROBE_TABLE}\` WHERE id = ${PROBE_ID}")"

bg_write_result "$(response_ok "blue-green/write-probe" "write probe succeeded" \
  "$(jq -n --arg pod "$primary" --arg database "$PROBE_DATABASE" --arg table "$PROBE_TABLE" --arg id "$PROBE_ID" --arg note "$PROBE_NOTE" --arg count "$count" '{pod: $pod, database: $database, table: $table, id: ($id|tonumber), note: $note, count: ($count|tonumber)}')")"
