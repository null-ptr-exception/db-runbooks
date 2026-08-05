#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/replication/status.sh
# Read-only view of this cluster's cross-cluster replication link.
#
# Runs on either side and reports what that side can see: whether it is wired
# into a multiCluster topology, whether its replication threads are running,
# how far behind it is, and — when the peer is reachable — the same
# attach/rebuild assessment `replication/attach` would make, so the state can be
# checked without arming a mutating task.
#
# Safe to poll. Touches nothing.
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
# Probing the peer costs a cross-cluster round trip; skip it when only the local
# view is wanted (e.g. a tight monitoring loop).
INCLUDE_PEER="${INCLUDE_PEER:-true}"

mdbt_load_config

mdbt_required "namespace" "$NAMESPACE" "$OP"
mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"

mariadb_set_target "${K8S_CONTEXT:-}" "$NAMESPACE" "${MARIADB_RESOURCE:-mariadb}" "" "${MARIADB_CONTAINER:-mariadb}"

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

# --- local view --------------------------------------------------------------
# The cross-cluster link and this cluster's internal replication are two
# different things, and status.replication.replicas holds BOTH:
#
#   replicas[<currentPrimary>]  the link — once attached, this cluster's primary
#                               is itself a replica of the peer
#   replicas[<other pods>]      local replicas following their own primary,
#                               healthy whether or not the link exists
#
# Reading them together (e.g. "are all replicas running?") reports a healthy
# link on a standby that was never attached, which is how this was wrong before.
LOCAL_VIEW="$(jq -c '
  (.status.currentPrimary // "") as $cp
  | (.status.replication.replicas // {}) as $replicas
  | ($replicas[$cp] // null) as $link
  | {
      ready: any(.status.conditions[]?; .type == "Ready" and .status == "True"),
      multiClusterEnabled: (.spec.multiCluster.enabled // false),
      desiredPrimary: (.spec.multiCluster.primary // null),
      currentPrimary: (.status.currentMultiClusterPrimary // null),
      linkRunning: (
        $link != null
        and ($link.slaveIORunning // false)
        and ($link.slaveSQLRunning // false)
      ),
      secondsBehind: (if $link == null then null else ($link.secondsBehindMaster // null) end),
      # NB: no `select` here. `select(. != "")` yields EMPTY, not null, when the
      # condition fails — which makes the whole object construction produce no
      # output at all. It only bites when the link is HEALTHY (empty error), so
      # an unlinked standby looks fine and a working one returns nothing.
      linkError: (
        if $link == null then null
        else (($link.lastIOError // "") | if . == "" then null else . end)
        end
      ),
      localReplicas: (
        $replicas
        | to_entries
        | map(select(.key != $cp))
        | map({
            pod: .key,
            ioRunning: (.value.slaveIORunning // false),
            sqlRunning: (.value.slaveSQLRunning // false),
            secondsBehind: (.value.secondsBehindMaster // null)
          })
      )
    }
' <<<"$CR_JSON")"

# --- peer view (optional) ----------------------------------------------------
PEER_VIEW='{"probed":false}'
if [[ "$(mdbt_bool_json "$INCLUDE_PEER")" == "true" ]]; then
  PRIMARY_POD="$(jq -r '.status.currentPrimary // empty' <<<"$CR_JSON")"
  if [[ -n "$PRIMARY_POD" ]]; then
    mapfile -t PODS < <(mariadb_list_pods "$(mariadb_cr_replicas || true)")
    if ROOT_PASSWORD="$(mariadb_read_root_password "$PRIMARY_POD" "${PODS[@]}" 2>/dev/null)"; then
      PEER_HOST="$(mdbr_peer_host "$NAMESPACE")"
      # Pass the linked state, same as attach: an already-attached standby
      # carries the operator's own post-restore writes and would otherwise be
      # reported as needing a rebuild while replicating perfectly.
      ALREADY_LINKED="$(jq -r '.spec.multiCluster.enabled // false' <<<"$CR_JSON")"
      if ASSESSMENT="$(mdbr_assess "$PRIMARY_POD" "$ROOT_PASSWORD" "$PEER_HOST" "$ALREADY_LINKED" 2>/dev/null)"; then
        PEER_VIEW="$(jq -c '{probed: true, reachable: true} + .' <<<"$ASSESSMENT")"
      else
        # A peer that cannot be reached or read is reported as such — status
        # never silently downgrades an unknown into a healthy-looking answer.
        # The reason comes from the captured output, not MDBR_ASSESS_ERROR,
        # which is lost across the command substitution.
        PEER_VIEW="$(jq -nc --arg reason "$(mdbr_assess_reason "$ASSESSMENT")" \
          '{probed: true, reachable: false, reason: $reason}')"
      fi
    fi
  fi
fi

DATA="$(jq -nc \
  --arg namespace "$NAMESPACE" \
  --argjson local "$LOCAL_VIEW" \
  --argjson peer "$PEER_VIEW" \
  '{namespace: $namespace, local: $local, peer: $peer}')"

mdbt_write_result "$(response_ok "$OP" "replication status" "$DATA")"
