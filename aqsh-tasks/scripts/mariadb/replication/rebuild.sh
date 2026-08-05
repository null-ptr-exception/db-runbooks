#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/replication/rebuild.sh
# Re-seed a standby that can no longer resume replication, then attach it.
#
# Reached when `replication/attach` reports REBUILD_REQUIRED. Runs on the
# STANDBY cluster.
#
#   1. ask the primary's AQSH for a FRESH physical backup, and wait for it
#   2. capture the standby's own spec
#   3. delete the standby (CR + data volumes)
#   4. recreate it from the captured spec + bootstrapFrom.s3 + multiCluster
#   5. wait for Ready, then for replication to actually run
#
# Step 1 is a fresh backup rather than the newest object already in the bucket
# on purpose: a stale backup restores the standby to a position that may again
# predate the primary's retained binlog, failing the very check that sent us
# here. Paying for one backup is cheaper than discovering that after the
# restore.
#
# THIS DESTROYS THE STANDBY'S DATA. Step 3 is irreversible, and everything
# after it depends on the backup taken in step 1 being restorable. There is no
# rollback: if step 4 fails, the standby is gone and must be recreated by
# whatever provisioned it originally.
#
# The MariaDB CR is recreated rather than restored in place because neither the
# current-generation operator (bootstrapFrom.s3) nor the legacy hand-rolled path
# can seed an existing instance — both only ever bootstrap a new one.
# =============================================================================

OP="replication/rebuild"

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi
# shellcheck source=../../../lib/mariadb-replication-link.sh
source "${LIB_DIR}/mariadb-replication-link.sh"
# The peer transport (mdbt_peer_call_task) comes from mariadb-task-common.sh via
# the line above. Deliberately NOT blue-green's bg_peer_call_task: that variant
# injects peer_aqsh_url/peer_token, which physical-backup does not declare and
# aqsh therefore rejects with 400.

# --- inputs ------------------------------------------------------------------
NAMESPACE="${DB_NAMESPACE:-}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"       # seconds; covers backup + restore + link
# The caller's own bearer token, valid at the peer because both clusters
# validate against the same TokenReview backend. Never stored.
PEER_TOKEN="${PEER_TOKEN:-}"
# Optional: the platform sets REPL_PEER_AQSH_URL_DEFAULT once per deployment.
# Accepted as an input so a deployment that has not set it is still operable.
PEER_AQSH_URL="${PEER_AQSH_URL:-${REPL_PEER_AQSH_URL_DEFAULT:-}}"
PEER_TIMEOUT="${REPL_PEER_TASK_TIMEOUT_DEFAULT:-900}"

mdbt_load_config
# mdbt_load_config may have supplied the URL default; re-resolve if still empty.
PEER_AQSH_URL="${PEER_AQSH_URL:-${REPL_PEER_AQSH_URL_DEFAULT:-}}"

mdbt_required "namespace" "$NAMESPACE" "$OP"
mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"
mdbt_validate_uint "wait_timeout" "$WAIT_TIMEOUT" "$OP"
mdbt_required "peer_token" "$PEER_TOKEN" "$OP"
if [[ -z "$PEER_AQSH_URL" ]]; then
  mdbt_fail "$OP" "peer service address is not configured" \
    '{"stage":"preflight"}' 1 PEER_CONFIGURATION_UNAVAILABLE
fi
mdbt_validate_url "peer_aqsh_url" "$PEER_AQSH_URL" "$OP"

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
_require_capable() {
  local confident_rc=0 ext_rc=0 phys_rc=0
  mdb_operator_group_is_confident || confident_rc=$?
  mdb_crd_status externalmariadbs || ext_rc=$?
  mdb_crd_status physicalbackups || phys_rc=$?
  if [[ "$confident_rc" -eq 2 || "$ext_rc" -eq 2 || "$phys_rc" -eq 2 ]]; then
    mdbt_fail "$OP" "replication capability could not be verified" \
      '{"stage":"capability"}' 2 INTERNAL_ERROR
  fi
  if [[ "$confident_rc" -ne 0 || "$ext_rc" -ne 0 || "$phys_rc" -ne 0 \
        || "$(mdb_operator_group)" != "k8s.mariadb.com" ]]; then
    mdbt_fail "$OP" "standby rebuild is unavailable for this database" \
      '{"stage":"capability"}' 2 OPERATION_UNAVAILABLE
  fi
}
_require_capable

CR_JSON="$(_kubectl get "$MARIADB_RESOURCE" "$MDB" -o json 2>/dev/null)" || \
  mdbt_fail "$OP" "database is unavailable" '{"stage":"target"}' 1 DATABASE_NOT_FOUND

