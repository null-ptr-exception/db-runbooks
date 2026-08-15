#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/migration/sourcedb-backup.sh
# Take a physical (mariabackup) backup of a migration source MariaDB to a
# caller-specified external MinIO endpoint.
#
# Unlike physical-backup.sh — which resolves S3 credentials purely from
# platform deploy-time config — this task's MinIO credentials are caller
# overridable (the backup destination for a migration is often outside the
# platform's own MinIO), falling back to this deployment's MINIO_*_DEFAULT
# internal config when omitted, same as migration/preflight.
#
# Secure credential handling:
#   The minio_secret_key arrives as the env var MINIO_SECRET_KEY. It is
#   written immediately to a temporary Kubernetes Secret in the target
#   namespace, then the env var is unset. The PhysicalBackup CR references
#   that Secret directly; the raw value never appears in logs or result JSON.
#   The temporary Secret is deleted on task exit (EXIT trap) — so wait_timeout
#   must be non-zero: the operator needs the Secret to still exist when it
#   reads it, and this script has no way to know that has happened other than
#   waiting for the PhysicalBackup to reach Complete.
#
# The backup name defaults to <mariadb>-migration-<timestamp>. The S3 prefix
# defaults to mariadb/<namespace> (compatible with the platform restore task).
# =============================================================================

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi

# Capture the raw 'mariadb' input before mariadb.sh defaults MARIADB_NAME.
MDB_INPUT="${MARIADB_NAME:-}"

# shellcheck source=../../../lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"
# shellcheck source=../../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"

# Deploy-time config: MINIO_ENDPOINT_DEFAULT / MINIO_ACCESS_KEY_DEFAULT /
# MINIO_SECRET_KEY_DEFAULT / MINIO_BUCKET_DEFAULT (plus a plain MINIO_ENDPOINT
# this script does not use — see caller-value capture below).
#
# That plain MINIO_ENDPOINT is the platform's own internal MinIO, used by the
# non-migration backup/restore tasks — sourcing this file would silently
# overwrite whatever the caller passed as THIS task's minio_endpoint, since
# both share the identical variable name for two different purposes. The
# four caller values are captured before sourcing and restored immediately
# after so the config file can only ever populate the `_DEFAULT` names.
_CALLER_MINIO_ENDPOINT="${MINIO_ENDPOINT:-}"
_CALLER_MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-}"
_CALLER_MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-}"
_CALLER_MINIO_BUCKET="${MINIO_BUCKET:-}"
[[ -f /etc/aqsh/config/mariadb.env ]] && source /etc/aqsh/config/mariadb.env
MINIO_ENDPOINT="$_CALLER_MINIO_ENDPOINT"
MINIO_ACCESS_KEY="$_CALLER_MINIO_ACCESS_KEY"
MINIO_SECRET_KEY="$_CALLER_MINIO_SECRET_KEY"
MINIO_BUCKET="$_CALLER_MINIO_BUCKET"

OP="migration/sourcedb-backup"

# --- Task inputs --------------------------------------------------------------
NAMESPACE="${DB_NAMESPACE:-}"
# MinIO options resolve task input -> deploy-time internal config
# (MINIO_*_DEFAULT) -> fail clearly if still unset.
MINIO_ENDPOINT="${MINIO_ENDPOINT:-${MINIO_ENDPOINT_DEFAULT:-}}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-${MINIO_ACCESS_KEY_DEFAULT:-}}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-${MINIO_SECRET_KEY_DEFAULT:-}}"
MINIO_BUCKET="${MINIO_BUCKET:-${MINIO_BUCKET_DEFAULT:-}}"
TARGET="${BACKUP_TARGET:-PreferReplica}"
COMPRESSION="${BACKUP_COMPRESSION:-bzip2}"
CONFIRM="${CONFIRM:-false}"
DRY_RUN="${DRY_RUN:-true}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"
K8S_CONTEXT="${K8S_CONTEXT:-}"
BACKUP_NAME="${BACKUP_NAME:-}"

# S3 internals not exposed as task inputs (env-overridable for advanced ops).
BACKUP_REGION="${BACKUP_REGION:-us-east-1}"
# Key names inside the temp secret — follow the same convention as the platform.
_CRED_ACCESS_KEY_NAME="access-key-id"
_CRED_SECRET_KEY_NAME="secret-access-key"

# Re-export for the shared manifest builder.
BACKUP_TARGET="$TARGET"
BACKUP_COMPRESSION="$COMPRESSION"

# --- Input validation --------------------------------------------------------
if [[ "$(mdbt_bool_json "$DRY_RUN")" != "true" ]]; then
  mdbt_require_confirm "$OP" "$CONFIRM"
fi

mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"
mdbt_required "minio_endpoint" "$MINIO_ENDPOINT" "$OP"
mdbt_required "minio_access_key" "$MINIO_ACCESS_KEY" "$OP"
mdbt_required "minio_secret_key" "$MINIO_SECRET_KEY" "$OP"
mdbt_required "minio_bucket" "$MINIO_BUCKET" "$OP"
mdbt_validate_s3_bucket "minio_bucket" "$MINIO_BUCKET" "$OP"
mdbt_validate_endpoint "minio_endpoint" "$MINIO_ENDPOINT" "$OP"

