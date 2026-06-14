#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/restore.sh
# Restore a MariaDB instance from a physical (mariabackup) backup in S3/MinIO,
# optionally to a point in time.
#
# AWS-style semantics: a restore always provisions a NEW MariaDB instance and
# never overwrites in place (RestoreDBInstanceFromDBSnapshot /
# RestoreDBInstanceToPointInTime). It drives the mariadb-operator
# `spec.bootstrapFrom` restore path — the same machinery blue-green/bootstrap
# uses — but without the replication / multi-cluster wiring. When a target_time
# is supplied, `bootstrapFrom.targetRecoveryTime` performs point-in-time
# recovery; otherwise the latest backup under the prefix is restored.
#
# The backup itself must be a mariadb-operator PhysicalBackup / mariabackup
# object-storage layout; the logical `backup` task is not a valid source. The
# generic input validators, confirm gate, and result contract come from
# mariadb-task-common.sh (shared with the blue-green tasks).
# =============================================================================

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi

# shellcheck source=../../lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"  # pulls in logging, response, k8s + generic helpers

OP="restore"

# Target instance + cluster. Empty values are caught by the validators below,
# which emit a structured INVALID_INPUT-style result rather than a bash error.
NAMESPACE="${DB_NAMESPACE:-}"
TARGET="${RESTORE_TARGET:-}"
IMAGE="${RESTORE_IMAGE:-}"
K8S_CONTEXT="${K8S_CONTEXT:-}"
# shellcheck disable=SC2034  # consumed by _kubectl in k8s.sh (sourced indirectly)
K8S_NAMESPACE="$NAMESPACE"

ROOT_SECRET_NAME="${ROOT_SECRET_NAME:-mariadb}"
ROOT_SECRET_KEY="${ROOT_SECRET_KEY:-password}"
STORAGE_SIZE="${STORAGE_SIZE:-1Gi}"
REPLICAS="${REPLICAS:-1}"

BACKUP_BUCKET="${BACKUP_BUCKET:-}"
BACKUP_PREFIX="${BACKUP_PREFIX:-}"
BACKUP_ENDPOINT="${BACKUP_ENDPOINT:-}"
BACKUP_REGION="${BACKUP_REGION:-us-east-1}"
BACKUP_ACCESS_SECRET="${BACKUP_ACCESS_SECRET:-minio}"
BACKUP_ACCESS_KEY="${BACKUP_ACCESS_KEY:-access-key-id}"
BACKUP_SECRET_KEY="${BACKUP_SECRET_KEY:-secret-access-key}"

# Optional point-in-time recovery target. Empty → restore the latest backup.
TARGET_TIME="${TARGET_TIME:-}"

WAIT_READY="${WAIT_READY:-true}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"
CONFIRM="${CONFIRM:-false}"
DRY_RUN="${DRY_RUN:-false}"

if [[ "$(mdbt_bool_json "$DRY_RUN")" != "true" ]]; then
  mdbt_require_confirm "$OP" "$CONFIRM"
fi

mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"
mdbt_validate_dns_label "target" "$TARGET" "$OP"
mdbt_validate_image "image" "$IMAGE" "$OP"
mdbt_validate_dns_label "root_secret_name" "$ROOT_SECRET_NAME" "$OP"
mdbt_validate_secret_key "root_secret_key" "$ROOT_SECRET_KEY" "$OP"
mdbt_validate_storage_size "storage_size" "$STORAGE_SIZE" "$OP"
mdbt_validate_uint "replicas" "$REPLICAS" "$OP"
if [[ "$REPLICAS" != "1" ]]; then
  mdbt_fail "$OP" "replicas must be 1 for standalone restore; replication/multiCluster wiring is intentionally not created" \
    "$(jq -n --arg replicas "$REPLICAS" '{replicas: $replicas, supportedReplicas: "1"}')" 2
fi
mdbt_validate_s3_bucket "backup_bucket" "$BACKUP_BUCKET" "$OP"
mdbt_validate_s3_prefix "backup_prefix" "$BACKUP_PREFIX" "$OP"
mdbt_validate_endpoint "backup_endpoint" "$BACKUP_ENDPOINT" "$OP"
mdbt_validate_region "backup_region" "$BACKUP_REGION" "$OP"
mdbt_validate_dns_label "backup_access_secret" "$BACKUP_ACCESS_SECRET" "$OP"
mdbt_validate_secret_key "backup_access_key" "$BACKUP_ACCESS_KEY" "$OP"
mdbt_validate_secret_key "backup_secret_key" "$BACKUP_SECRET_KEY" "$OP"
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

if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  data="$(jq -n \
    --arg namespace "$NAMESPACE" \
    --arg target "$TARGET" \
    --arg image "$IMAGE" \
    --arg bucket "$BACKUP_BUCKET" \
    --arg prefix "$BACKUP_PREFIX" \
    --arg endpoint "$BACKUP_ENDPOINT" \
    --arg region "$BACKUP_REGION" \
    --argjson pitr "$(mdbt_bool_json "${TARGET_TIME:+true}")" \
    --arg targetTime "$TARGET_TIME" \
    --arg manifest "$MANIFEST" \
    '{
      namespace: $namespace,
      target: $target,
      image: $image,
      backup: {bucket: $bucket, prefix: $prefix, endpoint: $endpoint, region: $region, contentType: "Physical"},
      pointInTimeRecovery: {enabled: $pitr, targetRecoveryTime: (if $pitr then $targetTime else null end)},
      dryRun: true,
      restored: false,
      manifest: $manifest
    }')"
  mdbt_write_result "$(response_ok "$OP" "dry run: MariaDB restore manifest rendered for ${TARGET}" "$data")"
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

if [[ -n "$TARGET_TIME" ]]; then
  PITR_ENABLED=true
else
  PITR_ENABLED=false
fi

data="$(jq -n \
  --arg namespace "$NAMESPACE" \
  --arg target "$TARGET" \
  --arg image "$IMAGE" \
  --arg bucket "$BACKUP_BUCKET" \
  --arg prefix "$BACKUP_PREFIX" \
  --arg endpoint "$BACKUP_ENDPOINT" \
  --arg region "$BACKUP_REGION" \
  --argjson pitr "$PITR_ENABLED" \
  --arg targetTime "$TARGET_TIME" \
  '{
    namespace: $namespace,
    target: $target,
    image: $image,
    backup: {bucket: $bucket, prefix: $prefix, endpoint: $endpoint, region: $region, contentType: "Physical"},
    pointInTimeRecovery: {enabled: $pitr, targetRecoveryTime: (if $pitr then $targetTime else null end)},
    restored: true
  }')"

mdbt_write_result "$(response_ok "$OP" "MariaDB restored into new instance ${TARGET}" "$data")"