# A standby with no replication configuration is not something this task can
# rebuild into a standby — it would be inventing a topology the deployment
# never declared.
if [[ "$(jq -r '.spec.replication.enabled // false' <<<"$CR_JSON")" != "true" ]]; then
  mdbt_fail "$OP" "database is not configured for replication" \
    '{"stage":"preflight"}' 1 REPLICATION_CONFIGURATION_UNAVAILABLE
fi

# Backup location: the standby's own policy, which points at the bucket shared
# with the primary. Same resolution every backup/restore task uses.
if ! mdbt_resolve_backup_location "$NAMESPACE" "$MDB" 2>/dev/null; then
  mdbt_fail "$OP" "backup configuration is unavailable" \
    '{"stage":"preflight"}' 1 BACKUP_CONFIGURATION_UNAVAILABLE
fi

# --- connection guard --------------------------------------------------------
# Stricter here than in attach: this task always destroys the data.
PRIMARY_POD="$(jq -r '.status.currentPrimary // empty' <<<"$CR_JSON")"
CONNECTION_COUNT=0
if [[ -n "$PRIMARY_POD" ]]; then
  mapfile -t PODS < <(mariadb_list_pods "$(mariadb_cr_replicas || true)")
  if ROOT_PASSWORD="$(mariadb_read_root_password "$PRIMARY_POD" "${PODS[@]}" 2>/dev/null)"; then
    if CONNECTIONS="$(mdbr_external_connections "$PRIMARY_POD" "$ROOT_PASSWORD")"; then
      CONNECTION_COUNT="$(jq -r '.total' <<<"$CONNECTIONS")"
    else
      mdbt_fail "$OP" "connection usage could not be read" \
        '{"stage":"connection-guard"}' 1 DATABASE_NOT_READY
    fi
  fi
fi
# A standby too broken to answer at all has no sessions to protect; that is the
# normal case for a rebuild and must not block it.
if (( CONNECTION_COUNT > MDBR_MAX_EXTERNAL_CONNECTIONS )); then
  mdbt_fail "$OP" "standby still has external connections" \
    "$(jq -nc --argjson n "$CONNECTION_COUNT" '{stage:"connection-guard", externalConnections:$n}')" \
    1 STANDBY_IN_USE
fi

PEER_HOST="$(mdbr_peer_host "$NAMESPACE")"

# --- refuse a rebuild that isn't needed --------------------------------------
# Called directly, this task would destroy a perfectly good standby that was
# merely never wired up. If the assessment says the link is resumable, stop and
# point at the cheap path instead.
#
# An assessment that cannot be COMPLETED does not block: a standby too broken to
# answer is the normal reason to be here. (A peer that is unreachable does not
# get to proceed far either way — step 1 needs it to take the backup.)
if [[ -n "${ROOT_PASSWORD:-}" && -n "$PRIMARY_POD" ]]; then
  _already_linked="$(jq -r '.spec.multiCluster.enabled // false' <<<"$CR_JSON")"
  if ASSESSMENT="$(mdbr_assess "$PRIMARY_POD" "$ROOT_PASSWORD" "$PEER_HOST" "$_already_linked" 2>/dev/null)"; then
    if [[ "$(jq -r '.action' <<<"$ASSESSMENT")" == "attach" ]]; then
      mdbt_fail "$OP" "standby can resume replication without a rebuild; run replication/attach" \
        "$(jq -c '{stage: "assess"} + .' <<<"$ASSESSMENT")" 1 REBUILD_NOT_REQUIRED
    fi
  fi
fi

PRIMARY_MEMBER="${NAMESPACE}${MDBR_PEER_SUFFIX}"
# Must equal the CR's own name — the operator's webhook rejects a topology whose
# members do not include the current cluster. Only the referenced
# ExternalMariaDB object may be named freely.
LOCAL_MEMBER="$MDB"
LOCAL_ENDPOINT="${MDB}-local"
LOCAL_HOST="$(mariadb_primary_service_name).${NAMESPACE}.svc.cluster.local"
# In-cluster Service: the database's own port, not the peer port.
LOCAL_PORT="$(jq -r '.spec.port // 3306' <<<"$CR_JSON")"
# Rebuild is the ONLY chance to fix a server-id collision: the field is
# immutable, so an already-deployed standby that shares ids with its primary
# can never be repaired in place — MariaDB refuses to replicate at all
# (errno 1593). Recreating the CR is exactly when a distinct range can be set.
STANDBY_SERVER_ID_START="${REPL_STANDBY_SERVER_ID_START_DEFAULT:-100}"
# The operator's S3 client rejects an endpoint carrying a scheme ("Endpoint url
# cannot have fully qualified paths"), so bootstrapFrom needs the bare host:port
# plus an explicit TLS flag derived from the original scheme. restore.sh already
# does this; the resolver's raw value must not be passed straight through.
OPERATOR_S3_ENDPOINT="$(mdbt_operator_s3_endpoint "$BACKUP_ENDPOINT")"
OPERATOR_S3_TLS="$(mdbt_operator_s3_tls_enabled "$BACKUP_ENDPOINT")"
BACKUP_NAME="${BACKUP_NAME:-replication-rebuild-${NAMESPACE}}"

