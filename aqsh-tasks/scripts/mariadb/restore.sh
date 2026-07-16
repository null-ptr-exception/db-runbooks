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

# Optional platform-selected MariaDB identity. Capture it before mariadb.sh
# applies its compatibility default. It is not a task input.
MDB_INPUT="${MARIADB_NAME:-}"

# shellcheck source=../../lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"  # pulls in logging, response, k8s + generic helpers
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"              # for mariadb_resolve_name (source auto-detect)
# shellcheck source=../../lib/minio-client.sh
source "${LIB_DIR}/minio-client.sh"         # s5cmd helpers for the hand-rolled path
# shellcheck source=../../lib/mariadb-physical-restore.sh
source "${LIB_DIR}/mariadb-physical-restore.sh"  # hand-rolled physical restore (legacy operator)

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
SOURCE_NAME="${RESTORE_SOURCE:-$MDB_INPUT}"
IMAGE="${RESTORE_IMAGE:-}"
STORAGE_SIZE="${STORAGE_SIZE:-}"
SOURCE_RESOURCES_JSON="null"
ROOT_SECRET_NAME="mariadb"
ROOT_SECRET_KEY="password"
BACKUP_REGION="${BACKUP_REGION:-}"
BACKUP_ACCESS_SECRET="${BACKUP_ACCESS_SECRET:-}"
BACKUP_ACCESS_KEY="${BACKUP_ACCESS_KEY:-}"
BACKUP_SECRET_ACCESS_SECRET="${BACKUP_SECRET_ACCESS_SECRET:-}"
BACKUP_SECRET_KEY="${BACKUP_SECRET_KEY:-}"
REPLICAS="1"                           # restore is standalone by design

restore_unhandled_error() {
  trap - ERR
  mdbt_write_result "$(mdbt_error_response "${OP:-restore}" "restore failed" \
    "$(jq -n --arg namespace "${NAMESPACE:-}" '{namespace: $namespace, restored: false, state: "FAILED"}')" \
    1 "INTERNAL_ERROR")" || true
  exit 1
}
trap restore_unhandled_error ERR

# Confirm is required to apply; a dry run renders the plan without it.
if [[ "$(mdbt_bool_json "$DRY_RUN")" != "true" ]]; then
  mdbt_require_confirm "$OP" "$CONFIRM"
fi

# Namespace is the one input the caller must provide.
mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"

# K8S_CONTEXT is a deployment-only reachability hook. Validate it before any
# cluster call without exposing it through the public task contract.
if [[ -n "$K8S_CONTEXT" ]]; then
  mdbt_validate_internal_or_fail "$OP" "INTERNAL_ERROR" "database service is unavailable" \
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
  if SOURCE_NAME="$(mariadb_resolve_name 2>/dev/null)"; then :; else SOURCE_NAME=""; fi
fi

# Fetch the source spec once (image + storage) to halve the API calls and avoid
# a race window if the source is mutated between two separate gets.
if [[ -n "$SOURCE_NAME" ]]; then
  SOURCE_JSON="$(_kubectl get mariadb "$SOURCE_NAME" -o json 2>/dev/null || true)"
  if [[ -n "$SOURCE_JSON" ]]; then
    [[ -z "$IMAGE" ]] && IMAGE="$(jq -r '.spec.image // empty' <<<"$SOURCE_JSON")"
    # Current generation: spec.storage.size.  Legacy mmontes generation:
    # spec.volumeClaimTemplate.resources.requests.storage (required by its CRD).
    [[ -z "$STORAGE_SIZE" ]] && STORAGE_SIZE="$(jq -r '
      .spec.storage.size //
      .spec.volumeClaimTemplate.resources.requests.storage //
      empty
    ' <<<"$SOURCE_JSON")"
    SOURCE_RESOURCES_JSON="$(jq -c '.spec.resources // null' <<<"$SOURCE_JSON")"
    ROOT_SECRET_NAME="$(jq -r '.spec.rootPasswordSecretKeyRef.name // "mariadb"' <<<"$SOURCE_JSON")"
    ROOT_SECRET_KEY="$(jq -r '.spec.rootPasswordSecretKeyRef.key // "password"' <<<"$SOURCE_JSON")"
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
    mdbt_fail "$OP" "restore configuration is ambiguous" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "DATABASE_CONFIGURATION_AMBIGUOUS"
  fi
  if [[ -z "$IMAGE" ]]; then
    mdbt_fail "$OP" "restore configuration is unavailable" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1 "RESTORE_CAPABILITY_UNAVAILABLE"
  fi
