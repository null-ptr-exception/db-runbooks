#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/physical-backup.sh
# Take a physical (mariabackup) backup of a namespace's MariaDB to S3/MinIO,
# driving the mariadb-operator `PhysicalBackup` path. This is the user-facing
# producer of the backups that `restore` consumes.
#
# The NAMESPACE is the database identity. The caller says only *which* namespace
# to back up (and may pick which instance / target / compression); the S3 backup
# location and credentials are resolved internally from platform conventions —
# the same `mdbt_resolve_backup_location` shared with restore — so a backup is
# written exactly where restore later looks for it (s3://db-backups/mariadb/<ns>).
#
# A PhysicalBackup with no schedule runs exactly once, immediately. The logical
# `backup` task (mariadb-dump) is a different artifact and is NOT restorable via
# `restore`; this task is the physical counterpart.
# =============================================================================

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi

# Capture the raw 'mariadb' input before mariadb.sh defaults MARIADB_NAME to
# "mariadb" at load time. Empty here means "auto-detect the namespace's instance".
MDB_INPUT="${MARIADB_NAME:-}"

# shellcheck source=../../lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"  # logging, response, k8s + generic helpers
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"              # for mariadb_autodetect_target (source auto-detect)

# Deploy-time S3/MinIO settings (MINIO_ENDPOINT, MINIO_BUCKET, ...).
mdbt_load_config

OP="physical-backup"

# --- User-facing inputs ------------------------------------------------------
NAMESPACE="${DB_NAMESPACE:-}"          # the database identity — the only required input
TARGET="${BACKUP_TARGET:-PreferReplica}"  # back up from Primary | Replica | PreferReplica
COMPRESSION="${BACKUP_COMPRESSION:-bzip2}"
CONFIRM="${CONFIRM:-false}"
DRY_RUN="${DRY_RUN:-true}"
# wait_timeout doubles as the wait switch: "0" → return without waiting; any
# positive duration (e.g. 10m) → wait up to that long for the backup to Complete.
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"
K8S_CONTEXT="${K8S_CONTEXT:-}"         # reachability hook (empty → in-cluster)

# --- Platform internals (NOT task inputs) ------------------------------------
# The S3 location is resolved by the shared helper (bucket/prefix/endpoint), and
# the credentials follow the platform convention; none is a task input.
BACKUP_NAME="${BACKUP_NAME:-}"         # auto-named below
BACKUP_REGION="${BACKUP_REGION:-us-east-1}"
BACKUP_ACCESS_SECRET="${BACKUP_ACCESS_SECRET:-minio}"
BACKUP_ACCESS_KEY="${BACKUP_ACCESS_KEY:-access-key-id}"
BACKUP_SECRET_KEY="${BACKUP_SECRET_KEY:-secret-access-key}"
# Re-export resolved location for the shared manifest builder.
BACKUP_TARGET="$TARGET"
BACKUP_COMPRESSION="$COMPRESSION"

# Confirm is required to apply; a dry run renders the plan without it.
if [[ "$(mdbt_bool_json "$DRY_RUN")" != "true" ]]; then
  mdbt_require_confirm "$OP" "$CONFIRM"
fi

# Namespace is the one input the caller must provide.
mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"

# Validate context before any kubectl call (empty → in-cluster, see restore.sh).
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

# Resolve the S3 backup location (bucket / prefix / endpoint) — the same helper
# restore reads, so this backup lands where restore later looks.
mdbt_resolve_backup_location "$NAMESPACE"

# Auto-name the backup for the caller when they didn't.
if [[ -z "$BACKUP_NAME" ]]; then
  BACKUP_NAME="${MARIADB_NAME}-$(date +%Y%m%d%H%M%S)"
fi

# Validate the resolved values (internals are trusted defaults).
mdbt_validate_dns_label "mariadb" "$MARIADB_NAME" "$OP"
mdbt_validate_dns_label "backup_name" "$BACKUP_NAME" "$OP"
mdbt_validate_enum "target" "$TARGET" "$OP" Primary Replica PreferReplica
mdbt_validate_enum "compression" "$COMPRESSION" "$OP" bzip2 gzip none
mdbt_validate_s3_bucket "backup_bucket" "$BACKUP_BUCKET" "$OP"
mdbt_validate_s3_prefix "backup_prefix" "$BACKUP_PREFIX" "$OP"
mdbt_validate_endpoint "backup_endpoint" "$BACKUP_ENDPOINT" "$OP"