_data() {
  local stage="$1" changed="$2"
  jq -nc \
    --arg namespace "$NAMESPACE" --arg stage "$stage" \
    --argjson connections "$CONNECTION_COUNT" \
    --argjson changed "$changed" \
    --argjson dryRun "$(mdbt_bool_json "$DRY_RUN")" \
    '{namespace: $namespace, stage: $stage, externalConnections: $connections,
      dryRun: $dryRun, changed: $changed}'
}

if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" \
    "standby would be re-seeded from a fresh primary backup" \
    "$(jq -c '. + {steps: [
        "request a fresh physical backup on the primary",
        "delete the standby database and its data volumes",
        "recreate it seeded from that backup",
        "re-establish replication and verify it runs"
      ]}' <<<"$(_data plan false)")")"
  exit 0
fi

mdbt_require_confirm "$OP" "$CONFIRM"

# --- step 1: fresh backup on the primary -------------------------------------
# Runs on the primary's AQSH: only that cluster can back its own database up.
# Payload carries exactly the fields physical-backup declares — no more. aqsh
# validates task inputs strictly and rejects an unknown field with 400.
if ! mdbt_peer_call_task "$PEER_AQSH_URL" "$PEER_TOKEN" "physical-backup" \
  "$(jq -nc --arg ns "$NAMESPACE" --arg t "$WAIT_TIMEOUT" \
    '{namespace: $ns, dry_run: "false", confirm: "true", wait_timeout: ($t + "s")}')" \
  "$PEER_TIMEOUT" >/dev/null; then
  # Nothing has been destroyed yet — failing here is safe and recoverable.
  mdbt_fail "$OP" "a fresh backup could not be produced on the primary" \
    "$(_data backup false)" 1 PEER_OPERATION_FAILED
fi

