#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/restore.sh
# Restore a MariaDB instance from a physical (mariabackup) backup in S3/MinIO,
# optionally to a point in time.
#
# User-oriented surface: the caller says *what* to restore (namespace, optional
# point-in-time), not *where/how* it is stored. Everything a managed database
# controls — credentials, S3 endpoint/region/credentials, the backup location,
# the engine version, and the storage size — is resolved internally from
# platform conventions or from the source instance, and is overridable only as
# an advanced option.
#
# AWS-style semantics: a restore always provisions a NEW MariaDB instance and
# never overwrites in place (RestoreDBInstanceFromDBSnapshot /
# RestoreDBInstanceToPointInTime). It drives the mariadb-operator
# `spec.bootstrapFrom` restore path — the same machinery blue-green/bootstrap
# uses — but without the replication / multi-cluster wiring. With target_time,
# `bootstrapFrom.targetRecoveryTime` performs point-in-time recovery; without
# it, the latest backup under the prefix is restored.
#
# NOTE: the per-namespace backup prefix (mariadb/<namespace>) is a forward-
# looking convention. Until the physical-backup task writes to that layout,
# point `backup_prefix`/`backup_bucket` at where the backup actually lives.
# The source must be a mariadb-operator PhysicalBackup / mariabackup layout;
# the logical `backup` task is not a valid source.
# =============================================================================

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi

# shellcheck source=../../lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"  # pulls in logging, response, k8s + generic helpers
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"              # for mariadb_resolve_name (source auto-detect)

OP="restore"

# --- User-facing inputs ------------------------------------------------------
NAMESPACE="${DB_NAMESPACE:-}"          # the only required input
TARGET_TIME="${TARGET_TIME:-}"         # optional: omit → latest backup; set → PITR
TARGET="${RESTORE_TARGET:-}"           # optional: auto-generated when empty
IMAGE="${RESTORE_IMAGE:-}"             # optional: derived from the source when empty
STORAGE_SIZE="${STORAGE_SIZE:-}"       # optional: derived from the source when empty
CONFIRM="${CONFIRM:-false}"
DRY_RUN="${DRY_RUN:-true}"
WAIT_READY="${WAIT_READY:-true}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"
K8S_CONTEXT="${K8S_CONTEXT:-}"

# --- Advanced overrides (default to the platform convention) -----------------
BACKUP_BUCKET="${BACKUP_BUCKET:-db-backups}"
BACKUP_PREFIX="${BACKUP_PREFIX:-}"     # defaulted to mariadb/<namespace> below
BACKUP_ENDPOINT="${BACKUP_ENDPOINT:-minio.db-ops.svc.cluster.local:9000}"

# --- Platform internals (NOT user-facing) ------------------------------------
ROOT_SECRET_NAME="mariadb"
ROOT_SECRET_KEY="password"
BACKUP_REGION="us-east-1"
BACKUP_ACCESS_SECRET="minio"
BACKUP_ACCESS_KEY="access-key-id"
BACKUP_SECRET_KEY="secret-access-key"
REPLICAS="1"                           # restore is standalone by design
DEFAULT_STORAGE_SIZE="1Gi"             # only used when the source instance is gone

# shellcheck disable=SC2034  # consumed by _kubectl in k8s.sh (sourced indirectly)
K8S_NAMESPACE="$NAMESPACE"

# Confirm is required to apply; a dry run renders the plan without it.
if [[ "$(mdbt_bool_json "$DRY_RUN")" != "true" ]]; then
  mdbt_require_confirm "$OP" "$CONFIRM"
fi

# Namespace is the one input the caller must provide.
mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"

# Per-namespace backup location convention.
BACKUP_PREFIX="${BACKUP_PREFIX:-mariadb/${NAMESPACE}}"

# Name the restored instance for the caller when they didn't.
if [[ -z "$TARGET" ]]; then
  TARGET="${NAMESPACE}-restore-$(date +%Y%m%d%H%M%S)"
fi

# Resolve the engine version (and storage) for the restored instance:
#  - explicit `source`             → derive from that instance
#  - exactly one MariaDB instance  → derive from it
#  - several, all the same image   → use that version (restore's own clones, etc.)
#  - mixed versions / none         → fail asking for `source`/`image` (never guess)
SOURCE_NAME="${RESTORE_SOURCE:-}"
if [[ -z "$SOURCE_NAME" && ( -z "$IMAGE" || -z "$STORAGE_SIZE" ) ]]; then
  if SOURCE_NAME="$(mariadb_resolve_name)"; then :; else SOURCE_NAME=""; fi
fi

if [[ -z "$IMAGE" ]]; then
  if [[ -n "$SOURCE_NAME" ]]; then
    IMAGE="$(_kubectl get mariadb "$SOURCE_NAME" -o jsonpath='{.spec.image}' 2>/dev/null || true)"
  else
    # No single source (multiple instances or none): a physical restore is
    # version-sensitive, so accept a derived version only when every instance
    # agrees — a namespace should not run mixed versions outside a blue-green
    # upgrade, and that window is exactly when the caller must disambiguate.
    NS_IMAGES="$(_kubectl get mariadb -o jsonpath='{range .items[*]}{.spec.image}{"\n"}{end}' 2>/dev/null | sed '/^$/d' | sort -u || true)"
    NS_IMAGE_COUNT="$(printf '%s\n' "$NS_IMAGES" | grep -c . || true)"
    if [[ "$NS_IMAGE_COUNT" -eq 1 ]]; then
      IMAGE="$NS_IMAGES"
    elif [[ "$NS_IMAGE_COUNT" -gt 1 ]]; then
      mdbt_fail "$OP" "multiple MariaDB versions in '${NAMESPACE}'; pass 'source' to pick the restore source, or 'image' explicitly" \
        "$(jq -n --arg c "$NS_IMAGES" '{versions: ($c | split("\n") | map(select(. != "")))}')" 2
    fi
  fi
  if [[ -z "$IMAGE" ]]; then
    mdbt_fail "$OP" "could not determine the source MariaDB version (no MariaDB instance in '${NAMESPACE}'); pass 'image' explicitly" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2
  fi
