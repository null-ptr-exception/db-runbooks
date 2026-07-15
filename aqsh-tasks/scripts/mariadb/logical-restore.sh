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
  local code="$?"
  local line="${BASH_LINENO[0]:-unknown}"
  trap - ERR
  mdbt_write_result "$(response_err "${OP:-logical-restore}" "logical-restore aborted before completing at line ${line} (exit ${code})" \
    "$(jq -n --arg namespace "${NAMESPACE:-}" --arg target "${TARGET:-}" \
       '{namespace: $namespace, target: $target}')" "$code")" || true
  exit "$code"
}
trap logical_restore_unhandled_error ERR

# Confirm is required to apply; a dry run renders the plan without it.
if [[ "$(mdbt_bool_json "$DRY_RUN")" != "true" ]]; then
  mdbt_require_confirm "$OP" "$CONFIRM"
fi

mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"
if [[ -n "$K8S_CONTEXT" ]]; then
  mdbt_validate_context "context" "$K8S_CONTEXT" "$OP"
fi

mariadb_set_target "$K8S_CONTEXT" "$NAMESPACE"

# Name the restored instance for the caller when they didn't.
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
    mdbt_fail "$OP" "'${NAMESPACE}' runs multiple MariaDB versions; cannot pick the restore version automatically — operator: set the RESTORE_SOURCE or RESTORE_IMAGE override" \
      "$(jq -n --arg c "$NS_IMAGES" '{versions: ($c | split("\n") | map(select(. != "")))}')" 2
  fi
  if [[ -z "$IMAGE" ]]; then
    mdbt_fail "$OP" "could not determine the MariaDB version for '${NAMESPACE}' (no instance to derive it from) — operator: set the RESTORE_IMAGE override" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2
  fi
fi
if [[ -z "$STORAGE_SIZE" ]]; then
  mdbt_fail "$OP" "could not determine the storage size for '${NAMESPACE}' (no instance to derive it from) — operator: set the RESTORE_SOURCE or STORAGE_SIZE override" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2
fi

mdbt_validate_dns_label "target" "$TARGET" "$OP"
mdbt_validate_image "image" "$IMAGE" "$OP"
mdbt_validate_storage_size "storage_size" "$STORAGE_SIZE" "$OP"

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

CONNECTION_HOST="${TARGET}-primary.${NAMESPACE}.svc.cluster.local"

restore_result() {
  local restored="$1" dry="$2" backup_ref="$3"
  jq -n \
    --arg namespace "$NAMESPACE" \
    --arg target "$TARGET" \
    --arg source "${SOURCE_NAME:-}" \
    --arg image "$IMAGE" \
    --arg backupRef "$backup_ref" \
    --arg host "$CONNECTION_HOST" \
    --arg secretName "$ROOT_SECRET_NAME" \
    --arg secretKey "$ROOT_SECRET_KEY" \
    --arg manifest "$(build_manifest "$backup_ref")" \
    --argjson restored "$restored" \
    --argjson dry "$dry" \
    '{
      namespace: $namespace,
      target: $target,
      source: (if $source == "" then null else $source end),
      image: $image,
      backup: {ref: $backupRef, contentType: "Logical"},
      connection: {host: $host, port: 3306},
      credentialsRef: {secretName: $secretName, secretKey: $secretKey},
      dryRun: $dry,
      restored: $restored
    } + (if $dry then {manifest: $manifest} else {} end)'
}

if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  # Dry run: show the plan. backupRef is echoed as given ("" → resolved at apply).
  mdbt_write_result "$(response_ok "$OP" "dry run: logical restore manifest rendered for ${TARGET}" "$(restore_result false true "${BACKUP_NAME:-<latest-at-apply>}")")"
  exit 0
fi

# The `Backup` CRD must exist — actionable failure instead of `no matches`.
mdb_require_crd backups "$OP" "install the mariadb-operator CRDs" || exit 1

# Resolve which Backup to restore: explicit name, else the most recent one.
if [[ -z "$BACKUP_NAME" ]]; then
  BACKUP_NAME="$(_kubectl get backup \
    -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | sed '/^\s*$/d' | sort -r | head -1 | cut -f2)"
  if [[ -z "$BACKUP_NAME" ]]; then
    trap - ERR
    mdbt_fail "$OP" "no Backup found in '${NAMESPACE}' to restore from (create one with logical-backup first)" \
      "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 2
  fi
fi
if ! _kubectl get backup "$BACKUP_NAME" >/dev/null 2>&1; then
  trap - ERR
  mdbt_fail "$OP" "Backup '${BACKUP_NAME}' not found in '${NAMESPACE}'" \
    "$(jq -n --arg ns "$NAMESPACE" --arg b "$BACKUP_NAME" '{namespace: $ns, backup: $b}')" 2
fi

# Restore never overwrites in place — refuse if the target already exists.
if _kubectl get mariadb "$TARGET" >/dev/null 2>&1; then
  trap - ERR
  mdbt_fail "$OP" "target MariaDB '${TARGET}' already exists; restore provisions a NEW instance and never overwrites in place (choose a different target name)" \
    "$(jq -n --arg ns "$NAMESPACE" --arg target "$TARGET" '{namespace: $ns, target: $target}')" 2
fi

MANIFEST="$(build_manifest "$BACKUP_NAME")"
if ! apply_out="$(printf '%s\n' "$MANIFEST" | _kubectl apply -f - 2>&1)"; then
  trap - ERR
  mdbt_fail "$OP" "failed to apply MariaDB logical-restore manifest: ${apply_out}" \
    "$(jq -n --arg ns "$NAMESPACE" --arg target "$TARGET" '{namespace: $ns, target: $target}')" 3
fi

if [[ "$WAIT_TIMEOUT" != "0" ]]; then
  if ! mdbt_wait_mariadb_backup_restored "$TARGET" "$WAIT_TIMEOUT" >/dev/null 2>&1 \
      || ! mdbt_wait_mariadb_ready "$TARGET" "$WAIT_TIMEOUT"; then
    mdbt_write_result "$(response_err "$OP" "MariaDB ${TARGET} was provisioned but did not become Ready or finish restoring its Backup within ${WAIT_TIMEOUT}" "$(restore_result true false "$BACKUP_NAME")" 1)"
    exit 1
  fi
fi

mdbt_write_result "$(response_ok "$OP" "MariaDB logically restored into new instance ${TARGET} from Backup ${BACKUP_NAME}" "$(restore_result true false "$BACKUP_NAME")")"
