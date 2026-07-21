#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# mariadb/migration/restore.sh
# Restore a MariaDB instance from a specific physical backup stored in a
# caller-specified external MinIO endpoint.
#
# Unlike restore.sh — which resolves S3 credentials and location from platform
# deploy-time config — this task accepts all MinIO parameters as explicit task
# inputs. The backup_file input is the S3 prefix path to the exact backup
# directory (e.g. mariadb/source-ns/mariadb-migration-20260712143022), used
# directly as bootstrapFrom.s3.prefix so the operator restores that one
# backup rather than the latest under a broader prefix.
#
# The task fails with a clear error if:
#   - the backup_file path cannot be found in MinIO (checked via mc before
#     applying anything — avoids silent operator timeouts)
#   - the target MariaDB CR already exists (never overwrites in place)
#   - the restore does not reach Ready within wait_timeout
#
# Secure credential handling:
#   minio_secret_key is used once for the backup existence check (mc alias set),
#   then written to a temporary Kubernetes Secret and the env var is unset.
#   The MariaDB CR references the Secret directly; the raw value never appears
#   in logs or result JSON. The temporary Secret is deleted on exit.
#
# image and storage_size are auto-detected from any existing MariaDB instance
# in the target namespace. For a fresh (migration-destination) namespace they
# must be provided as task inputs; the script fails clearly if neither source
# is available, consistent with restore.sh.
# =============================================================================

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi

# shellcheck source=../../../lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"
# shellcheck source=../../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"

OP="migration/restore"

# --- Task inputs -------------------------------------------------------------
NAMESPACE="${DB_NAMESPACE:-}"
BACKUP_FILE="${BACKUP_FILE:-}"         # S3 prefix path to the exact backup directory
MINIO_ENDPOINT="${MINIO_ENDPOINT:-}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-}"
MINIO_BUCKET="${MINIO_BUCKET:-}"
CONFIRM="${CONFIRM:-false}"
DRY_RUN="${DRY_RUN:-true}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"
K8S_CONTEXT="${K8S_CONTEXT:-}"

# image and storage_size: optional if a source instance can be detected in the
# namespace; required for a fresh migration-destination namespace.
IMAGE="${RESTORE_IMAGE:-}"
STORAGE_SIZE="${STORAGE_SIZE:-}"

# Target instance name — auto-generated below when empty.
TARGET="${RESTORE_TARGET:-}"

# Platform internals (env-overridable for advanced operators, not task inputs).
ROOT_SECRET_NAME="${RESTORE_ROOT_SECRET_NAME:-mariadb}"
ROOT_SECRET_KEY="${RESTORE_ROOT_SECRET_KEY:-password}"
BACKUP_REGION="${BACKUP_REGION:-us-east-1}"
REPLICAS="1"    # restore is standalone by design
SOURCE_NAME=""
SOURCE_RESOURCES_JSON="null"

# Credential key names inside the temp Secret — same convention as the platform.
_CRED_ACCESS_KEY_NAME="access-key-id"
_CRED_SECRET_KEY_NAME="secret-access-key"

# --- ERR trap (mirrors restore.sh) -------------------------------------------
restore_unhandled_error() {
  local code="$?"
  local line="${BASH_LINENO[0]:-unknown}"
  trap - ERR
  mdbt_write_result "$(response_err "$OP" \
    "migration restore aborted before completing at line ${line} (exit ${code})" \
    "$(jq -n \
      --arg namespace "${NAMESPACE:-}" \
      --arg target "${TARGET:-}" \
      '{namespace: $namespace, target: (if $target == "" then null else $target end)}')" \
    "$code")" || true
  exit "$code"
}
trap restore_unhandled_error ERR

# --- Input validation --------------------------------------------------------
if [[ "$(mdbt_bool_json "$DRY_RUN")" != "true" ]]; then
  mdbt_require_confirm "$OP" "$CONFIRM"
fi

mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"
mdbt_required "backup_file" "$BACKUP_FILE" "$OP"
mdbt_required "minio_endpoint" "$MINIO_ENDPOINT" "$OP"
mdbt_required "minio_access_key" "$MINIO_ACCESS_KEY" "$OP"
mdbt_required "minio_secret_key" "$MINIO_SECRET_KEY" "$OP"
mdbt_required "minio_bucket" "$MINIO_BUCKET" "$OP"
mdbt_validate_s3_bucket "minio_bucket" "$MINIO_BUCKET" "$OP"
mdbt_validate_endpoint "minio_endpoint" "$MINIO_ENDPOINT" "$OP"
mdbt_validate_s3_prefix "backup_file" "$BACKUP_FILE" "$OP"

if [[ -n "$K8S_CONTEXT" ]]; then
  mdbt_validate_context "context" "$K8S_CONTEXT" "$OP"
fi

mariadb_set_target "$K8S_CONTEXT" "$NAMESPACE"

if [[ -z "$TARGET" ]]; then
  TARGET="${NAMESPACE}-restore-$(date +%Y%m%d%H%M%S)"
