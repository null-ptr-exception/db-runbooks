#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/replication/detach.sh
# Remove this cluster's cross-cluster replication link.
#
# Runs on the STANDBY cluster and undoes exactly what `replication/attach`
# applied: the multiCluster block and the two ExternalMariaDB references. The
# database, its data, and its local replication (between its own pods) are left
# alone — this detaches the link, it does not tear down the instance.
#
# Detaching leaves a standby with a frozen copy of the data. It stops following
# the primary and drifts from that moment on, so a later re-attach is subject to
# the same assessment as any other: it may or may not still be resumable.
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

MULTICLUSTER_ENABLED="$(jq -r '.spec.multiCluster.enabled // false' <<<"$CR_JSON")"
# Member names are read from the CR rather than recomputed, so a detach removes
# what is actually wired up even if the naming convention has since changed.
mapfile -t MEMBER_REFS < <(jq -r '
  (.spec.multiCluster.members // [])[]
  | .externalMariaDbRef.name // empty
' <<<"$CR_JSON")

_data() {
  local stage="$1" changed="$2"
  jq -nc \
    --arg namespace "$NAMESPACE" \
    --arg stage "$stage" \
    --argjson wasLinked "$([[ "$MULTICLUSTER_ENABLED" == "true" ]] && echo true || echo false)" \
    --argjson refs "${#MEMBER_REFS[@]}" \
    --argjson changed "$changed" \
    --argjson dryRun "$(mdbt_bool_json "$DRY_RUN")" \
    '{
      namespace: $namespace, stage: $stage,
      wasLinked: $wasLinked, endpointRefs: $refs,
      dryRun: $dryRun, changed: $changed
    }'
}

if [[ "$MULTICLUSTER_ENABLED" != "true" && "${#MEMBER_REFS[@]}" -eq 0 ]]; then
  # Already detached. Reported as success, not an error: the requested end state
  # is the current state, and a runbook re-run should not fail on that.
  mdbt_write_result "$(response_ok "$OP" "no replication link to remove" "$(_data detach false)")"
  exit 0
fi

if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" "replication link would be removed" "$(_data plan false)")"
  exit 0
fi

mdbt_require_confirm "$OP" "$CONFIRM"

# Disable the topology before deleting the endpoints it references, so the
# operator never observes members pointing at objects that no longer exist.
if ! _kubectl patch "$MARIADB_RESOURCE" "$MDB" --type merge \
  -p '{"spec":{"multiCluster":{"enabled":false}}}' >/dev/null 2>&1; then
  mdbt_fail "$OP" "replication topology could not be disabled" \
    "$(_data detach false)" 1 INTERNAL_ERROR
fi

for ref in ${MEMBER_REFS[@]+"${MEMBER_REFS[@]}"}; do
  [[ -n "$ref" ]] || continue
  # --ignore-not-found: a partially completed earlier detach must not block this
  # one from finishing the rest.
  if ! _kubectl delete externalmariadb "$ref" --ignore-not-found >/dev/null 2>&1; then
    mdbt_fail "$OP" "replication endpoints could not be removed" \
      "$(_data detach true)" 1 INTERNAL_ERROR
  fi
done

# Finally drop the multiCluster block itself. Leaving `members` behind with only
# `enabled: false` would keep the CR pointing at ExternalMariaDB objects that no
# longer exist, and would make a second detach look like fresh work instead of
# the no-op it is. A JSON merge patch with null removes the field.
if ! _mc_err="$(_kubectl patch "$MARIADB_RESOURCE" "$MDB" --type merge \
  -p '{"spec":{"multiCluster":null}}' 2>&1 >/dev/null)"; then
  log_error "$OP" "multiCluster block could not be removed: ${_mc_err}"
  mdbt_fail "$OP" "replication topology could not be removed" \
    "$(_data detach true)" 1 INTERNAL_ERROR
fi

mdbt_write_result "$(response_ok "$OP" "replication link removed" "$(_data detach true)")"
