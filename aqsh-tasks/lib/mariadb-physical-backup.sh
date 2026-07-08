#!/usr/bin/env bash
# =============================================================================
# lib/mariadb-physical-backup.sh
# Hand-rolled physical (mariabackup) backup for clusters whose operator has no
# `PhysicalBackup` CRD (the legacy mmontes-era generation). The current-
# generation path stays in physical-backup.sh driving the operator CR; this lib
# is only reached when `mdb_has_crd physicalbackups` is false.
#
# Approach: run `mariabackup --backup --stream=xbstream` INSIDE the source pod
# (that is where the datadir + running server live; the aqsh image ships only
# mariadb-client, not mariabackup) and pipe its stdout straight to S3 via `mc`.
# The artifact lands at s3://<bucket>/<prefix>/<name>.xb, a single xbstream — the
# hand-rolled restore (Phase 2b) reads exactly that layout.
#
# ASSUMPTIONS (validated in the legacy-operator e2e, not here):
#   - the mariadb image in the pod provides `mariabackup` + `mbstream`
#   - the root password is in secret <ROOT_SECRET_NAME>/<ROOT_SECRET_KEY>
#   - streaming exec | mc pipe is acceptable (no resume/checkpoint); fine for the
#     sandbox scale this runbook targets
# =============================================================================

[[ -n "${_MARIADB_PHYSICAL_BACKUP_LOADED:-}" ]] && return 0
_MARIADB_PHYSICAL_BACKUP_LOADED=1

# mdbt_pb_target_pod <mariadb> <target>
# Resolve the pod to run mariabackup on. The operator names pods <mariadb>-0..N.
# We back up from ordinal 0 by default; a Replica target prefers the highest
# ordinal (a replica) to keep load off the primary. Best-effort — falls back to
# <mariadb>-0 when the replica set can't be listed.
mdbt_pb_target_pod() {
  local mariadb="$1" target="${2:-PreferReplica}"
  if [[ "$target" == "Primary" ]]; then
    printf '%s-0' "$mariadb"
    return 0
  fi
  local pods
  pods="$(_kubectl get pods -l "app.kubernetes.io/instance=${mariadb}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sed '/^$/d' | sort -V)"
  if [[ -n "$pods" ]] && [[ "$(printf '%s\n' "$pods" | grep -c .)" -gt 1 ]]; then
    printf '%s' "$pods" | tail -1        # highest ordinal → a replica
  else
    printf '%s-0' "$mariadb"
  fi
}

# mdbt_pb_handrolled_plan <pod> <object>
# JSON plan payload for the dry run (mirrors the operator path's manifest field).
mdbt_pb_handrolled_plan() {
  local pod="$1" object="$2"
  jq -n --arg pod "$pod" --arg object "$object" \
    '{mode: "hand-rolled", pod: $pod, command: "mariabackup --backup --stream=xbstream", object: $object}'
}

# mdbt_pb_handrolled_run <op> <pod> <root_secret> <root_key> <bucket> <object>
# Stream a physical backup from <pod> to s3://<bucket>/<object>. Returns 0 on
# success; on failure writes nothing (caller renders the error). Echoes nothing.
mdbt_pb_handrolled_run() {
  local op="$1" pod="$2" root_secret="$3" root_key="$4" bucket="$5" object="$6"

  local pw
  pw="$(_kubectl get secret "$root_secret" -o "jsonpath={.data.${root_key}}" 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -z "$pw" ]]; then
    return 3   # no credential — caller reports
  fi

  setup_minio_client >/dev/null 2>&1 || return 4
  ensure_bucket "$bucket" >/dev/null 2>&1 || return 4

  # mariabackup reads MYSQL_PWD from the env (no password on the command line, so
  # it never shows in the pod's process list). PIPESTATUS distinguishes a backup
  # failure (mariabackup) from an upload failure (mc).
  set -o pipefail
  _kubectl exec "$pod" -- env MYSQL_PWD="$pw" \
      mariabackup --backup --stream=xbstream --user=root --host=127.0.0.1 2>/dev/null \
    | mc pipe "minio/${bucket}/${object}"
  local st=$?
  set +o pipefail
  return "$st"
}