# wait_timeout=0 would return before the operator has necessarily read the
# temporary credential Secret, which is deleted on this process's exit.
if [[ "$WAIT_TIMEOUT" == "0" ]]; then
  mdbt_fail "$OP" \
    "wait_timeout=0 is not supported: the MinIO credential Secret is temporary and deleted when this task exits, so the operator must be given time to consume it" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2
fi

if [[ -n "$K8S_CONTEXT" ]]; then
  mdbt_validate_context "context" "$K8S_CONTEXT" "$OP"
fi

# Wire the cluster/namespace target through the canonical entry point.
mariadb_set_target "$K8S_CONTEXT" "$NAMESPACE" "${MARIADB_RESOURCE:-mariadb}" "$MDB_INPUT"

# --- MariaDB auto-detect -----------------------------------------------------
_on_ambiguous() {
  mdbt_fail "$OP" "several MariaDB instances in '${NAMESPACE}'; set 'mariadb' to choose which one to back up" \
    "$(jq -n --arg c "$1" '{candidates: ($c | split(","))}')" 2
}
_on_none() {
  mdbt_fail "$OP" "no MariaDB instance found in '${NAMESPACE}' to back up" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2
}

if [[ -z "$MDB_INPUT" ]]; then
  mariadb_autodetect_target false _on_ambiguous _on_none
else
  MARIADB_NAME="$MDB_INPUT"
fi

mdbt_validate_dns_label "mariadb" "$MARIADB_NAME" "$OP"

# Auto-name with a migration marker so these are distinguishable in the bucket.
if [[ -z "$BACKUP_NAME" ]]; then
  BACKUP_NAME="${MARIADB_NAME}-migration-$(date +%Y%m%d%H%M%S)"
fi
mdbt_validate_dns_label "backup_name" "$BACKUP_NAME" "$OP"

mdbt_validate_enum "target" "$TARGET" "$OP" Primary Replica PreferReplica
mdbt_validate_enum "compression" "$COMPRESSION" "$OP" bzip2 gzip none

# --- Resolve backup location from task inputs --------------------------------
BACKUP_BUCKET="$MINIO_BUCKET"
BACKUP_PREFIX="${BACKUP_PREFIX:-mariadb/${NAMESPACE}}"
BACKUP_ENDPOINT="$MINIO_ENDPOINT"

mdbt_validate_s3_prefix "backup_prefix" "$BACKUP_PREFIX" "$OP"

# --- Result helpers ----------------------------------------------------------
_backup_result() {
  local created="$1" dry="$2"
  jq -n \
    --arg namespace "$NAMESPACE" \
    --arg mariadb "$MARIADB_NAME" \
    --arg backupName "$BACKUP_NAME" \
    --arg endpoint "$BACKUP_ENDPOINT" \
    --arg bucket "$BACKUP_BUCKET" \
    --arg prefix "$BACKUP_PREFIX" \
    --arg target "$TARGET" \
    --arg compression "$COMPRESSION" \
    --argjson created "$created" \
    --argjson dry "$dry" \
    '{
      namespace: $namespace,
      mariadb: $mariadb,
      backupName: $backupName,
      backup: {endpoint: $endpoint, bucket: $bucket, prefix: $prefix, contentType: "Physical"},
      target: $target,
      compression: $compression,
      dryRun: $dry,
      created: $created
    }'
}

# --- Dry run: render manifest without creating any resources -----------------
if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  # Use a placeholder secret name for the dry-run manifest preview.
  BACKUP_ACCESS_SECRET="migration-backup-creds-preview"
  BACKUP_ACCESS_KEY="$_CRED_ACCESS_KEY_NAME"
  BACKUP_SECRET_KEY="$_CRED_SECRET_KEY_NAME"
  MANIFEST="$(mdbt_physical_backup_manifest "$BACKUP_NAME" "$NAMESPACE" "$MARIADB_NAME")"

  mdbt_write_result "$(response_ok "$OP" \
    "dry run: PhysicalBackup manifest rendered for ${MARIADB_NAME}" \
    "$(_backup_result false true | jq --arg m "$MANIFEST" '. + {manifest: $m}')")"
  exit 0
fi

# --- Check source MariaDB is Ready -------------------------------------------
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

# --- Create temporary K8s Secret with MinIO credentials ----------------------
# Name includes a random suffix (not just a timestamp) so concurrent calls in
# the same second can't collide; created atomically (no dry-run|apply) so a
# collision fails loudly instead of silently overwriting another run's Secret.
TEMP_SECRET_NAME="migration-backup-creds-$(date +%Y%m%d%H%M%S)-${RANDOM}-$$"

_cleanup_temp_secret() {
  if [[ -n "${TEMP_SECRET_NAME:-}" ]]; then
    _kubectl delete secret "$TEMP_SECRET_NAME" --ignore-not-found >/dev/null 2>&1 || true
  fi
}
# Covers only "never got as far as an applied CR" failures below (secret
# create, apply) — safe to clean up immediately since the operator was never
# given a CR that could reference this Secret.
trap _cleanup_temp_secret EXIT