fi

# --- Resolve image and storage_size from an existing instance ----------------
# Mirrors restore.sh: explicit RESTORE_SOURCE override → auto-detect → image
# scan. For a fresh migration-destination namespace (no MariaDB CR) the caller
# must supply image / storage_size as task inputs; the script fails clearly.
SOURCE_FOR_SPEC="${RESTORE_SOURCE:-}"
if [[ -z "$SOURCE_FOR_SPEC" && ( -z "$IMAGE" || -z "$STORAGE_SIZE" ) ]]; then
  if SOURCE_FOR_SPEC="$(mariadb_resolve_name)"; then :; else SOURCE_FOR_SPEC=""; fi
fi

if [[ -n "$SOURCE_FOR_SPEC" ]]; then
  SOURCE_JSON="$(_kubectl get mariadb "$SOURCE_FOR_SPEC" -o json 2>/dev/null || true)"
  if [[ -n "$SOURCE_JSON" ]]; then
    SOURCE_NAME="$SOURCE_FOR_SPEC"
    [[ -z "$IMAGE" ]]        && IMAGE="$(jq -r '.spec.image // empty' <<<"$SOURCE_JSON")"
    [[ -z "$STORAGE_SIZE" ]] && STORAGE_SIZE="$(jq -r '.spec.storage.size // empty' <<<"$SOURCE_JSON")"
    SOURCE_RESOURCES_JSON="$(jq -c '.spec.resources // null' <<<"$SOURCE_JSON")"
  fi
fi

if [[ -z "$IMAGE" ]]; then
  NS_IMAGES="$(_kubectl get mariadb \
    -o jsonpath='{range .items[*]}{.spec.image}{"\n"}{end}' 2>/dev/null \
    | sed '/^$/d' | sort -u || true)"
  NS_IMAGE_COUNT="$(printf '%s\n' "$NS_IMAGES" | grep -c . || true)"
  if [[ "$NS_IMAGE_COUNT" -eq 1 ]]; then
    IMAGE="$NS_IMAGES"
  elif [[ "$NS_IMAGE_COUNT" -gt 1 ]]; then
    mdbt_fail "$OP" \
      "'${NAMESPACE}' runs multiple MariaDB versions; cannot pick the restore version — provide the 'image' input" \
      "$(jq -n --arg c "$NS_IMAGES" '{versions: ($c | split("\n") | map(select(. != "")))}')" 2
  fi
  if [[ -z "$IMAGE" ]]; then
    mdbt_fail "$OP" \
      "could not determine the MariaDB image for '${NAMESPACE}' (no instance to derive it from) — provide the 'image' input" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2
  fi
fi

if [[ -z "$STORAGE_SIZE" ]]; then
  mdbt_fail "$OP" \
    "could not determine the storage size for '${NAMESPACE}' — provide the 'storage_size' input" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2
fi

mdbt_validate_dns_label "target" "$TARGET" "$OP"
mdbt_validate_image "image" "$IMAGE" "$OP"
mdbt_validate_storage_size "storage_size" "$STORAGE_SIZE" "$OP"

# Backup location is fully specified by task inputs.
BACKUP_BUCKET="$MINIO_BUCKET"
BACKUP_PREFIX="$BACKUP_FILE"
BACKUP_ENDPOINT="$MINIO_ENDPOINT"
OPERATOR_BACKUP_ENDPOINT="$(mdbt_operator_s3_endpoint "$BACKUP_ENDPOINT")"
OPERATOR_BACKUP_TLS="$(mdbt_operator_s3_tls_enabled "$BACKUP_ENDPOINT")"

# Helper to build the MariaDB CR for a given access-secret name.
_build_manifest() {
  local access_secret="$1"
  jq -n \
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
    --arg accessSecret "$access_secret" \
    --arg accessKey "$_CRED_ACCESS_KEY_NAME" \
    --arg secretKey "$_CRED_SECRET_KEY_NAME" \
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
        bootstrapFrom: {
          backupContentType: "Physical",
          s3: {
            bucket: $bucket,
            prefix: $prefix,
            endpoint: $endpoint,
            region: $region,
            tls: {enabled: $tls},
            accessKeyIdSecretKeyRef: {name: $accessSecret, key: $accessKey},
            secretAccessKeySecretKeyRef: {name: $accessSecret, key: $secretKey}
          }
        }
      } + (($resourcesJson | try fromjson catch null) as $resources |
           if $resources == null then {} else {resources: $resources} end))
    }'
}

if ! MANIFEST="$(_build_manifest "migration-restore-creds-preview" 2>&1)"; then
  trap - ERR
  mdbt_fail "$OP" "failed to render MariaDB restore manifest: ${MANIFEST}" \
    "$(jq -n --arg ns "$NAMESPACE" --arg target "$TARGET" \
       '{namespace: $ns, target: $target}')" 3