fi

# Storage is never guessed: an undersized PVC would truncate the restored data.
if [[ -z "$STORAGE_SIZE" ]]; then
  mdbt_fail "$OP" "restore configuration is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1 "RESTORE_CAPABILITY_UNAVAILABLE"
fi

# Storage policy follows the selected source MariaDB. Full-loss restores that
# have no remaining source retain the documented deploy-time fallback.
if ! mdbt_resolve_backup_location "$NAMESPACE" "$SOURCE_NAME"; then
  trap - ERR
  mdbt_fail "$OP" "restore source configuration is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_CONFIGURATION_UNAVAILABLE"
fi

# Validate platform-owned values without reflecting their names or values.
_validate_restore_internal() {
  mdbt_validate_internal_or_fail "$OP" "RESTORE_CAPABILITY_UNAVAILABLE" \
    "restore configuration is unavailable" "$@"
}
_validate_storage_internal() {
  mdbt_validate_internal_or_fail "$OP" "BACKUP_CONFIGURATION_UNAVAILABLE" \
    "restore source configuration is unavailable" "$@"
}
_validate_restore_internal mdbt_validate_dns_label "target" "$TARGET" "$OP"
_validate_restore_internal mdbt_validate_image "image" "$IMAGE" "$OP"
_validate_restore_internal mdbt_validate_storage_size "storage_size" "$STORAGE_SIZE" "$OP"
_validate_storage_internal mdbt_validate_s3_bucket "backup_bucket" "$BACKUP_BUCKET" "$OP"
_validate_storage_internal mdbt_validate_s3_prefix "backup_prefix" "$BACKUP_PREFIX" "$OP"
_validate_storage_internal mdbt_validate_endpoint "backup_endpoint" "$BACKUP_ENDPOINT" "$OP"
_validate_storage_internal mdbt_validate_region "backup_region" "$BACKUP_REGION" "$OP"
_validate_storage_internal mdbt_validate_dns_label "backup_access_secret" "$BACKUP_ACCESS_SECRET" "$OP"
_validate_storage_internal mdbt_validate_secret_key "backup_access_key" "$BACKUP_ACCESS_KEY" "$OP"
_validate_storage_internal mdbt_validate_dns_label "backup_secret_access_secret" "$BACKUP_SECRET_ACCESS_SECRET" "$OP"
_validate_storage_internal mdbt_validate_secret_key "backup_secret_key" "$BACKUP_SECRET_KEY" "$OP"
if [[ -n "$TARGET_TIME" ]]; then
  mdbt_validate_rfc3339 "target_time" "$TARGET_TIME" "$OP"
fi
OPERATOR_BACKUP_ENDPOINT="$(mdbt_operator_s3_endpoint "$BACKUP_ENDPOINT")"
OPERATOR_BACKUP_TLS="$(mdbt_operator_s3_tls_enabled "$BACKUP_ENDPOINT")"

