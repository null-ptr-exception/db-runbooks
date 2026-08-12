#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/replication/attach.sh
# Attach an existing mariadb-operator 0.24 standby to the primary in the peer
# cluster. Cross-cluster replication is runtime MariaDB state on v24: the
# operator continues to own the local instance and its local replicas, while
# this runbook owns CHANGE MASTER / START SLAVE on the standby's current primary.
#
# A read-only assessment first chooses one of two paths:
#   attach   resume from the standby's persisted gtid_slave_pos
#   rebuild  ask the peer for a fresh physical backup, restore B in place, then
#            start from the restored datadir's current GTID position
#
# Rebuild never replaces the MariaDB CR or PVCs. It is confirm-gated and refuses
# to run while clients are connected to the standby.
# =============================================================================

OP="replication/attach"

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi
# shellcheck source=../../../lib/mariadb-replication-rebuild.sh
source "${LIB_DIR}/mariadb-replication-rebuild.sh"

NAMESPACE="${DB_NAMESPACE:-}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
EXPECTED_ACTION="${EXPECTED_ACTION:-}"
PEER_AQSH_URL="${PEER_AQSH_URL:-${REPL_PEER_AQSH_URL_DEFAULT:-}}"
PEER_TOKEN_FILE="${REPL_PEER_TOKEN_FILE_DEFAULT:-/var/run/secrets/kubernetes.io/serviceaccount/token}"

mdbt_load_config
PEER_AQSH_URL="${PEER_AQSH_URL:-${REPL_PEER_AQSH_URL_DEFAULT:-}}"

mdbt_required "namespace" "$NAMESPACE" "$OP"
mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"
mdbt_validate_uint "wait_timeout" "$WAIT_TIMEOUT" "$OP"
[[ -z "$EXPECTED_ACTION" ]] || \
  mdbt_validate_enum "expected_action" "$EXPECTED_ACTION" "$OP" attach rebuild

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
    '{"stage":"assess"}' 1 DATABASE_NOT_READY

if [[ "$(jq -r '.error // empty' <<<"$LINK_STATUS")" == "MULTIPLE_REPLICATION_CONNECTIONS" ]]; then
  mdbt_fail "$OP" "standby has multiple replication connections" \
    '{"stage":"assess"}' 1 REPLICATION_CONFIGURATION_AMBIGUOUS
fi

LINK_CONFIGURED="$(jq -r '.configured // false' <<<"$LINK_STATUS")"
LINK_RUNNING="$(jq -r '.running // false' <<<"$LINK_STATUS")"
LINK_SOURCE="$(jq -r '.sourceHost // empty' <<<"$LINK_STATUS")"

# Never overwrite an unrelated replication source. Detach has the same guard.
if [[ "$LINK_CONFIGURED" == "true" && "$LINK_SOURCE" != "$PEER_HOST" ]]; then
  mdbt_fail "$OP" "standby is configured for a different replication source" \
    "$(jq -nc --arg source "$LINK_SOURCE" '{stage:"assess",sourceHost:$source}')" \
    1 REPLICATION_SOURCE_MISMATCH
fi

ALREADY_LINKED=false
if [[ "$LINK_CONFIGURED" == "true" && "$LINK_SOURCE" == "$PEER_HOST" ]]; then
  ALREADY_LINKED=true
fi

