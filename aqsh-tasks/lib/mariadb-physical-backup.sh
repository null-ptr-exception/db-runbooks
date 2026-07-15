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
# mariadb-client, not mariabackup) and pipe its stdout straight to S3 via s5cmd.
# The artifact lands at s3://<bucket>/<prefix>/<name>.xb, a single xbstream — the
# hand-rolled restore (Phase 2b) reads exactly that layout.
#
# ASSUMPTIONS (validated in the legacy-operator e2e):
#   - the mariadb image in the pod provides `mariabackup` + `mbstream`
#   - the operator injects MARIADB_ROOT_PASSWORD into the MariaDB container
#   - streaming exec | s5 pipe is acceptable (no resume/checkpoint); fine for the
#     sandbox scale this runbook targets
# =============================================================================

[[ -n "${_MARIADB_PHYSICAL_BACKUP_LOADED:-}" ]] && return 0
_MARIADB_PHYSICAL_BACKUP_LOADED=1

# mdbt_pb_target_pod <mariadb> <target> <current_primary>
# Resolve a Ready pod without assuming ordinal 0 is primary. Explicit Replica
# fails when no Ready replica exists; only PreferReplica may fall back to the
# Ready primary.
mdbt_pb_target_pod() {
  local mariadb="$1" target="${2:-PreferReplica}" primary="${3:-}"
  local pod_json ready_pods replicas selected
  pod_json="$(_kubectl get pods -l "app.kubernetes.io/instance=${mariadb}" -o json 2>/dev/null)" || return 4
  ready_pods="$(jq -r '
    .items[]
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    | .metadata.name
  ' <<<"$pod_json" | sed '/^$/d' | sort -V)"
  [[ -n "$ready_pods" ]] || return 4
  [[ -n "$primary" ]] || return 5

  if [[ "$target" == "Primary" ]]; then
    grep -Fxq "$primary" <<<"$ready_pods" || return 5
    printf '%s' "$primary"
    return 0
  fi

  replicas="$(grep -Fxv "$primary" <<<"$ready_pods" || true)"
  selected="$(printf '%s\n' "$replicas" | sed '/^$/d' | tail -1)"
  if [[ -n "$selected" ]]; then
    printf '%s' "$selected"
    return 0
  fi
  [[ "$target" == "PreferReplica" ]] || return 6
  grep -Fxq "$primary" <<<"$ready_pods" || return 5
  printf '%s' "$primary"
}

# mdbt_pb_handrolled_plan <pod> <object>
# JSON plan payload for the dry run (mirrors the operator path's manifest field).
mdbt_pb_handrolled_plan() {
  local pod="$1" object="$2"
  jq -n --arg pod "$pod" --arg object "$object" \
    '{mode: "hand-rolled", pod: $pod, command: "mariabackup --backup --stream=xbstream", object: $object}'
}

# mdbt_pb_handrolled_run <pod> <container> <bucket> <object>
# Stream a physical backup from <pod> to s3://<bucket>/<object>. Returns 0 on
# success; on failure writes nothing (caller renders the error). Echoes nothing.
mdbt_pb_handrolled_run() {
  local pod="$1" container="$2" bucket="$3" object="$4"
  local stream_timeout="${MDBT_PB_STREAM_TIMEOUT:-3600}"
  [[ "$stream_timeout" =~ ^[1-9][0-9]*$ ]] || return 2
  setup_minio_client >/dev/null 2>&1 || return 4
  ensure_bucket "$bucket" >/dev/null 2>&1 || return 4

  # Resolve the password inside the database container from the operator-injected
  # env. The secret value never appears in kubectl exec arguments/API audit data.
  # A subshell keeps pipefail local while preserving either producer/upload error.
  (
    set -o pipefail
    _kubectl exec "$pod" -c "$container" -- env "MDBT_PB_STREAM_TIMEOUT=${stream_timeout}" sh -ceu '
      if [ -z "${MARIADB_ROOT_PASSWORD:-}" ]; then
        echo "MARIADB_ROOT_PASSWORD is empty" >&2
        exit 3
      fi
      export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
      exec timeout "$MDBT_PB_STREAM_TIMEOUT" mariabackup --backup --stream=xbstream --user=root --host=127.0.0.1
    ' | s5 pipe "s3://${bucket}/${object}"
  )
}