fi

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
    --arg backupFile "$BACKUP_FILE" \
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
      backup: {bucket: $bucket, prefix: $prefix, endpoint: $endpoint,
               backupFile: $backupFile, contentType: "Physical"},
      connection: {host: $host, port: 3306},
      credentialsRef: {secretName: $secretName, secretKey: $secretKey},
      dryRun: $dry,
      restored: $restored
    } + (if $dry then {manifest: $manifest} else {} end)'
}

# --- Dry run -----------------------------------------------------------------
if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" \
    "dry run: MariaDB migration-restore manifest rendered for ${TARGET}" \
    "$(restore_result false true)")"
  exit 0
fi

# --- Real run ----------------------------------------------------------------

# Step 1: Verify backup exists in MinIO BEFORE creating any K8s resources.
# Fail fast with a clear message rather than letting the operator stall.
_MC_ALIAS="migration-restore-$$"
if ! mc alias set "$_MC_ALIAS" "$MINIO_ENDPOINT" \
    "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" --api S3v4 >/dev/null 2>&1; then
  mc alias rm "$_MC_ALIAS" >/dev/null 2>&1 || true
  mdbt_fail "$OP" \
    "failed to authenticate against MinIO at ${MINIO_ENDPOINT} — check minio_access_key and minio_secret_key" \
    "$(jq -n --arg ep "$MINIO_ENDPOINT" --arg bucket "$MINIO_BUCKET" \
       '{endpoint: $ep, bucket: $bucket}')" 2
fi

_BACKUP_EXISTS=false
if mc ls "${_MC_ALIAS}/${MINIO_BUCKET}/${BACKUP_FILE}" 2>/dev/null | grep -q .; then
  _BACKUP_EXISTS=true
fi
mc alias rm "$_MC_ALIAS" >/dev/null 2>&1 || true

if [[ "$_BACKUP_EXISTS" != "true" ]]; then
  mdbt_fail "$OP" \
    "backup not found at s3://${MINIO_BUCKET}/${BACKUP_FILE} on ${MINIO_ENDPOINT} — verify backup_file path" \
    "$(jq -n \
       --arg ep "$MINIO_ENDPOINT" \
       --arg bucket "$MINIO_BUCKET" \
       --arg bf "$BACKUP_FILE" \
       '{endpoint: $ep, bucket: $bucket, backupFile: $bf}')" 2
fi

# Step 2: Create temp K8s Secret with credentials; unset raw secret key.
TEMP_SECRET_NAME="migration-restore-creds-$(date +%Y%m%d%H%M%S)"

_cleanup_temp_secret() {
  if [[ -n "${TEMP_SECRET_NAME:-}" ]]; then
    _kubectl delete secret "$TEMP_SECRET_NAME" --ignore-not-found >/dev/null 2>&1 || true
  fi
}
trap _cleanup_temp_secret EXIT

_kubectl create secret generic "$TEMP_SECRET_NAME" \
  --from-literal="${_CRED_ACCESS_KEY_NAME}=${MINIO_ACCESS_KEY}" \
  --from-literal="${_CRED_SECRET_KEY_NAME}=${MINIO_SECRET_KEY}" \
  --dry-run=client -o json | _kubectl apply -f - >/dev/null

unset MINIO_SECRET_KEY

# Step 3: Rebuild manifest with the real temp-secret name.
if ! MANIFEST="$(_build_manifest "$TEMP_SECRET_NAME" 2>&1)"; then
  trap - ERR
  mdbt_fail "$OP" "failed to render MariaDB restore manifest: ${MANIFEST}" \
    "$(jq -n --arg ns "$NAMESPACE" --arg target "$TARGET" \
       '{namespace: $ns, target: $target}')" 3
fi

# Step 4: Refuse to overwrite an existing target.
if _kubectl get mariadb "$TARGET" >/dev/null 2>&1; then
  mdbt_fail "$OP" \
    "target MariaDB '${TARGET}' already exists; migration restore provisions a NEW instance and never overwrites in place" \
    "$(jq -n --arg ns "$NAMESPACE" --arg target "$TARGET" \
       '{namespace: $ns, target: $target}')" 2
fi

# Step 5: Apply and wait.
if ! apply_out="$(printf '%s\n' "$MANIFEST" | _kubectl apply -f - 2>&1)"; then
  trap - ERR
  mdbt_fail "$OP" "failed to apply MariaDB restore manifest: ${apply_out}" \
    "$(jq -n --arg ns "$NAMESPACE" --arg target "$TARGET" \
       '{namespace: $ns, target: $target}')" 3
fi

if [[ "$WAIT_TIMEOUT" != "0" ]]; then
  if ! mdbt_wait_mariadb_ready "$TARGET" "$WAIT_TIMEOUT"; then
    mdbt_write_result "$(response_err "$OP" \
      "MariaDB ${TARGET} was provisioned but did not become Ready within ${WAIT_TIMEOUT}" \
      "$(restore_result true false)" 1)"
    exit 1
  fi
fi

mdbt_write_result "$(response_ok "$OP" \
  "MariaDB restored into new instance ${TARGET} from backup ${BACKUP_FILE}" \
  "$(restore_result true false)")"