fi

if [[ -z "$STORAGE_SIZE" ]]; then
  if [[ -n "$SOURCE_NAME" ]]; then
    STORAGE_SIZE="$(_kubectl get mariadb "$SOURCE_NAME" -o jsonpath='{.spec.storage.size}' 2>/dev/null || true)"
  fi
  STORAGE_SIZE="${STORAGE_SIZE:-$DEFAULT_STORAGE_SIZE}"
fi

# Validate the resolved user-facing + override values (internals are trusted).
mdbt_validate_dns_label "target" "$TARGET" "$OP"
mdbt_validate_image "image" "$IMAGE" "$OP"
mdbt_validate_storage_size "storage_size" "$STORAGE_SIZE" "$OP"
mdbt_validate_s3_bucket "backup_bucket" "$BACKUP_BUCKET" "$OP"
mdbt_validate_s3_prefix "backup_prefix" "$BACKUP_PREFIX" "$OP"
mdbt_validate_endpoint "backup_endpoint" "$BACKUP_ENDPOINT" "$OP"
if [[ -n "$TARGET_TIME" ]]; then
  mdbt_validate_rfc3339 "target_time" "$TARGET_TIME" "$OP"
fi

# Only emit targetRecoveryTime when a PITR target was given; an empty line in
# the manifest is harmless YAML.
RECOVERY_LINE=""
if [[ -n "$TARGET_TIME" ]]; then
  RECOVERY_LINE="    targetRecoveryTime: \"${TARGET_TIME}\""
fi

MANIFEST="$(cat <<EOF
apiVersion: k8s.mariadb.com/v1alpha1
kind: MariaDB
metadata:
  name: ${TARGET}
  namespace: ${NAMESPACE}
spec:
  image: ${IMAGE}
  rootPasswordSecretKeyRef:
    name: ${ROOT_SECRET_NAME}
    key: ${ROOT_SECRET_KEY}
  storage:
    size: ${STORAGE_SIZE}
  replicas: ${REPLICAS}
  bootstrapFrom:
    backupContentType: Physical
${RECOVERY_LINE}
    s3:
      bucket: ${BACKUP_BUCKET}
      prefix: ${BACKUP_PREFIX}
      endpoint: ${BACKUP_ENDPOINT}
      region: ${BACKUP_REGION}
      accessKeyIdSecretKeyRef:
        name: ${BACKUP_ACCESS_SECRET}
        key: ${BACKUP_ACCESS_KEY}
      secretAccessKeySecretKeyRef:
        name: ${BACKUP_ACCESS_SECRET}
        key: ${BACKUP_SECRET_KEY}
EOF
)"

# The restored instance is reachable at the operator-managed primary Service;
# its root credentials live in the platform-managed Secret (returned by ref).
CONNECTION_HOST="${TARGET}-primary.${NAMESPACE}.svc.cluster.local"

# restore_result <restored:bool> <dryRun:bool>
restore_result() {
  jq -n \
    --arg namespace "$NAMESPACE" \
    --arg target "$TARGET" \
    --arg source "${SOURCE_NAME:-}" \
    --arg image "$IMAGE" \
    --arg bucket "$BACKUP_BUCKET" \
    --arg prefix "$BACKUP_PREFIX" \
    --arg endpoint "$BACKUP_ENDPOINT" \
    --argjson pitr "$(mdbt_bool_json "${TARGET_TIME:+true}")" \
    --arg targetTime "$TARGET_TIME" \
    --arg host "$CONNECTION_HOST" \
    --arg secretName "$ROOT_SECRET_NAME" \
    --arg secretKey "$ROOT_SECRET_KEY" \
    --arg manifest "$MANIFEST" \
    --argjson restored "$1" \
    --argjson dry "$2" \
    '{
      namespace: $namespace,
      target: $target,
      source: (if $source == "" then null else $source end),
      image: $image,
      backup: {bucket: $bucket, prefix: $prefix, endpoint: $endpoint, contentType: "Physical"},
      pointInTimeRecovery: {enabled: $pitr, targetRecoveryTime: (if $pitr then $targetTime else null end)},
      connection: {host: $host, port: 3306},
      credentialsRef: {secretName: $secretName, secretKey: $secretKey},
      dryRun: $dry,
      restored: $restored
    } + (if $dry then {manifest: $manifest} else {} end)'
}

if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" "dry run: MariaDB restore manifest rendered for ${TARGET}" "$(restore_result false true)")"
  exit 0
fi

# Restore never overwrites in place — refuse if the target already exists so a
# typo can't clobber a live instance. Operators clone to a new name instead.
if _kubectl get mariadb "$TARGET" >/dev/null 2>&1; then
  mdbt_fail "$OP" "target MariaDB '${TARGET}' already exists; restore provisions a NEW instance and never overwrites in place (choose a different target name)" \
    "$(jq -n --arg ns "$NAMESPACE" --arg target "$TARGET" '{namespace: $ns, target: $target}')" 2
fi

printf '%s\n' "$MANIFEST" | _kubectl apply -f -

if [[ "$WAIT_READY" != "false" ]]; then
  mdbt_wait_mariadb_ready "$TARGET" "$WAIT_TIMEOUT"
fi

mdbt_write_result "$(response_ok "$OP" "MariaDB restored into new instance ${TARGET}" "$(restore_result true false)")"
