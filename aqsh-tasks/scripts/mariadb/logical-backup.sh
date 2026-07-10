#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/logical-backup.sh
# Take a logical (mariadb-dump) backup of a namespace's MariaDB to S3/MinIO,
# driving the mariadb-operator `Backup` CR. This is the operator-managed logical
# counterpart of `physical-backup`, and — unlike `physical-backup` — it works on
# BOTH operator generations: the `Backup` CRD exists on the legacy mmontes-era
# operator as well as the current k8s.mariadb.com one.
#
# The NAMESPACE is the database identity. The caller says only *which* namespace
# to back up (and may pick which instance); the S3 backup location and
# credentials are resolved internally from platform conventions, exactly like
# physical-backup — but written to a DISTINCT prefix (mariadb-logical/<ns>) so
# logical artifacts never collide with the physical ones that `restore` /
# bootstrapFrom read from mariadb/<ns>.
#
# A Backup with no schedule runs exactly once, immediately. This artifact is
# restored by the logical restore path (operator `Restore` CR), not by the
# physical `restore` task.
#
# NOTE: the exec-based `backup` task (backup/backup-mariadb.sh) is a separate,
# operator-INDEPENDENT logical backup (mariadb-dump piped straight to MinIO). It
# stays as the zero-dependency fallback; this task is the operator-managed one.
# =============================================================================

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi

# Capture the raw 'mariadb' input before mariadb.sh defaults MARIADB_NAME at load.
MDB_INPUT="${MARIADB_NAME:-}"

# shellcheck source=../../lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"  # logging, response, k8s, operator-profile + helpers
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"              # for mariadb_autodetect_target (source auto-detect)

# Deploy-time S3/MinIO settings (MINIO_ENDPOINT, MINIO_BUCKET, ...).
mdbt_load_config

OP="logical-backup"

# --- User-facing inputs ------------------------------------------------------
NAMESPACE="${DB_NAMESPACE:-}"          # the database identity — the only required input
CONFIRM="${CONFIRM:-false}"
DRY_RUN="${DRY_RUN:-true}"
# wait_timeout doubles as the wait switch: "0" → return without waiting; any
# positive duration (e.g. 10m) → wait up to that long for the backup to Complete.
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"
K8S_CONTEXT="${K8S_CONTEXT:-}"         # reachability hook (empty → in-cluster)

# --- Platform internals (NOT task inputs) ------------------------------------
BACKUP_NAME="${BACKUP_NAME:-}"         # auto-named below
BACKUP_REGION="${BACKUP_REGION:-us-east-1}"
BACKUP_ACCESS_SECRET="${BACKUP_ACCESS_SECRET:-minio}"
BACKUP_ACCESS_KEY="${BACKUP_ACCESS_KEY:-access-key-id}"
BACKUP_SECRET_KEY="${BACKUP_SECRET_KEY:-secret-access-key}"

# Confirm is required to apply; a dry run renders the plan without it.
if [[ "$(mdbt_bool_json "$DRY_RUN")" != "true" ]]; then
  mdbt_require_confirm "$OP" "$CONFIRM"
fi

# Namespace is the one input the caller must provide.
mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"

# Validate context before any kubectl call (empty → in-cluster).
if [[ -n "$K8S_CONTEXT" ]]; then
  mdbt_validate_context "context" "$K8S_CONTEXT" "$OP"
fi

# Wire the cluster/namespace target through the canonical entry point.
mariadb_set_target "$K8S_CONTEXT" "$NAMESPACE" "$MARIADB_RESOURCE" "$MDB_INPUT"

# Resolve which instance to back up: explicit 'mariadb' input, else the
# namespace's single instance. Never guess across several.
_on_ambiguous() {
  mdbt_fail "$OP" "several MariaDB instances in '${NAMESPACE}'; set 'mariadb' to choose which one to back up" \
    "$(jq -n --arg c "$1" '{candidates: ($c | split(","))}')" 2
}
_on_none() {
  mdbt_fail "$OP" "no MariaDB instance found in '${NAMESPACE}' to back up" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2
}
if [[ -z "$MDB_INPUT" ]]; then
  mariadb_autodetect_target false _on_ambiguous _on_none   # sets MARIADB_NAME or exits
else
  MARIADB_NAME="$MDB_INPUT"
fi

# Resolve the S3 location (bucket / endpoint), then override the prefix to the
# logical convention so logical backups land under their own prefix, separate
# from the physical ones restore/bootstrapFrom read from mariadb/<ns>.
mdbt_resolve_backup_location "$NAMESPACE"
BACKUP_PREFIX="${LOGICAL_BACKUP_PREFIX:-mariadb-logical/${NAMESPACE}}"

# Auto-name the backup for the caller when they didn't.
if [[ -z "$BACKUP_NAME" ]]; then
  BACKUP_NAME="${MARIADB_NAME}-logical-$(date +%Y%m%d%H%M%S)"
