#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# backup/delete-backup-mariadb.sh
# Delete a named backup for a namespace under the shared convention
# (s3://<bucket>/mariadb/<namespace>/<backup>). The AWS-RDS analogue of
# DeleteDBSnapshot.
#
# Mutating: dry_run (default true) renders the plan; applying requires
# dry_run=false and confirm=true. The backup name is a single path segment
# (validated) so a deletion can never escape the namespace's own prefix.
# =============================================================================

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi

MDB_INPUT="${MARIADB_NAME:-}"

# shellcheck source=../../lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"  # logging, response, k8s + generic helpers
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"
# shellcheck source=../../lib/minio-client.sh
source "${LIB_DIR}/minio-client.sh"         # setup_minio_client, s5 (s5cmd)

mdbt_load_config

OP="delete-backup"

NAMESPACE="${DB_NAMESPACE:-}"          # the database identity
BACKUP_NAME="${BACKUP_NAME:-}"         # the backup to delete (single path segment)
CONFIRM="${CONFIRM:-false}"
DRY_RUN="${DRY_RUN:-true}"

# Confirm is required to apply; a dry run renders the plan without it.
if [[ "$(mdbt_bool_json "$DRY_RUN")" != "true" ]]; then
  mdbt_require_confirm "$OP" "$CONFIRM"
fi

mdbt_validate_dns_label "namespace" "$NAMESPACE" "$OP"
mdbt_required "backup" "$BACKUP_NAME" "$OP"
# A single path segment only — no slashes, no traversal — so the delete stays
# confined to this namespace's prefix.
if [[ ! "$BACKUP_NAME" =~ ^[A-Za-z0-9._-]+$ || "$BACKUP_NAME" == "." || "$BACKUP_NAME" == ".." ]]; then
  mdbt_fail "$OP" "backup must be a single name segment (^[A-Za-z0-9._-]+$), not a path" \
    "$(jq -n --arg v "$BACKUP_NAME" '{field: "backup", value: $v}')" 2 "INVALID_REQUEST"
fi

mariadb_set_target "${K8S_CONTEXT:-}" "$NAMESPACE" "$MARIADB_RESOURCE" "$MDB_INPUT"
if [[ -z "$MDB_INPUT" ]]; then
  resolve_rc=0
  resolved="$(mariadb_resolve_name)" || resolve_rc=$?
  case "$resolve_rc" in
    0) MARIADB_NAME="$resolved" ;;
    1) MARIADB_NAME="" ;;
    2) mdbt_fail "$OP" "database configuration is ambiguous" \
         "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 2 "DATABASE_CONFIGURATION_AMBIGUOUS" ;;
  esac
else
  MARIADB_NAME="$MDB_INPUT"
fi

if ! mdbt_resolve_backup_location "$NAMESPACE" "$MARIADB_NAME"; then
  mdbt_fail "$OP" "backup configuration is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_CONFIGURATION_UNAVAILABLE"
fi
TARGET="s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/${BACKUP_NAME}"

delete_result() {
  jq -n \
    --arg namespace "$NAMESPACE" \
    --arg backup "$BACKUP_NAME" \
    --arg state "$3" \
    --argjson dry "$1" \
    --argjson deleted "$2" \
    '{
      namespace: $namespace,
      backup: $backup,
      state: $state,
      dryRun: $dry,
      deleted: $deleted
    }'
}

if [[ "$(mdbt_bool_json "$DRY_RUN")" == "true" ]]; then
  mdbt_write_result "$(response_ok "$OP" "backup deletion dry run completed" "$(delete_result true false PLANNED)")"
  exit 0
fi

if ! mdbt_s3_prepare_direct_client >/dev/null 2>&1; then
  mdbt_fail "$OP" "backup configuration is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace:$ns}')" 1 "BACKUP_CONFIGURATION_UNAVAILABLE"
fi

if ! setup_minio_client >/dev/null 2>&1; then
  mdbt_fail "$OP" "backup service is unavailable" \
    "$(jq -n --arg ns "$NAMESPACE" '{namespace: $ns}')" 1 "BACKUP_SERVICE_UNAVAILABLE"
fi

# `s5cmd ls <name>` matches by PREFIX, so "backup-1" also returns a sibling
# "backup-10". Every presence decision below therefore filters the JSON entries
# down to an EXACT match first: key == name (flat object) or key == name + "/"
# (directory). Emits the matching entries, one per line; exits 1 if none.
_exact_entries() {
  local raw
  raw="$(s5 --json ls "$TARGET" 2>/dev/null)" || return 1
  raw="$(jq -c --arg t "$TARGET" 'select(.key == $t or .key == ($t + "/"))' <<<"$raw")"
  [[ -n "$raw" ]] || return 1
  printf '%s' "$raw"
}

# Existence check + TYPE detection in one exact-filtered `--json ls`. Missing
# (either 'no object found' or only prefix-siblings) => refuse, so a typo
# reports clearly instead of a silent no-op. Other ls failures (auth / network)
# must not masquerade as not-found.
if ! LS_RAW="$(s5 --json ls "$TARGET" 2>&1)"; then
  if ! grep -q "no object found" <<<"$LS_RAW"; then
    # Never reflect arbitrary S3 client stderr into the task result.
    mdbt_fail "$OP" "backup service request failed" \
      "$(jq -n --arg ns "$NAMESPACE" --arg b "$BACKUP_NAME" \
        '{namespace: $ns, backup: $b}')" 1 "BACKUP_SERVICE_UNAVAILABLE"
  fi
fi
if ! ENTRIES="$(_exact_entries)"; then
  mdbt_fail "$OP" "backup '${BACKUP_NAME}' not found for namespace '${NAMESPACE}'" \
    "$(jq -n --arg ns "$NAMESPACE" --arg b "$BACKUP_NAME" '{namespace: $ns, backup: $b}')" 2 "BACKUP_NOT_FOUND"
fi

# Delete by detected type. This must NOT be a bare `s5 rm "$TARGET"` for a
# directory: s5cmd rm on a directory-style name without a wildcard is a silent
# no-op that still exits 0 (verified against MinIO). The wildcard form
# "name/*" cannot over-match a sibling like "name-2" the way "name*" would.
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  etype="$(jq -r '.type // "file"' <<<"$entry")"
  if [[ "$etype" == "directory" ]]; then
    s5 rm "${TARGET}/*" >/dev/null 2>&1 || true
  else
    s5 rm "$TARGET" >/dev/null 2>&1 || true
  fi
done <<<"$ENTRIES"

# Verify-after on the same exact match: the name must now resolve to nothing —
# rm's own exit code cannot be trusted for prefixes (above), and a surviving
# prefix-sibling like "backup-10" must NOT count as "still present".
if _exact_entries >/dev/null; then
  mdbt_fail "$OP" "failed to delete backup '${BACKUP_NAME}' from ${NAMESPACE} (still present after delete)" \
    "$(delete_result false false FAILED)" 1 "BACKUP_FAILED"
fi

mdbt_write_result "$(response_ok "$OP" "backup deleted" "$(delete_result false true DELETED)")"
