#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# mariadb/logical-restore.sh
# Recreate a namespace's MariaDB from a logical (mariadb-dump) `Backup` CR,
# driving the operator's `bootstrapFrom.backupRef` path. This is the logical
# counterpart of `restore` and — like `logical-backup` — works on BOTH operator
# generations: `backupRef` bootstrapping exists on the legacy mmontes-era
# operator as well as the current one.
#
# AWS-style semantics, identical to the physical `restore`: a restore always
# provisions a NEW MariaDB instance and never overwrites in place. The engine
# version and storage size are derived from the namespace's still-present
# instance (a logical restore is far less version-sensitive than a physical one,
# but the new instance still needs a spec to stand up).
#
# The source is chosen by name (`backup` input) or, when omitted, the most
# recent `Backup` CR in the namespace. The referenced Backup object must still
# exist in-cluster — the operator reads its storage location to restore.
# =============================================================================

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi

# shellcheck source=../../lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"  # logging, response, k8s, operator-profile + helpers
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"              # for mariadb_resolve_name (source auto-detect)

mdbt_load_config

OP="logical-restore"

# --- User-facing inputs ------------------------------------------------------
NAMESPACE="${DB_NAMESPACE:-}"          # the database identity — the only required input
BACKUP_NAME="${BACKUP_NAME:-}"         # optional: omit → most recent Backup in the namespace
CONFIRM="${CONFIRM:-false}"
DRY_RUN="${DRY_RUN:-true}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"
K8S_CONTEXT="${K8S_CONTEXT:-}"

# --- Platform internals (NOT task inputs) ------------------------------------
TARGET="${RESTORE_TARGET:-}"           # restored instance name — auto-named below
SOURCE_NAME="${RESTORE_SOURCE:-}"      # which instance to copy the spec from
IMAGE="${RESTORE_IMAGE:-}"
STORAGE_SIZE="${STORAGE_SIZE:-}"
SOURCE_RESOURCES_JSON="null"
ROOT_SECRET_NAME="mariadb"
ROOT_SECRET_KEY="password"
REPLICAS="1"                           # restore is standalone by design

logical_restore_unhandled_error() {
  trap - ERR
  mdbt_write_result "$(mdbt_error_response "${OP:-logical-restore}" "logical restore failed" \
    "$(jq -n --arg namespace "${NAMESPACE:-}" --argjson dry "$(mdbt_bool_json "${DRY_RUN:-false}")" \
       '{namespace:$namespace,contentType:"Logical",state:"FAILED",dryRun:$dry,provisioned:false,restored:false}')" \
    1 "INTERNAL_ERROR")"
  exit 1
}
trap logical_restore_unhandled_error ERR

# Convert Kubernetes/Go-style wait values (for example 1500ms, 10m, or 1h30m)
# into one overall restore deadline shared by both conditions. Python is part
# of the task image and keeps decimal/sub-second compatibility with kubectl;
# positive sub-second values round up to the next whole second.
logical_restore_timeout_seconds() {
  python3 - "$1" <<'PY'
import re
import sys
from decimal import Decimal, InvalidOperation, ROUND_CEILING

value = sys.argv[1]
if value.startswith("+"):
    value = value[1:]

token = re.compile(r"(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:ns|us|µs|μs|ms|s|m|h)")
scales = {
    "ns": Decimal("0.000000001"),
    "us": Decimal("0.000001"),
    "µs": Decimal("0.000001"),
    "μs": Decimal("0.000001"),
    "ms": Decimal("0.001"),
    "s": Decimal(1),
    "m": Decimal(60),
    "h": Decimal(3600),
}

position = 0
total = Decimal(0)
try:
    while position < len(value):
        match = token.match(value, position)
        if match is None:
            raise ValueError
        part = match.group(0)
        unit = next(unit for unit in scales if part.endswith(unit))
        total += Decimal(part[:-len(unit)]) * scales[unit]
        position = match.end()
except (InvalidOperation, ValueError):
    sys.exit(1)

if not value or total <= 0 or total > Decimal(2_147_483_647):
    sys.exit(1)
print(int(total.to_integral_value(rounding=ROUND_CEILING)))
PY
}

WAIT_TIMEOUT_SECONDS=0
if [[ "$WAIT_TIMEOUT" != "0" ]]; then
  if ! WAIT_TIMEOUT_SECONDS="$(logical_restore_timeout_seconds "$WAIT_TIMEOUT")"; then
    mdbt_fail "$OP" "wait_timeout must be 0 or a positive duration" \
      "$(jq -n '{field:"wait_timeout"}')" 2 "INVALID_REQUEST"
  fi
