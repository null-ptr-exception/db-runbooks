#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/replication/attach.sh
# Attach an already-deployed standby to the primary in the peer cluster.
#
# Both databases exist already: this task does not provision anything. It runs
# on the STANDBY cluster and answers one question before doing anything else —
# can this standby resume replication from the primary as it stands, or has its
# history moved too far for that?
#
#   action=attach    wire multiCluster + ExternalMariaDB, resume replication
#   action=rebuild   history is unusable; the standby must be re-seeded
#
# Two-phase by design, using the same dry_run/confirm gate every mutating task
# in this repo already has — the first call assesses and reports, the second
# executes. No extra flags to learn.
#
# Only the standby cluster is touched. The primary needs no change: a MariaDB
# replica initiates its own replication, and the multiCluster wiring that names
# it lives entirely in this cluster's CRs (same as blue-green/create, which
# never patches Blue either).
# =============================================================================

OP="replication/attach"

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi
# shellcheck source=../../../lib/mariadb-replication-link.sh
source "${LIB_DIR}/mariadb-replication-link.sh"

# --- inputs ------------------------------------------------------------------
# Public surface is the namespace plus the per-call operational decisions.
# The peer address, port, connection policy, member naming, and credential
# references are all platform-resolved and deliberately not task inputs.
NAMESPACE="${DB_NAMESPACE:-}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"   # seconds, as in switch-primary
# Optional guard, same pattern as blue-green/switchover's expected_* inputs:
# empty means "do whatever the assessment says", a value means "stop if the
# assessment disagrees". Protects against a dry run that said `attach` turning
# into a destructive rebuild by the time the real call lands.
EXPECTED_ACTION="${EXPECTED_ACTION:-}"

mdbt_load_config

mdbt_required "namespace" "$NAMESPACE" "$OP"
mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"
mdbt_validate_uint "wait_timeout" "$WAIT_TIMEOUT" "$OP"
[[ -z "$EXPECTED_ACTION" ]] || mdbt_validate_enum "expected_action" "$EXPECTED_ACTION" "$OP" attach rebuild

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

# --- capability gate ---------------------------------------------------------
# Cross-cluster replication is built on ExternalMariaDB + multiCluster, which
# only exist on the current-generation operator. Fail closed on an uncertain
# probe rather than reporting a discovery error as an unsupported deployment.
_require_capable() {
  local confident_rc=0 ext_rc=0
  mdb_operator_group_is_confident || confident_rc=$?
  mdb_crd_status externalmariadbs || ext_rc=$?
  if [[ "$confident_rc" -eq 2 || "$ext_rc" -eq 2 ]]; then
    mdbt_fail "$OP" "replication capability could not be verified" \
      '{"stage":"capability"}' 2 INTERNAL_ERROR
  fi
  if [[ "$confident_rc" -ne 0 || "$ext_rc" -ne 0 || "$(mdb_operator_group)" != "k8s.mariadb.com" ]]; then
    mdbt_fail "$OP" "cross-cluster replication is unavailable for this database" \
      '{"stage":"capability"}' 2 OPERATION_UNAVAILABLE
  fi
}
_require_capable

# --- local target ------------------------------------------------------------
CR_JSON="$(_kubectl get "$MARIADB_RESOURCE" "$MDB" -o json 2>/dev/null)" || \
  mdbt_fail "$OP" "database is unavailable" '{"stage":"target"}' 1 DATABASE_NOT_FOUND

PRIMARY_POD="$(jq -r '.status.currentPrimary // empty' <<<"$CR_JSON")"
[[ -n "$PRIMARY_POD" ]] || \
  mdbt_fail "$OP" "database is not ready" '{"stage":"target"}' 1 DATABASE_NOT_READY

mapfile -t PODS < <(mariadb_list_pods "$(mariadb_cr_replicas || true)")
ROOT_PASSWORD="$(mariadb_read_root_password "$PRIMARY_POD" "${PODS[@]}")" || \
  mdbt_fail "$OP" "database credentials are unavailable" \
    '{"stage":"target"}' 1 INTERNAL_ERROR

# The root Secret reference comes from the CR itself, not a naming guess: it is
# the authoritative source and the ExternalMariaDB objects must point at the
# same material the database actually uses.
ROOT_SECRET_NAME="$(jq -r '.spec.rootPasswordSecretKeyRef.name // empty' <<<"$CR_JSON")"
ROOT_SECRET_KEY="$(jq -r '.spec.rootPasswordSecretKeyRef.key // empty' <<<"$CR_JSON")"
if [[ -z "$ROOT_SECRET_NAME" || -z "$ROOT_SECRET_KEY" ]]; then
  mdbt_fail "$OP" "database credential configuration is unavailable" \
    '{"stage":"target"}' 1 INTERNAL_ERROR
