#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# mariadb/restore.sh
# Recreate a namespace's MariaDB from its physical (mariabackup) backup in
# S3/MinIO, optionally to a point in time.
#
# The NAMESPACE is the database identity. The caller says only *which* namespace
# to restore (and optionally a point-in-time); everything that defines the
# managed database — the engine version, storage size, the restored instance
# name, which instance to derive the spec from, the S3 backup location, and the
# credentials — is resolved internally from platform conventions / the
# namespace's own state, never passed by the caller. (Some of these stay
# env-readable as advanced operator overrides, but none is a task input.)
#
# AWS-style semantics: a restore always provisions a NEW MariaDB instance and
# never overwrites in place (RestoreDBInstanceFromDBSnapshot /
# RestoreDBInstanceToPointInTime). It drives the mariadb-operator
# `spec.bootstrapFrom` restore path — the same machinery blue-green/bootstrap
# uses — but without the replication / multi-cluster wiring. With target_time,
# `bootstrapFrom.targetRecoveryTime` performs point-in-time recovery; without
# it, the latest backup under the prefix is restored.
#
# NOTE: version + storage are derived from the namespace's still-present
# instance. Reconstructing them when the namespace's instance is *entirely* gone
# (true full-loss DR) needs a durable, in-cluster spec source (backup metadata /
# per-namespace config) that does not exist yet. The source must be a
# mariadb-operator PhysicalBackup / mariabackup layout; the logical `backup`
# task is not a valid source.
#
# The S3 backup location (bucket / prefix / endpoint) is resolved by the shared
# mdbt_resolve_backup_location helper from the same deploy-time config + naming
# convention the physical-backup *write* side uses, so a restore finds a
# namespace's backups by namespace alone — read and write can never drift.
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

# Deploy-time S3/MinIO settings (MINIO_ENDPOINT, MINIO_BUCKET, ...).
mdbt_load_config

OP="restore"

# --- User-facing inputs ------------------------------------------------------
NAMESPACE="${DB_NAMESPACE:-}"          # the database identity — the only required input
TARGET_TIME="${TARGET_TIME:-}"         # optional: omit → latest backup; set → PITR
CONFIRM="${CONFIRM:-false}"
DRY_RUN="${DRY_RUN:-true}"
# wait_timeout doubles as the wait switch: "0" → return without waiting; any
# positive duration (e.g. 10m) → wait up to that long for Ready.
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"
K8S_CONTEXT="${K8S_CONTEXT:-}"         # reachability hook (empty → in-cluster)

# --- Platform internals (NOT task inputs) ------------------------------------
# These define the restored database and are resolved internally from the
# namespace; they stay env-readable as advanced operator overrides only.
#   TARGET / SOURCE: the restored instance name and which instance to copy the
#     spec from — auto-resolved below.
#   IMAGE / STORAGE_SIZE: the engine version and PVC size — derived from the
#     namespace's instance, never defaulted (an undersized PVC would truncate
#     the restored data; a mismatched version is unsafe for a physical restore).
TARGET="${RESTORE_TARGET:-}"
SOURCE_NAME="${RESTORE_SOURCE:-}"
IMAGE="${RESTORE_IMAGE:-}"
STORAGE_SIZE="${STORAGE_SIZE:-}"
SOURCE_RESOURCES_JSON="null"
# Backup location (bucket / prefix / endpoint) — resolved from deploy-time config
# + the per-namespace naming convention, identically to the write side. Sets
# BACKUP_BUCKET, BACKUP_PREFIX, BACKUP_ENDPOINT (each env-overridable).
mdbt_resolve_backup_location "$NAMESPACE"
ROOT_SECRET_NAME="mariadb"
ROOT_SECRET_KEY="password"
BACKUP_REGION="us-east-1"
BACKUP_ACCESS_SECRET="minio"
BACKUP_ACCESS_KEY="access-key-id"
BACKUP_SECRET_KEY="secret-access-key"
REPLICAS="1"                           # restore is standalone by design

restore_unhandled_error() {
  local code="$?"
  local line="${BASH_LINENO[0]:-unknown}"
  trap - ERR
  mdbt_write_result "$(response_err "$OP" "restore task aborted before completing at line ${line} (exit ${code})" \
    "$(jq -n \
      --arg namespace "${NAMESPACE:-}" \
      --arg target "${TARGET:-}" \
      --arg source "${SOURCE_NAME:-}" \
      '{namespace: $namespace, target: $target, source: (if $source == "" then null else $source end)}')" \
    "$code")" || true
  exit "$code"
}
trap restore_unhandled_error ERR

