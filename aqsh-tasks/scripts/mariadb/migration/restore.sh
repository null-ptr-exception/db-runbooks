#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# mariadb/migration/restore.sh
# Restore a MariaDB instance from a specific physical backup stored in a
# caller-specified external MinIO endpoint.
#
# Unlike the platform's own `restore` task (mariadb/restore.sh) — which
# resolves S3 credentials and location purely from platform deploy-time
# config — this task's MinIO parameters are caller overridable (a migration
# source may point at some OTHER MinIO entirely), falling back to this
# deployment's MINIO_*_DEFAULT internal config when omitted, same as
# migration/preflight. The backup_file input is the S3 prefix path to the
# exact backup directory (e.g.
# mariadb/source-ns/mariadb-migration-20260712143022), used directly as
# bootstrapFrom.s3.prefix so the operator restores that one backup rather
# than the latest under a broader prefix.
#
# The task fails with a clear error if:
#   - the backup_file path cannot be found in MinIO (checked via s5cmd before
#     applying anything — avoids silent operator timeouts)
#   - the target MariaDB CR already exists (never overwrites in place)
#   - the restore does not reach Ready within wait_timeout
#
# Secure credential handling:
#   minio_secret_key is used once for the backup existence check (s5cmd, via
#   AWS_* env vars — s5cmd is stateless, unlike mc's alias step), then written
#   to a temporary Kubernetes Secret and the env var is unset.
#   The MariaDB CR references the Secret directly; the raw value never appears
#   in logs or result JSON. The temporary Secret is deleted on exit — so
#   wait_timeout must be non-zero: the operator needs the Secret to still
#   exist when it reads it, and this script has no way to know that has
#   happened other than waiting for the restore to reach Ready.
#
# root_secret_name/root_secret_key (optional, default "mariadb"/"password",
# matching the platform's own convention) let a migration caller point the
# restored CR's rootPasswordSecretKeyRef at the Secret
# migration/import-db-env-from-vault relayed the source's real root password
# into — a physical restore carries over the source's actual DB password, so
# the operator's own Ready-probe (which authenticates using this Secret)
# needs it to match, not whatever a fresh/default secret happens to hold.
#
# image and storage_size are auto-detected from any existing MariaDB instance
# in the target namespace. For a fresh (migration-destination) namespace they
# must be provided as task inputs; the script fails clearly if neither source
# is available, consistent with the platform's own restore task.
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
# shellcheck source=../../../lib/minio-client.sh
source "${LIB_DIR}/minio-client.sh"  # s5 (s5cmd wrapper) — credentials set inline below, not via setup_minio_client (that reads deploy-time MINIO_ROOT_USER/PASSWORD, not this task's caller-supplied minio_access_key/minio_secret_key)

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

OP="migration/restore"

# --- Task inputs -------------------------------------------------------------
NAMESPACE="${DB_NAMESPACE:-}"
BACKUP_FILE="${BACKUP_FILE:-}"         # S3 prefix path to the exact backup directory
# MinIO options resolve task input -> deploy-time internal config
# (MINIO_*_DEFAULT) -> fail clearly if still unset.
MINIO_ENDPOINT="${MINIO_ENDPOINT:-${MINIO_ENDPOINT_DEFAULT:-}}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-${MINIO_ACCESS_KEY_DEFAULT:-}}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-${MINIO_SECRET_KEY_DEFAULT:-}}"
MINIO_BUCKET="${MINIO_BUCKET:-${MINIO_BUCKET_DEFAULT:-}}"
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

# Root credential Secret the restored CR's rootPasswordSecretKeyRef points
# at. Resolution: task input -> deploy-time internal config (RESTORE_ROOT_
# SECRET_*) -> hardcoded fallback. Defaults preserve today's behavior
# (platform-managed "mariadb"/"password"); a migration caller sets these
# explicitly to point at the Secret migration/import-db-env-from-vault
# relayed the source's actual root password into — since a physical restore
# carries over the source's real DB password, the operator's own Ready-probe
# (which authenticates using this Secret) needs it to match, not whatever a
# fresh/default secret in the destination namespace happens to hold.
ROOT_SECRET_NAME="${ROOT_SECRET_NAME:-${RESTORE_ROOT_SECRET_NAME:-mariadb}}"
ROOT_SECRET_KEY="${ROOT_SECRET_KEY:-${RESTORE_ROOT_SECRET_KEY:-password}}"
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

# mariadb-operator only creates a <name>-primary Service for multi-replica
# instances; a single-replica standalone instance (REPLICAS=1 above — this
# task is always standalone) is reached through its own plain Service
# instead (see docs/mariadb/sanity-check.md and tests/mariadb/check_connection.bats,
# which rely on exactly this behavior).
CONNECTION_HOST="${TARGET}.${NAMESPACE}.svc.cluster.local"

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
# s5cmd is stateless (no mc-style alias step): credentials via AWS_* env vars,
# endpoint via --endpoint-url. A single `ls` call distinguishes both failure
# modes s5cmd can report — 'no object found' means the prefix genuinely isn't
# there; anything else (auth/network/missing bucket) is a harder failure.
# shellcheck disable=SC2034  # read by s5() in minio-client.sh
S5_ENDPOINT="$MINIO_ENDPOINT"
export AWS_ACCESS_KEY_ID="$MINIO_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$MINIO_SECRET_KEY"