# Build the MariaDB CR programmatically with jq rather than interpolating values
# into a YAML heredoc: kubectl apply accepts JSON, so there is no string-injection
# surface even if a field's validation is relaxed later. targetRecoveryTime is
# emitted only when a PITR target was given.
if ! MANIFEST="$(jq -n \
  --arg apiVersion "$(mdb_operator_apiversion)" \
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
  --argjson tls "$OPERATOR_BACKUP_TLS" \
  --arg region "$BACKUP_REGION" \
  --arg accessSecret "$BACKUP_ACCESS_SECRET" \
  --arg accessKey "$BACKUP_ACCESS_KEY" \
  --arg secretAccessSecret "$BACKUP_SECRET_ACCESS_SECRET" \
  --arg secretKey "$BACKUP_SECRET_KEY" \
  --arg targetTime "$TARGET_TIME" \
  --arg resourcesJson "$SOURCE_RESOURCES_JSON" \
  '{
    apiVersion: $apiVersion,
    kind: "MariaDB",
    metadata: {name: $target, namespace: $namespace},
    spec: ({
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
          tls: {enabled: $tls},
          accessKeyIdSecretKeyRef: {name: $accessSecret, key: $accessKey},
          secretAccessKeySecretKeyRef: {name: $secretAccessSecret, key: $secretKey}
        }
      } + (if $targetTime == "" then {} else {targetRecoveryTime: $targetTime} end))
    } + (($resourcesJson | try fromjson catch null) as $resources | if $resources == null then {} else {resources: $resources} end))
  }' 2>&1)"; then
  trap - ERR
  mdbt_fail "$OP" "restore could not be prepared" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns,restored:false,state:"FAILED"}')" 1 "INTERNAL_ERROR"
fi

# restore_result <provisioned:bool> <restored:bool> <dryRun:bool> <state>
restore_result() {
  jq -n \
    --arg namespace "$NAMESPACE" \
    --argjson pitr "$(mdbt_bool_json "${TARGET_TIME:+true}")" \
    --arg targetTime "$TARGET_TIME" \
    --arg state "$4" \
    --argjson provisioned "$1" \
    --argjson restored "$2" \
    --argjson dry "$3" \
    '{
      namespace: $namespace,
      contentType: "Physical",
      pointInTimeRecovery: {enabled: $pitr, targetRecoveryTime: (if $pitr then $targetTime else null end)},
      state: $state,
      dryRun: $dry,
      provisioned: $provisioned,
      restored: $restored
    }'
}

# --- Route by operator capability: legacy has no physical bootstrapFrom -------
# When a confidently detected legacy operator lacks the PhysicalBackup CRD it
# also lacks physical bootstrapFrom. Take the hand-rolled path: pre-populate the
# datadir PVC from the .xb via a Job and let the new instance adopt it.
PHYSICAL_MODE=""
mode_rc=0
PHYSICAL_MODE="$(mdb_physical_backup_mode)" || mode_rc=$?
if [[ "$mode_rc" -ne 0 ]]; then
  trap - ERR
  if [[ "$mode_rc" -eq 2 ]]; then
    mdbt_fail "$OP" "physical restore capability is unavailable" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "RESTORE_CAPABILITY_UNAVAILABLE"
  fi
  mdbt_fail "$OP" "physical restore capability is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "RESTORE_CAPABILITY_UNAVAILABLE"
fi

