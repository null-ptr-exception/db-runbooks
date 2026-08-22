#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/replication/detach.sh
# Remove the v24 cross-cluster SQL link from the standby's current primary.
# The MariaDB CR, StatefulSet, PVCs, data, and operator-managed local replicas
# are left untouched.
# =============================================================================

OP="replication/detach"

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi
# shellcheck source=../../../lib/mariadb-replication-link.sh
source "${LIB_DIR}/mariadb-replication-link.sh"

NAMESPACE="${DB_NAMESPACE:-}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"

mdbt_load_config
mdbt_required "namespace" "$NAMESPACE" "$OP"
mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"
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

PEER_HOST="$(mdbr_peer_host "$NAMESPACE")"
LINK_STATUS="$(mdbr_replica_status "$PRIMARY_POD" "$ROOT_PASSWORD")" || \
  mdbt_fail "$OP" "replication state could not be read" \
    '{"stage":"detach"}' 1 DATABASE_NOT_READY
LINK_CONFIGURED="$(jq -r '.configured // false' <<<"$LINK_STATUS")"
LINK_SOURCE="$(jq -r '.sourceHost // empty' <<<"$LINK_STATUS")"

_data() {
  local stage="$1" changed="$2"
  jq -nc --arg namespace "$NAMESPACE" --arg stage "$stage" \
    --argjson link "$LINK_STATUS" --argjson changed "$changed" \
    --argjson dryRun "$(mdbt_bool_json "$DRY_RUN")" \
    '{namespace:$namespace,stage:$stage,wasLinked:($link.configured == true),
      replication:$link,dryRun:$dryRun,changed:$changed}'
}

if [[ "$(jq -r '.error // empty' <<<"$LINK_STATUS")" == "MULTIPLE_REPLICATION_CONNECTIONS" ]]; then
  mdbt_fail "$OP" "standby has multiple replication connections" \
    "$(_data detach false)" 1 REPLICATION_CONFIGURATION_AMBIGUOUS
fi
if [[ "$LINK_CONFIGURED" != "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" "no replication link to remove" \
    "$(_data detached false)")"
  exit 0
fi
if [[ "$LINK_SOURCE" != "$PEER_HOST" ]]; then
  mdbt_fail "$OP" "standby is configured for a different replication source" \
    "$(_data detach false)" 1 REPLICATION_SOURCE_MISMATCH
fi

if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" "replication link would be removed" \
    "$(_data plan false)")"
  exit 0
fi

mdbt_require_confirm "$OP" "$CONFIRM"
if ! mdbr_replica_stop_reset "$PRIMARY_POD" "$ROOT_PASSWORD"; then
  mdbt_fail "$OP" "replication link could not be removed" \
    "$(_data detach false)" 1 LINK_NOT_REMOVED
fi

LINK_STATUS="$(mdbr_replica_status "$PRIMARY_POD" "$ROOT_PASSWORD")" || \
  mdbt_fail "$OP" "replication state could not be verified" \
    "$(_data detach true)" 1 LINK_NOT_REMOVED
if [[ "$(jq -r '.configured // false' <<<"$LINK_STATUS")" == "true" ]]; then
  mdbt_fail "$OP" "replication link is still configured" \
    "$(_data detach true)" 1 LINK_NOT_REMOVED
fi

mdbt_write_result "$(response_ok "$OP" "replication link removed" \
  "$(_data detached true)")"