_S3_BACKUP_PATH="s3://${MINIO_BUCKET}/${BACKUP_FILE}/"
if ! _LS_OUT="$(s5 ls "$_S3_BACKUP_PATH" 2>&1)"; then
  if grep -q "no object found" <<<"$_LS_OUT"; then
    mdbt_fail "$OP" \
      "backup not found at s3://${MINIO_BUCKET}/${BACKUP_FILE} on ${MINIO_ENDPOINT} — verify backup_file path" \
      "$(jq -n \
         --arg ep "$MINIO_ENDPOINT" \
         --arg bucket "$MINIO_BUCKET" \
         --arg bf "$BACKUP_FILE" \
         '{endpoint: $ep, bucket: $bucket, backupFile: $bf}')" 2
  else
    mdbt_fail "$OP" \
      "failed to verify backup at s3://${MINIO_BUCKET}/${BACKUP_FILE} on ${MINIO_ENDPOINT} — check minio_access_key and minio_secret_key" \
      "$(jq -n --arg ep "$MINIO_ENDPOINT" --arg bucket "$MINIO_BUCKET" \
         '{endpoint: $ep, bucket: $bucket}')" 2
  fi
fi

# Step 2: Verify the root credential Secret exists in the target namespace
# BEFORE creating anything. Without this, a fresh migration-destination
# namespace that never had this Secret provisioned would only fail much
# later as a Ready timeout — same fail-fast philosophy as the backup check.
if ! _kubectl get secret "$ROOT_SECRET_NAME" >/dev/null 2>&1; then
  mdbt_fail "$OP" \
    "root credential secret '${ROOT_SECRET_NAME}' not found in namespace '${NAMESPACE}' — the restored instance's rootPasswordSecretKeyRef would never resolve" \
    "$(jq -n --arg ns "$NAMESPACE" --arg secret "$ROOT_SECRET_NAME" \
       '{namespace: $ns, secretName: $secret}')" 2
fi

# Step 3: Create temp K8s Secret with credentials; unset raw secret key.
# Name includes a random suffix (not just a timestamp) so concurrent calls in
# the same second can't collide; created atomically (no dry-run|apply) so a
# collision fails loudly instead of silently overwriting another run's Secret.
TEMP_SECRET_NAME="migration-restore-creds-$(date +%Y%m%d%H%M%S)-${RANDOM}-$$"

_cleanup_temp_secret() {
  if [[ -n "${TEMP_SECRET_NAME:-}" ]]; then
    _kubectl delete secret "$TEMP_SECRET_NAME" --ignore-not-found >/dev/null 2>&1 || true
  fi
}
# Covers only "never got as far as an applied CR" failures below (secret
# create, manifest render, CR create) — safe to clean up immediately since
# the operator was never given a CR that could reference this Secret.
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
  trap - ERR
  mdbt_fail "$OP" "failed to create temporary credential secret '${TEMP_SECRET_NAME}'" \
    "$(jq -n --arg ns "$NAMESPACE" --arg target "$TARGET" \
       '{namespace: $ns, target: $target}')" 1
fi
unset _TEMP_SECRET_MANIFEST

unset MINIO_SECRET_KEY

# Step 4: Rebuild manifest with the real temp-secret name.
if ! MANIFEST="$(_build_manifest "$TEMP_SECRET_NAME" 2>&1)"; then
  trap - ERR
  mdbt_fail "$OP" "failed to render MariaDB restore manifest: ${MANIFEST}" \
    "$(jq -n --arg ns "$NAMESPACE" --arg target "$TARGET" \
       '{namespace: $ns, target: $target}')" 3
fi

# Step 5: Create (never apply) — `create` atomically fails if the target
# already exists, closing the check-then-apply race a separate `get` probe
# would leave open (another actor could create the target between the check
# and the apply, which `apply` would then silently patch instead of refuse).
if ! create_out="$(printf '%s\n' "$MANIFEST" | _kubectl create -f - 2>&1)"; then
  trap - ERR
  if [[ "$create_out" == *AlreadyExists* || "$create_out" == *"already exists"* ]]; then
    mdbt_fail "$OP" \
      "target MariaDB '${TARGET}' already exists; migration restore provisions a NEW instance and never overwrites in place" \
      "$(jq -n --arg ns "$NAMESPACE" --arg target "$TARGET" \
         '{namespace: $ns, target: $target}')" 2
  fi
  mdbt_fail "$OP" "failed to create MariaDB restore manifest: ${create_out}" \
    "$(jq -n --arg ns "$NAMESPACE" --arg target "$TARGET" \
       '{namespace: $ns, target: $target}')" 3
fi

# The CR now exists and may reference the temp Secret — stop the blanket
# EXIT-trap cleanup. Only the "reached Ready" path below deletes it now;
# a wait-timeout leaves it in place; see the wait branch below.
trap - EXIT

# wait_timeout=0 is rejected above, so this always waits: the temp credential
# Secret must outlive the operator's read of it, and Ready is the only signal
# this script has that the read already happened.
if ! mdbt_wait_mariadb_ready "$TARGET" "$WAIT_TIMEOUT"; then
  # Do NOT delete the temp Secret here — the restore may still be in flight
  # and the operator may not have consumed bootstrapFrom.s3's credentials
  # yet. Deleting it now would turn a slow-but-recoverable restore into a
  # guaranteed failure. It's named clearly enough for manual cleanup once
  # the restore either completes or is confirmed abandoned.
  mdbt_write_result "$(response_err "$OP" \
    "MariaDB ${TARGET} was provisioned but did not become Ready within ${WAIT_TIMEOUT}; temporary credential secret '${TEMP_SECRET_NAME}' was intentionally left in place (may still be needed) — clean it up manually once the restore is confirmed to have completed or been abandoned" \
    "$(restore_result true false)" 1)"
  exit 1
fi

# Ready confirms the operator has already consumed the Secret — safe to
# clean up now.
_cleanup_temp_secret

mdbt_write_result "$(response_ok "$OP" \
  "MariaDB restored into new instance ${TARGET} from backup ${BACKUP_FILE}" \
  "$(restore_result true false)")"