# Built via jq and piped through stdin rather than --from-literal, which
# would put the raw MinIO secret key into kubectl's own argv (readable by
# any same-UID process via ps/procfs).
_TEMP_SECRET_MANIFEST="$(jq -n \
  --arg name "$TEMP_SECRET_NAME" \
  --arg accessKeyName "$_CRED_ACCESS_KEY_NAME" \
  --arg accessKeyValue "$MINIO_ACCESS_KEY" \
  --arg secretKeyName "$_CRED_SECRET_KEY_NAME" \
  --arg secretKeyValue "$MINIO_SECRET_KEY" \
  '{apiVersion:"v1", kind:"Secret", metadata:{name:$name}, type:"Opaque",
    data:{($accessKeyName):($accessKeyValue|@base64), ($secretKeyName):($secretKeyValue|@base64)}}')"
if ! printf '%s\n' "$_TEMP_SECRET_MANIFEST" | _kubectl create -f - >/dev/null; then
  mdbt_fail "$OP" "failed to create temporary credential secret '${TEMP_SECRET_NAME}'" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1
fi
unset _TEMP_SECRET_MANIFEST

# Clear the raw secret key from memory — the operator reads it from the Secret.
unset MINIO_SECRET_KEY

# Wire credential references for the manifest builder.
# BACKUP_ACCESS_SECRET/KEY/SECRET_KEY are read by mdbt_physical_backup_manifest
# in mariadb-task-common.sh, not referenced again in this file.
# shellcheck disable=SC2034
BACKUP_ACCESS_SECRET="$TEMP_SECRET_NAME"
# shellcheck disable=SC2034
BACKUP_ACCESS_KEY="$_CRED_ACCESS_KEY_NAME"
# shellcheck disable=SC2034
BACKUP_SECRET_KEY="$_CRED_SECRET_KEY_NAME"

# --- Build and apply PhysicalBackup CR ---------------------------------------
MANIFEST="$(mdbt_physical_backup_manifest "$BACKUP_NAME" "$NAMESPACE" "$MARIADB_NAME")"
printf '%s\n' "$MANIFEST" | _kubectl apply -f -

# The CR now exists and references the temp Secret — stop the blanket
# EXIT-trap cleanup. Only a confirmed terminal state (Complete condition
# reached, below) deletes it now; a wait-timeout leaves it in place.
trap - EXIT

# --- Wait for completion -----------------------------------------------------
# wait_timeout=0 is rejected above, so this always waits: the temp credential
# Secret must outlive the operator's read of it, and Complete is the only
# signal this script has that the read already happened.
if ! _kubectl wait --for=condition=Complete "physicalbackup/${BACKUP_NAME}" \
    --timeout="$WAIT_TIMEOUT" >/dev/null 2>&1; then
  status_json="$(_kubectl get "physicalbackup/${BACKUP_NAME}" -o json \
    | jq -c '.status // {}' 2>/dev/null || printf '{}')"
  # Do NOT delete the temp Secret here — the PhysicalBackup job may still be
  # running and the operator may not have consumed the S3 credentials yet.
  # Deleting it now would turn a slow-but-recoverable backup into a
  # guaranteed failure. It's named clearly enough for manual cleanup once
  # the backup either completes or is confirmed abandoned.
  mdbt_write_result "$(response_err "$OP" \
    "PhysicalBackup ${BACKUP_NAME} was created but did not Complete within ${WAIT_TIMEOUT}; temporary credential secret '${TEMP_SECRET_NAME}' was intentionally left in place (may still be needed) — clean it up manually once the backup is confirmed to have completed or been abandoned" \
    "$(_backup_result true false | jq \
      --argjson s "$status_json" \
      '. + {physicalBackupStatus: $s.status, physicalBackupConditions: ($s.conditions // [])}')" 1)"
  exit 1
fi

# The Complete condition was reached (success or failure) — the operator has
# finished with the credentials either way, so it's safe to clean up now.
_cleanup_temp_secret

status_json="$(_kubectl get "physicalbackup/${BACKUP_NAME}" -o json \
  2>/dev/null | jq -c '.status // {}' 2>/dev/null || printf '{}')"
if jq -e '
  (.status == "Failed") or
  any(.conditions[]?; .type == "Complete" and .status == "True" and .reason == "JobFailed")
' <<<"$status_json" >/dev/null; then
  reason="$(jq -r '.conditions[]? | select(.type == "Complete") | .reason // empty' \
    <<<"$status_json" | tail -1)"
  mdbt_write_result "$(response_err "$OP" \
    "PhysicalBackup ${BACKUP_NAME} failed${reason:+: ${reason}}" \
    "$(_backup_result true false | jq \
      --argjson s "$status_json" \
      '. + {physicalBackupStatus: $s.status, physicalBackupConditions: ($s.conditions // [])}')" 1)"
  exit 1
fi

mdbt_write_result "$(response_ok "$OP" \
  "migration backup ${BACKUP_NAME} completed for ${MARIADB_NAME}" \
  "$(_backup_result true false)")"