# --- step 2: capture the standby's own shape ---------------------------------
# Everything the deployment declared is preserved; only bootstrapFrom and
# multiCluster are added. Recreating from a hand-written template instead would
# silently drop resources, tolerations, TLS, storage class, and so on.
REBUILD_MANIFEST="$(jq \
  --arg primaryMember "$PRIMARY_MEMBER" --arg localMember "$LOCAL_MEMBER" \
  --arg localRef "$LOCAL_ENDPOINT" --argjson serverIdStart "$STANDBY_SERVER_ID_START" \
  --arg bucket "$BACKUP_BUCKET" --arg prefix "$BACKUP_PREFIX" \
  --arg endpoint "$OPERATOR_S3_ENDPOINT" --argjson tls "$OPERATOR_S3_TLS" \
  --arg region "$BACKUP_REGION" \
  --arg accessSecret "$BACKUP_ACCESS_SECRET" --arg accessKey "$BACKUP_ACCESS_KEY" \
  --arg secretSecret "$BACKUP_SECRET_ACCESS_SECRET" --arg secretKey "$BACKUP_SECRET_KEY" \
  '{
    apiVersion: .apiVersion,
    kind: .kind,
    metadata: {
      name: .metadata.name,
      namespace: .metadata.namespace,
      labels: (.metadata.labels // {}),
      annotations: ((.metadata.annotations // {})
        | del(."kubectl.kubernetes.io/last-applied-configuration"))
    },
    spec: (.spec + {
      bootstrapFrom: {
        s3: {
          bucket: $bucket, prefix: $prefix, endpoint: $endpoint, region: $region,
          tls: {enabled: $tls},
          accessKeyIdSecretKeyRef: {name: $accessSecret, key: $accessKey},
          secretAccessKeySecretKeyRef: {name: $secretSecret, key: $secretKey}
        },
        backupContentType: "Physical"
      },
      multiCluster: {
        enabled: true,
        primary: $primaryMember,
        members: [
          {name: $primaryMember, externalMariaDbRef: {name: $primaryMember}},
          {name: $localMember, externalMariaDbRef: {name: $localRef}}
        ]
      },
      replication: (.spec.replication + {serverIdStartIndex: $serverIdStart})
    })
  }' <<<"$CR_JSON")"

ROOT_SECRET_NAME="$(jq -r '.spec.rootPasswordSecretKeyRef.name // empty' <<<"$CR_JSON")"
ROOT_SECRET_KEY="$(jq -r '.spec.rootPasswordSecretKeyRef.key // empty' <<<"$CR_JSON")"
if [[ -z "$ROOT_SECRET_NAME" || -z "$ROOT_SECRET_KEY" ]]; then
  mdbt_fail "$OP" "database credential configuration is unavailable" \
    "$(_data capture false)" 1 INTERNAL_ERROR
fi

# --- step 3: destroy ---------------------------------------------------------
# Past this point there is no way back.
if ! _delete_err="$(_kubectl delete "$MARIADB_RESOURCE" "$MDB" --wait=true \
  --timeout="${WAIT_TIMEOUT}s" 2>&1 >/dev/null)"; then
  log_error "$OP" "standby delete failed: ${_delete_err}"
  mdbt_fail "$OP" "standby could not be removed" \
    "$(_data destroy false)" 1 INTERNAL_ERROR
fi

# The StatefulSet's PVCs outlive the CR by design. They must go too: a surviving
# datadir makes the operator skip bootstrapFrom entirely and the standby comes
# back carrying exactly the stale data this task exists to replace — a silent
# wrong-data success, the worst possible outcome here.
#
# Selected two ways (operator label, and the StatefulSet's
# <template>-<mdb>-<ordinal> naming) because a label selector that matches
# nothing "succeeds" while deleting nothing. Whatever the deployment's
# volumeClaimTemplate is called, one of the two finds it.
_stale_pvcs() {
  {
    _kubectl get pvc -l "app.kubernetes.io/instance=${MDB}" -o name 2>/dev/null || true
    _kubectl get pvc -o name 2>/dev/null | grep -E "/[^/]*-${MDB}-[0-9]+$" || true
  } | sed 's#^persistentvolumeclaim/##' | sed '/^$/d' | sort -u
}

mapfile -t STALE_PVCS < <(_stale_pvcs)
for pvc in ${STALE_PVCS[@]+"${STALE_PVCS[@]}"}; do
  if ! _kubectl delete pvc "$pvc" --wait=true --timeout="${WAIT_TIMEOUT}s" >/dev/null 2>&1; then
    mdbt_fail "$OP" "standby storage could not be removed" \
      "$(_data destroy true)" 1 INTERNAL_ERROR
  fi
done

# Fail closed. If anything still matches, the recreate below would bootstrap
# from a surviving datadir instead of the backup, so stop before that happens.
mapfile -t REMAINING_PVCS < <(_stale_pvcs)
if (( ${#REMAINING_PVCS[@]} > 0 )); then
  mdbt_fail "$OP" "standby storage could not be removed" \
    "$(_data destroy true)" 1 INTERNAL_ERROR
fi

# --- step 4: recreate --------------------------------------------------------
if ! _endpoint_err="$(_kubectl apply -f - 2>&1 >/dev/null <<EOF
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
)"; then
  log_error "$OP" "endpoint registration failed: ${_endpoint_err}"
  mdbt_fail "$OP" "replication endpoints could not be registered" \
    "$(_data recreate true)" 1 INTERNAL_ERROR
fi

# Capture stderr into the task log rather than discarding it. The public result
# stays sanitized, but a failure here happens AFTER the standby is deleted —
# "could not be recreated" with no further detail is not enough to act on.
# `2>&1 >/dev/null` order matters: stderr to the capture, stdout to nowhere.
if ! _apply_err="$(printf '%s\n' "$REBUILD_MANIFEST" | _kubectl apply -f - 2>&1 >/dev/null)"; then
  log_error "$OP" "standby recreate failed: ${_apply_err}"
  mdbt_fail "$OP" "standby could not be recreated" \
    "$(_data recreate true)" 1 RESTORE_FAILED
fi

if ! mdbt_wait_mariadb_ready "$MDB" "${WAIT_TIMEOUT}s" >/dev/null 2>&1; then
  mdbt_fail "$OP" "standby did not become ready after restore" \
    "$(_data recreate true)" 1 RESTORE_TIMEOUT
fi

# --- step 5: verify the link actually runs -----------------------------------
DEADLINE_REACHED=true
ELAPSED=0
while (( ELAPSED < WAIT_TIMEOUT )); do
  LIVE_JSON="$(_kubectl get "$MARIADB_RESOURCE" "$MDB" -o json 2>/dev/null)" || LIVE_JSON='{}'
  # The link is the current primary's OWN slave status — the local replicas are
  # running regardless of whether the cross-cluster link came up.
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
  mdbt_fail "$OP" "replication did not start after restore" \
    "$(_data verify true)" 1 LINK_NOT_ESTABLISHED
fi

mdbt_write_result "$(response_ok "$OP" \
  "standby re-seeded and replicating" "$(_data attached true)")"