if [[ "$PHYSICAL_MODE" == "hand-rolled" ]]; then
  if [[ -n "$TARGET_TIME" ]]; then
    trap - ERR
    mdbt_fail "$OP" "point-in-time recovery is unavailable for this database" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2 "RESTORE_CAPABILITY_UNAVAILABLE"
  fi

  if ! mdbt_s3_prepare_direct_client >/dev/null 2>&1; then
    trap - ERR
    mdbt_fail "$OP" "restore source configuration is unavailable" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_CONFIGURATION_UNAVAILABLE"
  fi
  if ! setup_minio_client >/dev/null 2>&1; then
    trap - ERR
    mdbt_fail "$OP" "restore source is unavailable" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_SERVICE_UNAVAILABLE"
  fi
  PR_OBJECT="$(mdbt_pr_source_object "$BACKUP_BUCKET" "$BACKUP_PREFIX" "${RESTORE_BACKUP_OBJECT:-}" 2>/dev/null)" || {
    trap - ERR
    mdbt_fail "$OP" "restore source is unavailable" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_SERVICE_UNAVAILABLE"
  }
  pr_result() {  # <provisioned:bool> <restored:bool> <dryRun:bool> <state>
    restore_result "$1" "$2" "$3" "$4"
  }

  if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
    mdbt_write_result "$(response_ok "$OP" "restore dry run completed" "$(pr_result false false true PLANNED)")"
    exit 0
  fi

  if [[ -z "$PR_OBJECT" ]]; then
    trap - ERR
    mdbt_fail "$OP" "no backup is available to restore" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns,restored:false,state:"FAILED"}')" 2 "BACKUP_NOT_FOUND"
  fi

  if [[ "$WAIT_TIMEOUT" == "0" ]]; then
    trap - ERR
    mdbt_fail "$OP" "wait_timeout=0 is unavailable for this restore" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns,waitTimeout:0}')" 2 "INVALID_REQUEST"
  fi

  if _kubectl get mariadb "$TARGET" >/dev/null 2>&1; then
    trap - ERR
    mdbt_fail "$OP" "restore target is unavailable" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns,restored:false,state:"FAILED"}')" 1 "RESTORE_FAILED"
  fi

  rc=0
  # The s5cmd prepare Job requires the original endpoint URL including scheme.
  # OPERATOR_BACKUP_ENDPOINT is only for operator CRs.
  mdbt_pr_orchestrate "$TARGET" "$NAMESPACE" "$IMAGE" "$STORAGE_SIZE" "$ROOT_SECRET_NAME" "$ROOT_SECRET_KEY" \
    "$BACKUP_BUCKET" "$PR_OBJECT" "$BACKUP_ENDPOINT" \
    "$BACKUP_ACCESS_SECRET" "$BACKUP_ACCESS_KEY" "$BACKUP_SECRET_ACCESS_SECRET" "$BACKUP_SECRET_KEY" \
    "$(mdb_operator_apiversion)" "$WAIT_TIMEOUT" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    mdbt_write_result "$(response_ok "$OP" "database restore completed" "$(pr_result true true false COMPLETED)")"
    exit 0
  fi
  trap - ERR
  mdbt_fail "$OP" "database restore failed" \
    "$(pr_result false false false FAILED)" 1 "RESTORE_FAILED"
fi

if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" "restore dry run completed" "$(restore_result false false true PLANNED)")"
  exit 0
fi

# Restore never overwrites in place — refuse if the target already exists so a
# typo can't clobber a live instance. Operators clone to a new name instead.
if _kubectl get mariadb "$TARGET" >/dev/null 2>&1; then
  mdbt_fail "$OP" "restore target is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns,restored:false,state:"FAILED"}')" 1 "RESTORE_FAILED"
fi

if ! printf '%s\n' "$MANIFEST" | _kubectl apply -f - >/dev/null 2>&1; then
  # Disable the ERR trap so its generic message can't mask the real apply error,
  # and use a minimal data payload (not restore_result) so nothing else can fail
  # here and swallow the public error.
  trap - ERR
  mdbt_fail "$OP" "database restore could not be started" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns,provisioned:false,restored:false,state:"FAILED"}')" \
    1 "RESTORE_FAILED"
fi

# wait_timeout="0" returns immediately; otherwise wait for Ready. The instance is
# already provisioned at this point, so a wait timeout must NOT lose the result —
# emit a sanitized partial result without backend resource details.
if [[ "$WAIT_TIMEOUT" != "0" ]]; then
  if ! mdbt_wait_mariadb_backup_restored "$TARGET" "$WAIT_TIMEOUT" >/dev/null 2>&1 \
      || ! mdbt_wait_mariadb_ready "$TARGET" "$WAIT_TIMEOUT" >/dev/null 2>&1; then
    mdbt_write_result "$(mdbt_error_response "$OP" "database restore is still pending" \
      "$(restore_result true false false PENDING)" 1 "RESTORE_TIMEOUT")"
    exit 1
  fi
fi

if [[ "$WAIT_TIMEOUT" == "0" ]]; then
  mdbt_write_result "$(response_ok "$OP" "database restore requested" "$(restore_result true false false REQUESTED)")"
else
  mdbt_write_result "$(response_ok "$OP" "database restore completed" "$(restore_result true true false COMPLETED)")"
fi