fi

# Confirm is required to apply; a dry run renders the plan without it.
if [[ "$(mdbt_bool_json "$DRY_RUN")" != "true" ]]; then
  mdbt_require_confirm "$OP" "$CONFIRM"
fi

mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"
if [[ -n "$BACKUP_NAME" ]]; then
  mdbt_validate_dns_label "backup" "$BACKUP_NAME" "$OP"
fi
if [[ -n "$K8S_CONTEXT" ]]; then
  mdbt_validate_internal_or_fail "$OP" "INTERNAL_ERROR" "database service is unavailable" \
    mdbt_validate_context "context" "$K8S_CONTEXT" "$OP"
fi

mariadb_set_target "$K8S_CONTEXT" "$NAMESPACE"

# Name the restored instance when the platform did not supply one.
if [[ -z "$TARGET" ]]; then
  TARGET="${NAMESPACE}-lrestore-$(date +%Y%m%d%H%M%S)"
fi

# Derive engine version + storage from the namespace's own state, exactly like
# the physical restore (never guess across mixed versions).
if [[ -z "$SOURCE_NAME" && ( -z "$IMAGE" || -z "$STORAGE_SIZE" ) ]]; then
  if SOURCE_NAME="$(mariadb_resolve_name)"; then :; else SOURCE_NAME=""; fi
fi
if [[ -n "$SOURCE_NAME" ]]; then
  SOURCE_JSON="$(_kubectl get mariadb "$SOURCE_NAME" -o json 2>/dev/null || true)"
  if [[ -n "$SOURCE_JSON" ]]; then
    [[ -z "$IMAGE" ]]        && IMAGE="$(jq -r '.spec.image // empty' <<<"$SOURCE_JSON")"
    [[ -z "$STORAGE_SIZE" ]] && STORAGE_SIZE="$(jq -r '.spec.storage.size // empty' <<<"$SOURCE_JSON")"
    SOURCE_RESOURCES_JSON="$(jq -c '.spec.resources // null' <<<"$SOURCE_JSON")"
  fi
fi
if [[ -z "$IMAGE" ]]; then
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
      "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "RESTORE_CAPABILITY_UNAVAILABLE"
  fi
fi
if [[ -z "$STORAGE_SIZE" ]]; then
  mdbt_fail "$OP" "restore configuration is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "RESTORE_CAPABILITY_UNAVAILABLE"
fi

# Platform-derived values must never be reflected through the public contract.
_validate_restore_internal() {
  mdbt_validate_internal_or_fail "$OP" "RESTORE_CAPABILITY_UNAVAILABLE" \
    "restore configuration is unavailable" "$@"
}
_validate_restore_internal mdbt_validate_dns_label "target" "$TARGET" "$OP"
_validate_restore_internal mdbt_validate_image "image" "$IMAGE" "$OP"
_validate_restore_internal mdbt_validate_storage_size "storage_size" "$STORAGE_SIZE" "$OP"

# Build the MariaDB CR with bootstrapFrom.backupRef (logical). backupRef is
# resolved to a concrete Backup name below (dry run may leave it auto).
build_manifest() {
  local backup_ref="$1"
  jq -n \
    --arg apiVersion "$(mdb_operator_apiversion)" \
    --arg target "$TARGET" \
    --arg namespace "$NAMESPACE" \
    --arg image "$IMAGE" \
    --arg rootSecret "$ROOT_SECRET_NAME" \
    --arg rootKey "$ROOT_SECRET_KEY" \
    --arg storageSize "$STORAGE_SIZE" \
    --argjson replicas "$REPLICAS" \
    --arg backupRef "$backup_ref" \
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
        bootstrapFrom: {backupRef: {name: $backupRef}}
      } + (($resourcesJson | try fromjson catch null) as $r | if $r == null then {} else {resources: $r} end))
    }'
}

# restore_result <provisioned:bool> <restored:bool> <dryRun:bool> <state>
restore_result() {
  jq -n \
    --arg namespace "$NAMESPACE" \
    --arg state "$4" \
    --argjson provisioned "$1" \
    --argjson restored "$2" \
    --argjson dry "$3" \
    '{
      namespace: $namespace,
      contentType: "Logical",
      state: $state,
      dryRun: $dry,
      provisioned: $provisioned,
      restored: $restored
    }'
}

# Mutating and dry-run routes both need a confidently resolved operator API.
# Keep discovery and CRD details behind the public capability reason.
operator_confidence_rc=0
mdb_operator_group_is_confident >/dev/null 2>&1 || operator_confidence_rc=$?
if [[ "$operator_confidence_rc" -ne 0 ]]; then
  mdbt_fail "$OP" "logical restore capability is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "RESTORE_CAPABILITY_UNAVAILABLE"