fi

# Validate the resolved values (internals are trusted defaults).
mdbt_validate_dns_label "mariadb" "$MARIADB_NAME" "$OP"
mdbt_validate_dns_label "backup_name" "$BACKUP_NAME" "$OP"
mdbt_validate_s3_bucket "backup_bucket" "$BACKUP_BUCKET" "$OP"
mdbt_validate_s3_prefix "backup_prefix" "$BACKUP_PREFIX" "$OP"
mdbt_validate_endpoint "backup_endpoint" "$BACKUP_ENDPOINT" "$OP"

MANIFEST="$(mdbt_logical_backup_manifest "$BACKUP_NAME" "$NAMESPACE" "$MARIADB_NAME")"

# backup_result <created:bool> <dryRun:bool>
backup_result() {
  jq -n \
    --arg namespace "$NAMESPACE" \
    --arg mariadb "$MARIADB_NAME" \
    --arg backupName "$BACKUP_NAME" \
    --arg bucket "$BACKUP_BUCKET" \
    --arg prefix "$BACKUP_PREFIX" \
    --arg endpoint "$BACKUP_ENDPOINT" \
    --arg manifest "$MANIFEST" \
    --argjson created "$1" \
    --argjson dry "$2" \
    '{
      namespace: $namespace,
      mariadb: $mariadb,
      backupName: $backupName,
      backup: {bucket: $bucket, prefix: $prefix, endpoint: $endpoint, contentType: "Logical"},
      restorableBy: {task: "logical-restore", namespace: $namespace},
      dryRun: $dry,
      created: $created
    } + (if $dry then {manifest: $manifest} else {} end)'
}

backup_status_result() {
  local status_json="$1"
  backup_result true false | jq \
    --argjson status "$status_json" \
    '. + {backupStatus: ($status.conditions // [])}'
}

if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" "dry run: Backup manifest rendered for ${MARIADB_NAME}" "$(backup_result false true)")"
  exit 0
fi

# The `Backup` CRD must exist on this cluster — turn a would-be `no matches for
# kind "Backup"` into an actionable message. (Present on both generations, but
# this guards a broken/partial install.)
mdb_require_crd backups "$OP" "install the mariadb-operator CRDs" || exit 1

# The operator only backs up a Ready source — fail clearly rather than create a
# Backup that can never complete. Merge stderr so a real failure is distinguished
# from a genuine NotFound.
if ! SOURCE_JSON="$(_kubectl get mariadb "$MARIADB_NAME" -o json 2>&1)"; then
  if [[ "$SOURCE_JSON" == *NotFound* || "$SOURCE_JSON" == *"not found"* ]]; then
    mdbt_fail "$OP" "source MariaDB '${MARIADB_NAME}' not found in '${NAMESPACE}'" \
      "$(jq -n --arg ns "$NAMESPACE" --arg mdb "$MARIADB_NAME" '{namespace: $ns, mariadb: $mdb}')" 2
  fi
  mdbt_fail "$OP" "failed to query source MariaDB '${MARIADB_NAME}': ${SOURCE_JSON}" \
    "$(jq -n --arg ns "$NAMESPACE" --arg mdb "$MARIADB_NAME" '{namespace: $ns, mariadb: $mdb}')" 1
fi
READY="$(jq -r '.status.conditions[]? | select(.type == "Ready") | .status' <<<"$SOURCE_JSON" | tail -1)"
if [[ "$READY" != "True" ]]; then
  mdbt_fail "$OP" "source MariaDB '${MARIADB_NAME}' must be Ready before a logical backup" \
    "$(jq -n --arg mdb "$MARIADB_NAME" --arg r "${READY:-Unknown}" '{mariadb: $mdb, ready: $r}')" 2
fi

printf '%s\n' "$MANIFEST" | _kubectl apply -f -

# wait_timeout="0" returns immediately; otherwise wait for Complete. The backup
# CR is already created at this point, so a wait timeout must NOT lose the result.
if [[ "$WAIT_TIMEOUT" != "0" ]]; then
  if ! _kubectl wait --for=condition=Complete "backup/${BACKUP_NAME}" --timeout="$WAIT_TIMEOUT" >/dev/null 2>&1; then
    status_json="$(_kubectl get "backup/${BACKUP_NAME}" -o json | jq -c '.status // {}' 2>/dev/null || printf '{}')"
    mdbt_write_result "$(response_err "$OP" "Backup ${BACKUP_NAME} was created but did not Complete within ${WAIT_TIMEOUT}" "$(backup_status_result "$status_json")" 1)"
    exit 1
  fi
fi

mdbt_write_result "$(response_ok "$OP" "logical backup ${BACKUP_NAME} completed for ${MARIADB_NAME}" "$(backup_result true false)")"
