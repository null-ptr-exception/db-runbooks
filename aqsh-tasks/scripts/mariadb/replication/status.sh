#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/replication/status.sh
# Read-only v24 cross-cluster replication status. The operator has no topology
# object for this link, so the authoritative state is SHOW ALL SLAVES STATUS on
# this cluster's current primary. Operator status remains useful only for local
# readiness and local replicas.
# =============================================================================

OP="replication/status"

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi
# shellcheck source=../../../lib/mariadb-replication-link.sh
source "${LIB_DIR}/mariadb-replication-link.sh"

NAMESPACE="${DB_NAMESPACE:-}"
INCLUDE_PEER="${INCLUDE_PEER:-true}"

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
PEER_HOST="$(mdbr_peer_host "$NAMESPACE")"
ROOT_PASSWORD=""
LINK_STATUS='{"configured":null,"running":false,"ioRunning":null,"sqlRunning":null,"secondsBehind":null,"sourceHost":null,"sourcePort":null,"connectionName":null,"usingGtid":null,"error":"DATABASE_NOT_READY"}'

if [[ -n "$PRIMARY_POD" ]]; then
  mapfile -t PODS < <(mariadb_list_pods "$(mariadb_cr_replicas || true)")
  if ROOT_PASSWORD="$(mariadb_read_root_password "$PRIMARY_POD" "${PODS[@]}" 2>/dev/null)"; then
    LINK_STATUS="$(mdbr_replica_status "$PRIMARY_POD" "$ROOT_PASSWORD" 2>/dev/null)" || \
      LINK_STATUS='{"configured":null,"running":false,"ioRunning":null,"sqlRunning":null,"secondsBehind":null,"sourceHost":null,"sourcePort":null,"connectionName":null,"usingGtid":null,"error":"DATABASE_NOT_READY"}'
  fi
fi

LOCAL_VIEW="$(jq -nc \
  --argjson cr "$CR_JSON" \
  --argjson link "$LINK_STATUS" \
  --arg peerHost "$PEER_HOST" '
  ($cr.status.currentPrimary // null) as $cp
  | ($cr.status.replication.replicas // {}) as $replicas
  | {
      ready: any($cr.status.conditions[]?; .type == "Ready" and .status == "True"),
      currentPrimary: $cp,
      replicationConfigured: $link.configured,
      linkRunning: $link.running,
      ioRunning: $link.ioRunning,
      sqlRunning: $link.sqlRunning,
      sourceHost: $link.sourceHost,
      sourcePort: $link.sourcePort,
      sourceMatchesPeer: (
        if $link.configured == true then $link.sourceHost == $peerHost else false end
      ),
      secondsBehind: $link.secondsBehind,
      usingGtid: $link.usingGtid,
      linkError: $link.error,
      localReplicas: (
        $replicas | to_entries | map(select(.key != $cp))
        | map({pod:.key,ioRunning:(.value.slaveIORunning // false),
               sqlRunning:(.value.slaveSQLRunning // false),
               secondsBehind:(.value.secondsBehindMaster // null)})
      )
    }
')"

PEER_VIEW='{"probed":false}'
if [[ "$(mdbt_bool_json "$INCLUDE_PEER")" == "true" && \
      -n "$PRIMARY_POD" && -n "$ROOT_PASSWORD" ]]; then
  ALREADY_LINKED=false
  if [[ "$(jq -r '.configured // false' <<<"$LINK_STATUS")" == "true" && \
        "$(jq -r '.sourceHost // empty' <<<"$LINK_STATUS")" == "$PEER_HOST" ]]; then
    ALREADY_LINKED=true
  fi
  if ASSESSMENT="$(mdbr_assess "$PRIMARY_POD" "$ROOT_PASSWORD" \
    "$PEER_HOST" "$ALREADY_LINKED" 2>/dev/null)"; then
    PEER_VIEW="$(jq -c '{probed:true,reachable:true} + .' <<<"$ASSESSMENT")"
  else
    PEER_VIEW="$(jq -nc --arg reason "$(mdbr_assess_reason "$ASSESSMENT")" \
      '{probed:true,reachable:false,reason:$reason}')"
  fi
fi

DATA="$(jq -nc --arg namespace "$NAMESPACE" \
  --argjson local "$LOCAL_VIEW" --argjson peer "$PEER_VIEW" \
  '{namespace:$namespace,local:$local,peer:$peer}')"
mdbt_write_result "$(response_ok "$OP" "replication status" "$DATA")"