if [[ "$ALREADY_LINKED" == "true" && "$LINK_RUNNING" == "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" "standby is already attached and replicating" \
    "$(jq -nc --arg ns "$NAMESPACE" --argjson link "$LINK_STATUS" \
      --argjson dryRun "$(mdbt_bool_json "$DRY_RUN")" \
      '{namespace:$ns,stage:"attached",action:"attach",
        actionReason:"ALREADY_ATTACHED",replication:$link,
        changed:false,dryRun:$dryRun}')")"
  exit 0
fi

CONNECTIONS="$(mdbr_external_connections "$PRIMARY_POD" "$ROOT_PASSWORD")" || \
  mdbt_fail "$OP" "connection usage could not be read" \
    '{"stage":"connection-guard"}' 1 DATABASE_NOT_READY
mdbt_validate_internal_or_fail "$OP" INTERNAL_ERROR \
  "replication policy is unavailable" \
  mdbt_validate_uint "max_external_connections" "$MDBR_MAX_EXTERNAL_CONNECTIONS" "$OP"

CONNECTION_COUNT="$(jq -r '.total' <<<"$CONNECTIONS")"
if (( CONNECTION_COUNT > MDBR_MAX_EXTERNAL_CONNECTIONS )); then
  mdbt_fail "$OP" "standby still has external connections" \
    "$(jq -c --argjson conns "$CONNECTIONS" --argjson allowed "$MDBR_MAX_EXTERNAL_CONNECTIONS" \
      '{stage:"connection-guard",externalConnections:$conns.total,
        allowed:$allowed,accounts:($conns.accounts | map(.account))}')" \
    1 STANDBY_IN_USE
fi

if ! ASSESSMENT="$(mdbr_assess "$PRIMARY_POD" "$ROOT_PASSWORD" "$PEER_HOST" "$ALREADY_LINKED")"; then
  mdbt_fail "$OP" "replication state could not be assessed" \
    '{"stage":"assess"}' 1 "$(mdbr_assess_reason "$ASSESSMENT")"
fi
ACTION="$(jq -r '.action' <<<"$ASSESSMENT")"
ASSESS_REASON="$(jq -r '.reason' <<<"$ASSESSMENT")"

_assessment_data() {
  local stage="$1" changed="$2"
  jq -nc \
    --arg namespace "$NAMESPACE" \
    --arg stage "$stage" \
    --argjson assessment "$ASSESSMENT" \
    --argjson link "$LINK_STATUS" \
    --argjson connections "$CONNECTION_COUNT" \
    --argjson changed "$changed" \
    --argjson dryRun "$(mdbt_bool_json "$DRY_RUN")" \
    '{namespace:$namespace,stage:$stage,action:$assessment.action,
      actionReason:$assessment.reason,checks:$assessment.checks,
      replication:$link,externalConnections:$connections,
      dryRun:$dryRun,changed:$changed}'
}

if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" \
    "assessed standby: ${ACTION} (${ASSESS_REASON})" "$(_assessment_data assess false)")"
  exit 0
fi

mdbt_require_confirm "$OP" "$CONFIRM"
if [[ -n "$EXPECTED_ACTION" && "$EXPECTED_ACTION" != "$ACTION" ]]; then
  mdbt_fail "$OP" "assessment does not match expected_action" \
    "$(_assessment_data assess false)" 1 UNEXPECTED_ACTION
fi
if [[ "$ASSESS_REASON" == "SERVER_ID_CONFLICT" ]]; then
  mdbt_fail "$OP" "standby and primary share a server id; correct the deployment first" \
    "$(_assessment_data assess false)" 1 SERVER_ID_CONFLICT
fi