# Confirm is required to apply; a dry run renders the plan without it.
if [[ "$(mdbt_bool_json "$DRY_RUN")" != "true" ]]; then
  mdbt_require_confirm "$OP" "$CONFIRM"
fi

# Namespace is the one input the caller must provide.
mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"

# K8S_CONTEXT is empty on the normal in-cluster path: aqsh runs inside
# cluster-dbs, so the in-cluster config already targets the MariaDB cluster.
# Out-of-cluster / multi-cluster callers pass `context` explicitly; validate it
# so a malformed value can't silently provision into the wrong cluster
# (per CLAUDE.md: "Always specify --context"). Validate before any kubectl call.
if [[ -n "$K8S_CONTEXT" ]]; then
  mdbt_validate_context "context" "$K8S_CONTEXT" "$OP"
fi

# Wire the cluster/namespace target through the canonical entry point (the same
# one blue-green uses via bg_init_target) rather than poking K8S_* directly, so
# restore can't silently drift if that setup grows.
mariadb_set_target "$K8S_CONTEXT" "$NAMESPACE"

# Name the restored instance for the caller when they didn't.
if [[ -z "$TARGET" ]]; then
  TARGET="${NAMESPACE}-restore-$(date +%Y%m%d%H%M%S)"
fi

# Resolve the engine version and storage for the restored instance from the
# namespace's own state (the namespace is the database identity):
#  - RESTORE_SOURCE override        → derive from that instance
#  - exactly one MariaDB instance   → derive from it
#  - several, all the same image    → use that version (restore's own clones, etc.)
#  - mixed versions / none          → fail (never guess)
# Both must match the source: a physical restore is version- and size-sensitive,
# so neither the engine nor the PVC size is ever silently defaulted.
if [[ -z "$SOURCE_NAME" && ( -z "$IMAGE" || -z "$STORAGE_SIZE" ) ]]; then
  if SOURCE_NAME="$(mariadb_resolve_name)"; then :; else SOURCE_NAME=""; fi
fi

# Fetch the source spec once (image + storage) to halve the API calls and avoid
# a race window if the source is mutated between two separate gets.
if [[ -n "$SOURCE_NAME" ]]; then
  SOURCE_JSON="$(_kubectl get mariadb "$SOURCE_NAME" -o json 2>/dev/null || true)"
  if [[ -n "$SOURCE_JSON" ]]; then
    [[ -z "$IMAGE" ]]        && IMAGE="$(jq -r '.spec.image // empty' <<<"$SOURCE_JSON")"
    [[ -z "$STORAGE_SIZE" ]] && STORAGE_SIZE="$(jq -r '.spec.storage.size // empty' <<<"$SOURCE_JSON")"
    SOURCE_RESOURCES_JSON="$(jq -c '.spec.resources // null' <<<"$SOURCE_JSON")"
  fi
fi

if [[ -z "$IMAGE" ]]; then
  # No single source (multiple instances or none): a physical restore is
  # version-sensitive, so accept a derived version only when every instance
  # agrees — a namespace should not run mixed versions outside a blue-green
  # upgrade, and that window is exactly when the caller must disambiguate.
  NS_IMAGES="$(_kubectl get mariadb -o jsonpath='{range .items[*]}{.spec.image}{"\n"}{end}' 2>/dev/null | sed '/^$/d' | sort -u || true)"
  NS_IMAGE_COUNT="$(printf '%s\n' "$NS_IMAGES" | grep -c . || true)"
  if [[ "$NS_IMAGE_COUNT" -eq 1 ]]; then
    IMAGE="$NS_IMAGES"
  elif [[ "$NS_IMAGE_COUNT" -gt 1 ]]; then
    mdbt_fail "$OP" "'${NAMESPACE}' runs multiple MariaDB versions (e.g. mid blue-green upgrade); cannot pick the restore version automatically — operator: set the RESTORE_SOURCE or RESTORE_IMAGE override" \
      "$(jq -n --arg c "$NS_IMAGES" '{versions: ($c | split("\n") | map(select(. != "")))}')" 2
  fi
  if [[ -z "$IMAGE" ]]; then
    mdbt_fail "$OP" "could not determine the MariaDB version for '${NAMESPACE}' (no instance to derive it from); full-loss restore needs the backup to carry the spec (future) — operator: set the RESTORE_IMAGE override meanwhile" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2
  fi