MANIFEST="$(mdbt_physical_backup_manifest "$BACKUP_NAME" "$NAMESPACE" "$MARIADB_NAME")"

# backup_result <created:bool> <dryRun:bool>
backup_result() {
  jq -n \
    --arg namespace "$NAMESPACE" \
    --arg mariadb "$MARIADB_NAME" \
    --arg backupName "$BACKUP_NAME" \
    --arg bucket "$BACKUP_BUCKET" \
    --arg prefix "$BACKUP_PREFIX" \
    --arg endpoint "$BACKUP_ENDPOINT" \
    --arg target "$TARGET" \
    --arg compression "$COMPRESSION" \
    --arg manifest "$MANIFEST" \
    --argjson created "$1" \
    --argjson dry "$2" \
    '{
      namespace: $namespace,
      mariadb: $mariadb,
      backupName: $backupName,
      backup: {bucket: $bucket, prefix: $prefix, endpoint: $endpoint, contentType: "Physical"},
      target: $target,
      compression: $compression,
      restorableBy: {task: "restore", namespace: $namespace},
      dryRun: $dry,
      created: $created
    } + (if $dry then {manifest: $manifest} else {} end)'
}

backup_status_result() {
  local status_json="$1"
  backup_result true false | jq \
    --argjson status "$status_json" \
    '. + {physicalBackupStatus: $status.status, physicalBackupConditions: ($status.conditions // [])}'
}

if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" "dry run: PhysicalBackup manifest rendered for ${MARIADB_NAME}" "$(backup_result false true)")"
  exit 0
fi

# The operator only backs up a Ready source — fail clearly rather than create a
# PhysicalBackup that can never complete.
# Fetch the source spec. Merge stderr into the capture so a real failure
# (permission/connectivity) is distinguished from a genuine NotFound instead of
# both looking like "not found".
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
  mdbt_fail "$OP" "source MariaDB '${MARIADB_NAME}' must be Ready before a physical backup" \
    "$(jq -n --arg mdb "$MARIADB_NAME" --arg r "${READY:-Unknown}" '{mariadb: $mdb, ready: $r}')" 2
fi

printf '%s\n' "$MANIFEST" | _kubectl apply -f -

# wait_timeout="0" returns immediately; otherwise wait for Complete. The backup
# CR is already created at this point, so a wait timeout must NOT lose the result
# — emit a partial result (with the backup location) then exit non-zero.
if [[ "$WAIT_TIMEOUT" != "0" ]]; then
  if ! _kubectl wait --for=condition=Complete "physicalbackup/${BACKUP_NAME}" --timeout="$WAIT_TIMEOUT" >/dev/null 2>&1; then
    status_json="$(_kubectl get "physicalbackup/${BACKUP_NAME}" -o json | jq -c '.status // {}' 2>/dev/null || printf '{}')"
    mdbt_write_result "$(response_err "$OP" "PhysicalBackup ${BACKUP_NAME} was created but did not Complete within ${WAIT_TIMEOUT}" "$(backup_status_result "$status_json")" 1)"
    exit 1
  fi

  status_json="$(_kubectl get "physicalbackup/${BACKUP_NAME}" -o json | jq -c '.status // {}')"
  if jq -e '
    (.status == "Failed") or
    any(.conditions[]?; .type == "Complete" and .status == "True" and .reason == "JobFailed")
  ' <<<"$status_json" >/dev/null; then
    reason="$(jq -r '.conditions[]? | select(.type == "Complete") | .reason // empty' <<<"$status_json" | tail -1)"
    mdbt_write_result "$(response_err "$OP" "PhysicalBackup ${BACKUP_NAME} failed${reason:+: ${reason}}" "$(backup_status_result "$status_json")" 1)"
    exit 1
  fi
fi

mdbt_write_result "$(response_ok "$OP" "physical backup ${BACKUP_NAME} completed for ${MARIADB_NAME}" "$(backup_result true false)")"
