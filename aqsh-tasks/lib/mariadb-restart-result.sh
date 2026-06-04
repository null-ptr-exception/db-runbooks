#!/usr/bin/env bash
# =============================================================================
# lib/mariadb-restart-result.sh
# Structured JSON response builder for the MariaDB restart task.
# =============================================================================

[[ -n "${_MARIADB_RESTART_RESULT_LIB_LOADED:-}" ]] && return 0
_MARIADB_RESTART_RESULT_LIB_LOADED=1

mariadb_restart_emit_result() {
  local status="$1"
  local reason="$2"
  local summary="$3"
  local changed="$4"
  local pods_json="${5:-[]}"
  local result_json

  result_json=$(jq -nc \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg summary "$summary" \
    --arg context "${CONTEXT:-}" \
    --arg namespace "${NAMESPACE:-}" \
    --arg resource "${RESOURCE:-}" \
    --arg mdb "${MDB:-}" \
    --arg update_strategy "${UPDATE_STRATEGY:-}" \
    --arg annotation_key "${ANNOTATION_KEY:-}" \
    --arg annotation_value "${PATCH_VALUE:-}" \
    --arg metadata_field "${METADATA_FIELD:-}" \
    --argjson replicas "$(task_json_num_or_null "${REPLICAS:-}")" \
    --argjson dry_run "$(task_json_bool "${DRY_RUN:-}")" \
    --argjson confirm "$(task_json_bool "${CONFIRM:-}")" \
    --argjson changed "$(task_json_bool "$changed")" \
    --argjson pods "$pods_json" \
    '{
      status: $status,
      reason_code: $reason,
      summary: $summary,
      target: {
        context: ($context | if . == "" then null else . end),
        namespace: $namespace,
        resource: $resource,
        mdb: $mdb,
        update_strategy: ($update_strategy | if . == "" then null else . end),
        replicas: $replicas
      },
      operator_controlled: true,
      annotation: {
        metadata_field: ($metadata_field | if . == "" then null else . end),
        key: $annotation_key,
        value: ($annotation_value | if . == "" then null else . end)
      },
      dry_run: $dry_run,
      confirm: $confirm,
      changed: $changed,
      pods: $pods
    }')

  [[ -n "${RESULT_FILE:-}" ]] && printf '%s\n' "$result_json" > "$RESULT_FILE"
  printf '%s\n' "$result_json"
}