fi

# Storage is never guessed: an undersized PVC would truncate the restored data.
if [[ -z "$STORAGE_SIZE" ]]; then
  mdbt_fail "$OP" "could not determine the storage size for '${NAMESPACE}' (no instance to derive it from); a physical restore must match the source PVC size — operator: set the RESTORE_SOURCE or STORAGE_SIZE override" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2
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
OPERATOR_BACKUP_ENDPOINT="$(mdbt_operator_s3_endpoint "$BACKUP_ENDPOINT")"

# Build the MariaDB CR programmatically with jq rather than interpolating values
# into a YAML heredoc: kubectl apply accepts JSON, so there is no string-injection
# surface even if a field's validation is relaxed later. targetRecoveryTime is
# emitted only when a PITR target was given.
MANIFEST="$(jq -n \
  --arg target "$TARGET" \
  --arg namespace "$NAMESPACE" \
  --arg image "$IMAGE" \
  --arg rootSecret "$ROOT_SECRET_NAME" \
  --arg rootKey "$ROOT_SECRET_KEY" \
  --arg storageSize "$STORAGE_SIZE" \
  --argjson replicas "$REPLICAS" \
  --arg bucket "$BACKUP_BUCKET" \
  --arg prefix "$BACKUP_PREFIX" \
  --arg endpoint "$OPERATOR_BACKUP_ENDPOINT" \
  --arg region "$BACKUP_REGION" \
  --arg accessSecret "$BACKUP_ACCESS_SECRET" \
  --arg accessKey "$BACKUP_ACCESS_KEY" \
  --arg secretKey "$BACKUP_SECRET_KEY" \
  --arg targetTime "$TARGET_TIME" \
  --arg resourcesJson "$SOURCE_RESOURCES_JSON" \
  '{
    apiVersion: "k8s.mariadb.com/v1alpha1",
    kind: "MariaDB",
    metadata: {name: $target, namespace: $namespace},
    spec: {
      image: $image,
      rootPasswordSecretKeyRef: {name: $rootSecret, key: $rootKey},
      storage: {size: $storageSize},
      replicas: $replicas,
      bootstrapFrom: ({
        backupContentType: "Physical",
        s3: {
          bucket: $bucket,
          prefix: $prefix,
          endpoint: $endpoint,
          region: $region,
          tls: {enabled: false},
          accessKeyIdSecretKeyRef: {name: $accessSecret, key: $accessKey},
          secretAccessKeySecretKeyRef: {name: $accessSecret, key: $secretKey}
        }
      } + (if $targetTime == "" then {} else {targetRecoveryTime: $targetTime} end))
    } + (($resourcesJson | try fromjson catch null) as $resources | if $resources == null then {} else {resources: $resources} end)
  }')"

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

if ! apply_out="$(printf '%s\n' "$MANIFEST" | _kubectl apply -f - 2>&1)"; then
  # Disable the ERR trap so its generic message can't mask the real apply error,
  # and use a minimal data payload (not restore_result) so nothing else can fail
  # here and swallow ${apply_out}.
  trap - ERR
  mdbt_fail "$OP" "failed to apply MariaDB restore manifest: ${apply_out}" \
    "$(jq -n --arg ns "$NAMESPACE" --arg target "$TARGET" '{namespace: $ns, target: $target}')" 3
fi

# wait_timeout="0" returns immediately; otherwise wait for Ready. The instance is
# already provisioned at this point, so a wait timeout must NOT lose the result —
# emit a partial result (with the connection endpoint + credential ref) so the
# caller can still reach the not-yet-Ready instance, then exit non-zero.
if [[ "$WAIT_TIMEOUT" != "0" ]]; then
  if ! mdbt_wait_mariadb_ready "$TARGET" "$WAIT_TIMEOUT"; then
    mdbt_write_result "$(response_err "$OP" "MariaDB ${TARGET} was provisioned but did not become Ready within ${WAIT_TIMEOUT}" "$(restore_result true false)" 1)"
    exit 1
  fi
fi

mdbt_write_result "$(response_ok "$OP" "MariaDB restored into new instance ${TARGET}" "$(restore_result true false)")"