fi

if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  # Validate that an internal manifest can be prepared, but never return it.
  if ! build_manifest "${BACKUP_NAME:-logical-backup}" >/dev/null 2>&1; then
    trap - ERR
    mdbt_fail "$OP" "logical restore could not be prepared" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns,provisioned:false,restored:false,state:"FAILED"}')" \
      1 "INTERNAL_ERROR"
  fi
  mdbt_write_result "$(response_ok "$OP" "logical restore dry run completed" "$(restore_result false false true PLANNED)")"
  exit 0
fi

# Capability failures are public categories, not CRD or API-group diagnostics.
if ! mdb_has_crd backups >/dev/null 2>&1; then
  mdbt_fail "$OP" "logical restore capability is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "RESTORE_CAPABILITY_UNAVAILABLE"
fi

# Resolve which Backup to restore: explicit name, else the most recent one.
if [[ -z "$BACKUP_NAME" ]]; then
  BACKUP_ROWS=""
  if ! BACKUP_ROWS="$(_kubectl get backup \
    -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null)"; then
    trap - ERR
    mdbt_fail "$OP" "logical restore capability is unavailable" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "RESTORE_CAPABILITY_UNAVAILABLE"
  fi
  BACKUP_NAME="$(printf '%s' "$BACKUP_ROWS" | sed '/^[[:space:]]*$/d' | sort -r | head -1 | cut -f2)"
  if [[ -z "$BACKUP_NAME" ]]; then
    trap - ERR
    mdbt_fail "$OP" "no logical backup is available to restore" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns,provisioned:false,restored:false,state:"FAILED"}')" \
      2 "BACKUP_NOT_FOUND"
  fi
fi
if ! _kubectl get backup "$BACKUP_NAME" >/dev/null 2>&1; then
  trap - ERR
  mdbt_fail "$OP" "logical backup is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns,provisioned:false,restored:false,state:"FAILED"}')" \
    2 "BACKUP_NOT_FOUND"
fi

# Restore never overwrites in place — refuse if the target already exists.
if _kubectl get mariadb "$TARGET" >/dev/null 2>&1; then
  trap - ERR
  mdbt_fail "$OP" "restore target is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns,provisioned:false,restored:false,state:"FAILED"}')" \
    1 "RESTORE_FAILED"
fi

if ! MANIFEST="$(build_manifest "$BACKUP_NAME" 2>/dev/null)"; then
  trap - ERR
  mdbt_fail "$OP" "logical restore could not be prepared" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns,provisioned:false,restored:false,state:"FAILED"}')" \
    1 "INTERNAL_ERROR"
fi
if ! printf '%s\n' "$MANIFEST" | _kubectl apply -f - >/dev/null 2>&1; then
  trap - ERR
  mdbt_fail "$OP" "logical restore could not be started" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns,provisioned:false,restored:false,state:"FAILED"}')" \
    1 "RESTORE_FAILED"
fi

if [[ "$WAIT_TIMEOUT" != "0" ]]; then
  wait_deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
  wait_remaining=$((wait_deadline - SECONDS))
  if [[ "$wait_remaining" -le 0 ]] \
      || ! mdbt_wait_mariadb_backup_restored "$TARGET" "${wait_remaining}s" >/dev/null 2>&1; then
    mdbt_write_result "$(mdbt_error_response "$OP" "logical restore is still pending" \
      "$(restore_result true false false PENDING)" 1 "RESTORE_TIMEOUT")"
    exit 1
  fi
  wait_remaining=$((wait_deadline - SECONDS))
  if [[ "$wait_remaining" -lt 0 ]]; then
    wait_remaining=0
  fi
  # Even at the deadline, perform one non-blocking Ready observation so an
  # already-complete restore is not reported as pending due to rounding.
  if ! mdbt_wait_mariadb_ready "$TARGET" "${wait_remaining}s" >/dev/null 2>&1; then
    mdbt_write_result "$(mdbt_error_response "$OP" "logical restore is still pending" \
      "$(restore_result true false false PENDING)" 1 "RESTORE_TIMEOUT")"
    exit 1
  fi
fi

if [[ "$WAIT_TIMEOUT" == "0" ]]; then
  mdbt_write_result "$(response_ok "$OP" "logical restore requested" "$(restore_result true false false REQUESTED)")"
else
  mdbt_write_result "$(response_ok "$OP" "logical restore completed" "$(restore_result true true false COMPLETED)")"
fi