REBUILT=false
if [[ "$ACTION" == "rebuild" ]]; then
  if [[ "$WAIT_TIMEOUT" == "0" ]]; then
    mdbt_fail "$OP" "wait_timeout=0 is unavailable when the standby needs an in-place restore" \
      "$(_assessment_data assess false)" 2 INVALID_REQUEST
  fi
  [[ -n "$PEER_AQSH_URL" ]] || \
    mdbt_fail "$OP" "peer service address is not configured" \
      "$(_assessment_data assess false)" 1 PEER_CONFIGURATION_UNAVAILABLE
  mdbt_validate_url "peer_aqsh_url" "$PEER_AQSH_URL" "$OP"
  if ! PEER_TOKEN="$(mdbr_read_peer_token "$PEER_TOKEN_FILE")"; then
    mdbt_fail "$OP" "peer service authentication is unavailable" \
      "$(_assessment_data assess false)" 1 PEER_CONFIGURATION_UNAVAILABLE
  fi

  if ! PEER_BACKUP="$(mdbt_peer_call_task "$PEER_AQSH_URL" "$PEER_TOKEN" \
    "physical-backup" \
    "$(jq -nc --arg ns "$NAMESPACE" --arg timeout "${MDBR_PEER_TASK_TIMEOUT}s" \
      '{namespace:$ns,dry_run:"false",confirm:"true",wait_timeout:$timeout}')" \
    "$MDBR_PEER_TASK_TIMEOUT")"; then
    mdbt_fail "$OP" "a fresh backup could not be produced on the primary" \
      "$(_assessment_data backup false)" 1 PEER_OPERATION_FAILED
  fi
  BACKUP_NAME="$(jq -r '.backupName // empty' <<<"$PEER_BACKUP")"
  if ! (MDBT_RESULT_FILE=/dev/null; mdbt_validate_dns_label \
    "backup" "$BACKUP_NAME" "$OP") >/dev/null 2>&1; then
    mdbt_fail "$OP" "the primary returned an invalid physical backup" \
      "$(_assessment_data backup false)" 1 PEER_OPERATION_FAILED
  fi

  if ! mdbt_resolve_backup_location "$NAMESPACE" "$MDB" 2>/dev/null; then
    mdbt_fail "$OP" "backup configuration is unavailable" \
      "$(_assessment_data backup false)" 1 BACKUP_CONFIGURATION_UNAVAILABLE
  fi
  mdbr_rebuild_standby "$OP" _assessment_data
  REBUILT=true

  # The restored primary pod may have changed identity and always needs a fresh
  # credential read before SQL is issued.
  CR_JSON="$(_kubectl get "$MARIADB_RESOURCE" "$MDB" -o json 2>/dev/null)" || \
    mdbt_fail "$OP" "database is unavailable after restore" \
      "$(_assessment_data wire true)" 1 DATABASE_NOT_READY
  PRIMARY_POD="$(jq -r '.status.currentPrimary // empty' <<<"$CR_JSON")"
  [[ -n "$PRIMARY_POD" ]] || \
    mdbt_fail "$OP" "database has no current primary after restore" \
      "$(_assessment_data wire true)" 1 DATABASE_NOT_READY
  mapfile -t PODS < <(mariadb_list_pods "$(mariadb_cr_replicas || true)")
  ROOT_PASSWORD="$(mariadb_read_root_password "$PRIMARY_POD" "${PODS[@]}")" || \
    mdbt_fail "$OP" "database credentials are unavailable after restore" \
      "$(_assessment_data wire true)" 1 INTERNAL_ERROR
fi

GTID_MODE=slave_pos
[[ "$REBUILT" == "true" ]] && GTID_MODE=current_pos
if ! mdbr_replica_configure "$PRIMARY_POD" "$ROOT_PASSWORD" \
  "$PEER_HOST" "$MDBR_PEER_PORT" "$GTID_MODE"; then
  mdbt_fail "$OP" "replication link could not be configured" \
    "$(_assessment_data wire true)" 1 LINK_NOT_ESTABLISHED
fi

ELAPSED=0
while :; do
  if LINK_STATUS="$(mdbr_replica_status "$PRIMARY_POD" "$ROOT_PASSWORD" 2>/dev/null)" \
    && [[ "$(jq -r '.running // false' <<<"$LINK_STATUS")" == "true" ]] \
    && [[ "$(jq -r '.sourceHost // empty' <<<"$LINK_STATUS")" == "$PEER_HOST" ]]; then
    break
  fi
  if (( ELAPSED >= WAIT_TIMEOUT )); then
    mdbt_fail "$OP" "replication did not start within the wait" \
      "$(_assessment_data verify true)" 1 LINK_NOT_ESTABLISHED
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [[ "$REBUILT" == "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" \
    "standby restored in place and replicating" "$(_assessment_data attached true)")"
else
  mdbt_write_result "$(response_ok "$OP" \
    "standby attached and replicating" "$(_assessment_data attached true)")"
fi