fi

PEER_HOST="$(mdbr_peer_host "$NAMESPACE")"

# Already wired into the topology? Two things follow. First, a healthy link
# means this call is a no-op: re-running a runbook step must not fail because
# the end state already holds (detach behaves the same way). Second, the
# local-write check does not apply — the operator's own post-restore writes
# carry the standby's server_id, so a linked standby always looks "written to".
ALREADY_LINKED="$(jq -r '.spec.multiCluster.enabled // false' <<<"$CR_JSON")"
LINK_RUNNING="$(jq -r '
  (.status.currentPrimary // "") as $cp
  | ((.status.replication.replicas // {})[$cp] // null) as $link
  | ($link != null and ($link.slaveIORunning // false) and ($link.slaveSQLRunning // false))
' <<<"$CR_JSON")"

if [[ "$ALREADY_LINKED" == "true" && "$LINK_RUNNING" == "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" "standby is already attached and replicating" \
    "$(jq -nc --arg ns "$NAMESPACE" \
      '{namespace: $ns, stage: "attached", action: "attach",
        actionReason: "ALREADY_ATTACHED", changed: false,
        dryRun: ($ENV.DRY_RUN // "true" | . != "false")}')")"
  exit 0
fi

# --- guard: nobody may be using the standby ----------------------------------
# Checked before the assessment, not after: if the outcome turns out to be
# rebuild, the data is destroyed, and an open session means someone is relying
# on it right now. An unreadable process list is an error, never an implicit
# "nobody is connected".
CONNECTIONS="$(mdbr_external_connections "$PRIMARY_POD" "$ROOT_PASSWORD")" || \
  mdbt_fail "$OP" "connection usage could not be read" \
    '{"stage":"connection-guard"}' 1 DATABASE_NOT_READY

# A malformed policy value must not silently become an arithmetic error that
# skips the guard entirely.
mdbt_validate_internal_or_fail "$OP" INTERNAL_ERROR "replication policy is unavailable" \
  mdbt_validate_uint "max_external_connections" "$MDBR_MAX_EXTERNAL_CONNECTIONS" "$OP"

CONNECTION_COUNT="$(jq -r '.total' <<<"$CONNECTIONS")"
if (( CONNECTION_COUNT > MDBR_MAX_EXTERNAL_CONNECTIONS )); then
  mdbt_fail "$OP" "standby still has external connections" \
    "$(jq -c --argjson conns "$CONNECTIONS" --argjson allowed "$MDBR_MAX_EXTERNAL_CONNECTIONS" \
      '{stage: "connection-guard", externalConnections: $conns.total,
        allowed: $allowed, accounts: ($conns.accounts | map(.account))}')" \
    1 STANDBY_IN_USE
fi

# --- assess ------------------------------------------------------------------
ASSESSMENT="$(mdbr_assess "$PRIMARY_POD" "$ROOT_PASSWORD" "$PEER_HOST" "$ALREADY_LINKED")" || \
  mdbt_fail "$OP" "replication state could not be assessed" \
    '{"stage":"assess"}' 1 "${MDBR_ASSESS_ERROR:-INTERNAL_ERROR}"

ACTION="$(jq -r '.action' <<<"$ASSESSMENT")"
ASSESS_REASON="$(jq -r '.reason' <<<"$ASSESSMENT")"

_assessment_data() {
  local stage="$1" changed="$2"
  jq -c \
    --arg namespace "$NAMESPACE" \
    --arg stage "$stage" \
    --argjson assessment "$ASSESSMENT" \
    --argjson connections "$CONNECTION_COUNT" \
    --argjson changed "$changed" \
    --argjson dryRun "$(mdbt_bool_json "$DRY_RUN")" \
    -n '{
      namespace: $namespace,
      stage: $stage,
      action: $assessment.action,
      actionReason: $assessment.reason,
      checks: $assessment.checks,
      externalConnections: $connections,
      dryRun: $dryRun,
      changed: $changed
    }'
}

# --- phase 1: report and stop ------------------------------------------------
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

# --- phase 2: execute --------------------------------------------------------
if [[ "$ACTION" == "rebuild" ]]; then
  # Deliberately not automatic, and not a flag on this task: re-seeding destroys
  # the standby's data and needs the primary's AQSH to produce a fresh backup.
  # Run replication/rebuild explicitly for that.
  mdbt_fail "$OP" "standby cannot resume replication; run replication/rebuild to re-seed it" \
    "$(_assessment_data assess false)" 1 REBUILD_REQUIRED
fi

PRIMARY_MEMBER="${NAMESPACE}${MDBR_PEER_SUFFIX}"
# The local member's NAME must equal this MariaDB CR's own name: the operator's
# validating webhook rejects the topology otherwise ("current cluster <name> is
# not defined as a multi-cluster member"). Only the ExternalMariaDB object it
# references may be named freely.
LOCAL_MEMBER="$MDB"
LOCAL_ENDPOINT="${MDB}-local"
LOCAL_HOST="$(mariadb_primary_service_name).${NAMESPACE}.svc.cluster.local"
# The local endpoint is an in-cluster Service, so it uses the database's own
# port — NOT the peer port, which in some deployments is a gateway/nodePort
# standing in front of the remote cluster.
LOCAL_PORT="$(jq -r '.spec.port // 3306' <<<"$CR_JSON")"

# ExternalMariaDB objects first: multiCluster members reference them, so
# applying the reference before its target would leave the CR briefly dangling.
if ! _kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: k8s.mariadb.com/v1alpha1
kind: ExternalMariaDB
metadata:
  name: ${PRIMARY_MEMBER}
  namespace: ${NAMESPACE}
spec:
  host: ${PEER_HOST}
  port: ${MDBR_PEER_PORT}
  username: root
  passwordSecretKeyRef:
    name: ${ROOT_SECRET_NAME}
    key: ${ROOT_SECRET_KEY}
---
apiVersion: k8s.mariadb.com/v1alpha1
kind: ExternalMariaDB
metadata:
  name: ${LOCAL_ENDPOINT}
  namespace: ${NAMESPACE}
spec:
  host: ${LOCAL_HOST}
  port: ${LOCAL_PORT}
  username: root
  passwordSecretKeyRef:
    name: ${ROOT_SECRET_NAME}
    key: ${ROOT_SECRET_KEY}
EOF
then
  mdbt_fail "$OP" "replication endpoints could not be registered" \
    "$(_assessment_data wire false)" 1 INTERNAL_ERROR
fi

if ! _patch_err="$(_kubectl patch "$MARIADB_RESOURCE" "$MDB" --type merge -p "$(jq -nc \
  --arg primary "$PRIMARY_MEMBER" --arg local "$LOCAL_MEMBER" --arg localRef "$LOCAL_ENDPOINT" \
  '{spec: {multiCluster: {
      enabled: true,
      primary: $primary,
      members: [
        {name: $primary, externalMariaDbRef: {name: $primary}},
        {name: $local, externalMariaDbRef: {name: $localRef}}
      ]
   }}}')" 2>&1 >/dev/null)"
then
  log_error "$OP" "multiCluster patch failed: ${_patch_err}"
  mdbt_fail "$OP" "replication topology could not be applied" \
    "$(_assessment_data wire false)" 1 INTERNAL_ERROR
fi

# --- verify ------------------------------------------------------------------
# Attach only succeeds once the link is actually running. A patch that reconciles
# into a broken replica is a failure, not a success with a caveat.
DEADLINE_REACHED=true
ELAPSED=0
while (( ELAPSED < WAIT_TIMEOUT )); do
  LIVE_JSON="$(_kubectl get "$MARIADB_RESOURCE" "$MDB" -o json 2>/dev/null)" || LIVE_JSON='{}'
  # The cross-cluster link is the CURRENT PRIMARY's own slave status: once
  # attached, this cluster's primary is itself a replica of the peer, and that
  # is the only entry in status.replication.replicas describing the link. The
  # other entries are this cluster's local replicas following their own primary
  # — they are healthy whether or not the link exists, so requiring "all
  # replicas running" reports success on a standby that never attached.
  if jq -e '
    (.status.currentPrimary // "") as $cp
    | ((.status.replication.replicas // {})[$cp] // null) as $link
    | $link != null and $link.slaveIORunning == true and $link.slaveSQLRunning == true
  ' <<<"$LIVE_JSON" >/dev/null 2>&1; then
    DEADLINE_REACHED=false
    break
  fi
  sleep 5
  ELAPSED=$(( ELAPSED + 5 ))
done

if [[ "$DEADLINE_REACHED" == "true" ]]; then
  mdbt_fail "$OP" "replication did not start within the wait" \
    "$(_assessment_data verify true)" 1 LINK_NOT_ESTABLISHED
fi

mdbt_write_result "$(response_ok "$OP" \
  "standby attached and replicating" "$(_assessment_data attached true)")"
