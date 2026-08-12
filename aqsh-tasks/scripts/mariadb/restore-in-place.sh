#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/restore-in-place.sh
# Restore one exact physical backup into an existing mariadb-operator 0.24
# instance. The MariaDB CR and PVC objects retain their UIDs; only datadir
# contents are replaced. This is the internal restore primitive used by the
# cross-cluster rebuild path and is also exposed as POST /tasks/restore-in-place.
# =============================================================================

OP="restore-in-place"

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi
# shellcheck source=../../lib/mariadb-replication-rebuild.sh
source "${LIB_DIR}/mariadb-replication-rebuild.sh"

NAMESPACE="${DB_NAMESPACE:-}"
BACKUP_NAME="${BACKUP_NAME:-}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"

mdbt_load_config
mdbt_required "namespace" "$NAMESPACE" "$OP"
mdbt_required "backup" "$BACKUP_NAME" "$OP"
mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"
mdbt_validate_dns_label "backup" "$BACKUP_NAME" "$OP"
mdbt_validate_uint "wait_timeout" "$WAIT_TIMEOUT" "$OP"
if [[ "$WAIT_TIMEOUT" == "0" ]]; then
  mdbt_fail "$OP" "wait_timeout=0 is unavailable for an in-place restore" \
    '{"stage":"validate"}' 2 INVALID_REQUEST
fi

mariadb_set_target "${K8S_CONTEXT:-}" "$NAMESPACE" \
  "${MARIADB_RESOURCE:-mariadb}" "" "${MARIADB_CONTAINER:-mariadb}"
mdbr_require_v24 "$OP"

_ambiguous() {
  mdbt_fail "$OP" "namespace does not resolve to a single database" \
    '{"stage":"target"}' 1 DATABASE_CONFIGURATION_AMBIGUOUS
}
_none() {
  mdbt_fail "$OP" "no database found in namespace" \
    '{"stage":"target"}' 1 DATABASE_NOT_FOUND
}
mariadb_autodetect_target false _ambiguous _none
MDB="$MARIADB_NAME"

CR_JSON="$(_kubectl get "$MARIADB_RESOURCE" "$MDB" -o json 2>/dev/null)" || \
  mdbt_fail "$OP" "database is unavailable" '{"stage":"target"}' 1 DATABASE_NOT_FOUND
PRIMARY_POD="$(jq -r '.status.currentPrimary // empty' <<<"$CR_JSON")"
[[ -n "$PRIMARY_POD" ]] || \
  mdbt_fail "$OP" "database is not ready" '{"stage":"target"}' 1 DATABASE_NOT_READY
mapfile -t PODS < <(mariadb_list_pods "$(mariadb_cr_replicas || true)")
ROOT_PASSWORD="$(mariadb_read_root_password "$PRIMARY_POD" "${PODS[@]}")" || \
  mdbt_fail "$OP" "database credentials are unavailable" \
    '{"stage":"target"}' 1 INTERNAL_ERROR

if ! mdbt_resolve_backup_location "$NAMESPACE" "$MDB" 2>/dev/null; then
  mdbt_fail "$OP" "backup configuration is unavailable" \
    '{"stage":"capture"}' 1 BACKUP_CONFIGURATION_UNAVAILABLE
fi

mdbt_validate_internal_or_fail "$OP" INTERNAL_ERROR \
  "restore policy is unavailable" \
  mdbt_validate_uint "max_external_connections" "$MDBR_MAX_EXTERNAL_CONNECTIONS" "$OP"
CONNECTIONS="$(mdbr_external_connections "$PRIMARY_POD" "$ROOT_PASSWORD")" || \
  mdbt_fail "$OP" "connection usage could not be read" \
    '{"stage":"connection-guard"}' 1 DATABASE_NOT_READY
CONNECTION_COUNT="$(jq -r '.total' <<<"$CONNECTIONS")"
if (( CONNECTION_COUNT > MDBR_MAX_EXTERNAL_CONNECTIONS )); then
  mdbt_fail "$OP" "standby still has external connections" \
    "$(jq -c --argjson conns "$CONNECTIONS" --argjson allowed "$MDBR_MAX_EXTERNAL_CONNECTIONS" \
      '{stage:"connection-guard",externalConnections:$conns.total,
        allowed:$allowed,accounts:($conns.accounts | map(.account))}')" \
    1 STANDBY_IN_USE
fi

_restore_data() {
  local stage="$1" changed="$2"
  jq -nc --arg namespace "$NAMESPACE" --arg backup "$BACKUP_NAME" \
    --arg stage "$stage" --argjson connections "$CONNECTION_COUNT" \
    --argjson changed "$changed" --argjson dryRun "$(mdbt_bool_json "$DRY_RUN")" \
    '{namespace:$namespace,backup:$backup,contentType:"Physical",inPlace:true,
      stage:$stage,state:(if $stage == "completed" then "COMPLETED"
        elif $changed then "FAILED" else "PLANNED" end),
      externalConnections:$connections,dryRun:$dryRun,changed:$changed}'
}

# Dry-run performs every read-only precondition that can otherwise fail after
# the database has stopped: image/PVC discovery and exact S3 object resolution.
if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  [[ -n "$(jq -r '.spec.image // empty' <<<"$CR_JSON")" ]] || \
    mdbt_fail "$OP" "database image could not be resolved" \
      "$(_restore_data capture false)" 1 INTERNAL_ERROR
  PVC_LIST="$(_mdbr_data_pvcs)" || \
    mdbt_fail "$OP" "standby data volumes could not be listed" \
      "$(_restore_data capture false)" 1 INTERNAL_ERROR
  [[ -n "$PVC_LIST" ]] || \
    mdbt_fail "$OP" "standby has no data volumes to restore" \
      "$(_restore_data capture false)" 1 INTERNAL_ERROR

  BACKUP_RC=0
  _mdbr_exact_backup_object "$BACKUP_NAME" >/dev/null || BACKUP_RC=$?
  case "$BACKUP_RC" in
    0) ;;
    2) mdbt_fail "$OP" "physical backup is not available" \
         "$(_restore_data capture false)" 1 BACKUP_NOT_FOUND ;;
    3) mdbt_fail "$OP" "physical backup source is ambiguous" \
         "$(_restore_data capture false)" 1 BACKUP_AMBIGUOUS ;;
    4) mdbt_fail "$OP" "backup configuration is unavailable" \
         "$(_restore_data capture false)" 1 BACKUP_CONFIGURATION_UNAVAILABLE ;;
    *) mdbt_fail "$OP" "backup service is unavailable" \
         "$(_restore_data capture false)" 1 BACKUP_SERVICE_UNAVAILABLE ;;
  esac

  mdbt_write_result "$(response_ok "$OP" "in-place restore plan is valid" \
    "$(_restore_data planned false)")"
  exit 0
fi

mdbt_require_confirm "$OP" "$CONFIRM"
mdbr_rebuild_standby "$OP" _restore_data
mdbt_write_result "$(response_ok "$OP" "database restored in place" \
  "$(_restore_data completed true)")"
