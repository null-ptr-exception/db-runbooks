#!/usr/bin/env bash
# =============================================================================
# lib/mariadb-replication-rebuild.sh
# v24 in-place restore for a standby whose history can no longer resume
# replication.
#
# Called by replication/attach after the primary has produced one exact
# physical-backup object. The same primitive is exposed by restore-in-place.sh;
# keeping the destructive operation here means both entry points share the same
# fencing, volume, and failure semantics.
#
#   1. force the StatefulSet to OnDelete so the temporary template is inert
#   2. append one-shot restore init containers to the MariaDB CR
#   3. delete the old Pods; every replacement restores its own PVC before
#      mysqld is allowed to start
#   4. remove the restore hook and delete the Pods once more so they start from
#      the restored datadir using the original Pod template
#
# The MariaDB CR and its PVCs are never deleted. An earlier version did delete
# them — because `bootstrapFrom` only applies to a brand-new instance — which
# made this irreversible: a failure after the delete left no standby at all.
# v0.0.24 supports user initContainers and defaults their volume mounts to the
# MariaDB storage volume. This is the safe in-place hook: MariaDB's own restore
# documentation requires the server to be stopped and the datadir to be empty.
# A standalone Job plus StatefulSet scale-to-zero is not used because the v24
# reconciler writes StatefulSet replicas back from MariaDB.spec.replicas.
#
# The backup carries its own replication coordinates (`xtrabackup_binlog_info`,
# `xtrabackup_slave_info`), so nothing here has to derive a GTID position.
#
# The caller supplies the exact backup name: a stale object cannot be selected by
# a broad "latest under prefix" lookup.
#
# NOTE: this cannot fix a server_id collision. `serverIdStartIndex` is immutable,
# so only a redeploy can change it — which is correct, since that value is the
# deployment's declaration, not something a task should quietly rewrite.
# =============================================================================

[[ -n "${_MARIADB_REPLICATION_REBUILD_LOADED:-}" ]] && return 0
_MARIADB_REPLICATION_REBUILD_LOADED=1

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$SCRIPT_DIR"
fi

# shellcheck source=aqsh-tasks/lib/mariadb-replication-link.sh
source "${LIB_DIR}/mariadb-replication-link.sh"
# shellcheck source=aqsh-tasks/lib/minio-client.sh
source "${LIB_DIR}/minio-client.sh"

MDBR_PEER_TASK_TIMEOUT="${REPL_PEER_TASK_TIMEOUT_DEFAULT:-900}"
# The operator's volumeClaimTemplate name, which prefixes every data PVC it
# creates (<template>-<mdb>-<ordinal>). Same knob the hand-rolled restore uses.
MDBR_PVC_TEMPLATE="${MARIADB_PVC_TEMPLATE:-storage}"
# mysqld's uid, to hand the restored datadir back to.
MDBR_RUN_AS_USER="${MARIADB_RUN_AS_USER:-999}"
MDBR_S5CMD_IMAGE="${S5CMD_IMAGE:-peakcom/s5cmd:v2.3.0}"
# Needs bunzip2/gunzip; the MariaDB image ships neither. Busybox covers both.
MDBR_DECOMPRESS_IMAGE="${REPL_DECOMPRESS_IMAGE_DEFAULT:-alpine:3.20}"
# v0.0.24 mounts the MariaDB storage volume at this fixed path. Keep it fixed:
# the restore hook removes every top-level child and must never accept a
# caller-controlled deletion target.
MDBR_DATADIR="/var/lib/mysql"
MDBR_RESTORE_DIR="${MDBR_DATADIR}/.aqsh-restore"

# --- volume discovery --------------------------------------------------------

# _mdbr_data_pvcs
# The standby's data volumes, found two ways so a mismatched label convention
# cannot silently leave a datadir untouched. Returns 1 if either listing FAILS:
# swallowing that would let the restore skip a volume and still report success.
_mdbr_data_pvcs() {
  local by_label by_name
  by_label="$(_kubectl get pvc -l "app.kubernetes.io/instance=${MDB}" -o name 2>/dev/null)" || return 1
  by_name="$(_kubectl get pvc -o name 2>/dev/null)" || return 1
  {
    printf '%s\n' "$by_label"
    # Anchored to the full <template>-<mdb>-<ordinal> name. A trailing-suffix
    # match would also select another StatefulSet's "storage-foo-${MDB}-0".
    printf '%s\n' "$by_name" \
      | grep -E "^persistentvolumeclaim/${MDBR_PVC_TEMPLATE}-${MDB}-[0-9]+$" || true
  } | sed 's#^persistentvolumeclaim/##' | sed '/^$/d' | sort -u
}

# _mdbr_exact_backup_object <backup_name>
# Resolve the one physical-backup object that belongs to <backup_name>. This is
# deliberately performed before the standby is stopped. s5cmd `ls` is a prefix
# lookup, so filter the response to the only three formats produced by the
# backup task instead of accepting a similarly prefixed sibling.
#
# stdout: exact s3:// URL
# rc: 0 found, 1 storage unavailable, 2 missing, 3 ambiguous, 4 bad credentials
_mdbr_exact_backup_object() {
  local backup="$1" base listing matches count

  mdbt_s3_prepare_direct_client >/dev/null 2>&1 || return 4
  setup_minio_client >/dev/null 2>&1 || return 1

  base="s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/${backup}.xb"
  if ! listing="$(s5 --json ls "${base}*" 2>&1)"; then
    grep -q "no object found" <<<"$listing" && return 2
    return 1
  fi

  matches="$(printf '%s' "$listing" | jq -r --arg base "$base" '
    select(.type != "directory")
    | .key
    | select(. == $base or . == ($base + ".bz2") or . == ($base + ".gz"))
  ' 2>/dev/null)" || return 1
  count="$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"
  case "$count" in
    0) return 2 ;;
    1) printf '%s\n' "$matches" ;;
    *) return 3 ;;
  esac
}

# --- one-shot Pod restore hook ----------------------------------------------

# _mdbr_restore_init_containers <image> <backup_object> <backup_name>
# Emit the v0.0.24 MariaDB.spec.initContainers entries appended temporarily to
# the user's existing list. The operator supplies its storage volume mounts.
_mdbr_restore_init_containers() {
  local image="$1" backup_object="$2" backup_name="$3"
  jq -n \
    --arg image "$image" --arg backupObject "$backup_object" --arg backup "$backup_name" \
    --arg s5cmd "$MDBR_S5CMD_IMAGE" --arg decompress "$MDBR_DECOMPRESS_IMAGE" \
    --arg endpoint "$BACKUP_ENDPOINT" --arg datadir "$MDBR_DATADIR" \
    --arg restoreDir "$MDBR_RESTORE_DIR" \
    --arg accessSecret "$BACKUP_ACCESS_SECRET" --arg accessKey "$BACKUP_ACCESS_KEY" \
    --arg secretSecret "$BACKUP_SECRET_ACCESS_SECRET" --arg secretKey "$BACKUP_SECRET_KEY" \
    --argjson uid "$MDBR_RUN_AS_USER" \
    '[
      {
        image: $decompress, command: ["sh", "-ceu"],
        args: [("mkdir -p " + ($restoreDir|@sh))],
        securityContext: {runAsUser: 0}
      },
      {
        image: $s5cmd, command: ["/s5cmd"],
        args: ["--endpoint-url", $endpoint, "cp", $backupObject,
               ($restoreDir + "/backup.source")],
        env: [
          {name:"AWS_ACCESS_KEY_ID",valueFrom:{secretKeyRef:{name:$accessSecret,key:$accessKey}}},
          {name:"AWS_SECRET_ACCESS_KEY",valueFrom:{secretKeyRef:{name:$secretSecret,key:$secretKey}}}
        ],
        securityContext: {runAsUser: 0}
      },
      {
        image: $decompress, command: ["sh", "-ceu"],
        env: [{name:"BACKUP_OBJECT",value:$backupObject}],
        args: [("case \"$BACKUP_OBJECT\" in *.bz2) bunzip2 -c " + ($restoreDir|@sh) + "/backup.source > " + ($restoreDir|@sh) + "/backup.xb ;; *.gz) gunzip -c " + ($restoreDir|@sh) + "/backup.source > " + ($restoreDir|@sh) + "/backup.xb ;; *.xb) cp " + ($restoreDir|@sh) + "/backup.source " + ($restoreDir|@sh) + "/backup.xb ;; *) echo unsupported-backup-format >&2; exit 1 ;; esac; test -s " + ($restoreDir|@sh) + "/backup.xb")],
        securityContext: {runAsUser: 0}
      },
      {
        image: $image, command: ["bash", "-ceu"],
        env: [{name:"AQSH_RESTORE_BACKUP",value:$backup}],
        args: [("marker=" + ($restoreDir|@sh) + "/completed; if test -f \"$marker\" && grep -Fxq \"$AQSH_RESTORE_BACKUP\" \"$marker\"; then exit 0; fi; find " + ($datadir|@sh) + " -mindepth 1 -maxdepth 1 ! -name .aqsh-restore -exec rm -rf -- {} +; mbstream -x -C " + ($datadir|@sh) + " < " + ($restoreDir|@sh) + "/backup.xb; mariabackup --prepare --target-dir=" + ($datadir|@sh) + "; chown -R " + ($uid|tostring) + ":" + ($uid|tostring) + " " + ($datadir|@sh) + "; printf \"%s\\n\" \"$AQSH_RESTORE_BACKUP\" > \"$marker\"")],
        securityContext: {runAsUser: 0}
      }
    ]'
}

_mdbr_patch_init_containers() {
  local init_json="$1"
  _kubectl patch "$MARIADB_RESOURCE" "$MDB" --type merge \
    -p "$(jq -nc --argjson init "$init_json" '{spec:{initContainers:$init}}')" >/dev/null 2>&1
}

_mdbr_patch_sts_strategy() {
  local strategy_json="$1"
  _kubectl patch statefulset "$MDB" --type merge \
    -p "$(jq -nc --argjson strategy "$strategy_json" '{spec:{updateStrategy:$strategy}}')" >/dev/null 2>&1
}

_mdbr_wait_sts_init_count() {
  local expected="$1" timeout="$2" elapsed=0 sts
  while (( elapsed <= timeout )); do
    sts="$(_kubectl get statefulset "$MDB" -o json 2>/dev/null)" || sts='{}'
    if [[ "$(jq -r '(.spec.template.spec.initContainers // []) | length' <<<"$sts")" == "$expected" ]]; then
      return 0
    fi
    (( elapsed >= timeout )) && break
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

# Delete every old member in one API call, then require replacement UIDs and
# Ready containers. OnDelete prevents the template change itself from rolling
# a Pod before all old members have been selected for deletion.
_mdbr_restart_members() {
  local timeout="$1" elapsed=0 pod json all_ready i
  local -a pods=() old_uids=()
  mapfile -t pods < <(mariadb_list_member_pods)
  (( ${#pods[@]} > 0 )) || return 1
  for pod in "${pods[@]}"; do
    old_uids+=("$(_kubectl get pod "$pod" -o jsonpath='{.metadata.uid}' 2>/dev/null)")
  done
  _kubectl delete pod "${pods[@]}" --wait=false >/dev/null 2>&1 || return 1

  while (( elapsed <= timeout )); do
    all_ready=true
    for i in "${!pods[@]}"; do
      pod="${pods[$i]}"
      json="$(_kubectl get pod "$pod" -o json 2>/dev/null)" || { all_ready=false; continue; }
      [[ "$(jq -r '.metadata.uid // empty' <<<"$json")" != "${old_uids[$i]}" ]] || all_ready=false
      jq -e '.status.phase == "Running" and any(.status.containerStatuses[]?; .name == "mariadb" and .ready == true)' \
        <<<"$json" >/dev/null 2>&1 || all_ready=false
    done
    [[ "$all_ready" == true ]] && return 0
    (( elapsed >= timeout )) && break
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

# --- orchestration -----------------------------------------------------------

# mdbr_rebuild_standby <op> <data_fn>
# Reads from the caller's scope: NAMESPACE, MDB, MARIADB_RESOURCE, CR_JSON,
# PRIMARY_POD, ROOT_PASSWORD, BACKUP_NAME, WAIT_TIMEOUT, and the BACKUP_* set
# left by mdbt_resolve_backup_location. <data_fn> is a
# caller-supplied function taking <stage> <changed> that builds the public
# result payload, so the calling task keeps one consistent result shape.
#
# Returns 0 once the standby is back up on the restored data. Every failure path
# calls mdbt_fail (which exits). Failures after overwrite starts retain OnDelete
# and the idempotent restore hook so Pod replacement retries the exact backup
# before mysqld starts.
mdbr_rebuild_standby() {
  local op="$1" data_fn="$2"
  local image recheck rc=0 pvc_list backup_object backup_rc=0 sts_json
  local original_strategy original_init restore_init combined_init expected_init_count pod
  local -a pvcs=() pods=()

  if [[ -z "${BACKUP_NAME:-}" ]]; then
    mdbt_fail "$op" "an exact physical backup is required" \
      "$("$data_fn" capture false)" 2 BACKUP_NOT_FOUND
  fi
  mdbt_validate_dns_label "backup" "$BACKUP_NAME" "$op"

  mdbt_validate_internal_or_fail "$op" BACKUP_CONFIGURATION_UNAVAILABLE \
    "backup configuration is unavailable" \
    mdbt_validate_s3_bucket "backup_bucket" "$BACKUP_BUCKET" "$op"
  mdbt_validate_internal_or_fail "$op" BACKUP_CONFIGURATION_UNAVAILABLE \
    "backup configuration is unavailable" \
    mdbt_validate_s3_prefix "backup_prefix" "$BACKUP_PREFIX" "$op"
  mdbt_validate_internal_or_fail "$op" BACKUP_CONFIGURATION_UNAVAILABLE \
    "backup configuration is unavailable" \
    mdbt_validate_endpoint "backup_endpoint" "$BACKUP_ENDPOINT" "$op"

  image="$(jq -r '.spec.image // empty' <<<"$CR_JSON")"
  if [[ -z "$image" ]]; then
    mdbt_fail "$op" "database image could not be resolved" \
      "$("$data_fn" capture false)" 1 INTERNAL_ERROR
  fi
  mdbt_validate_internal_or_fail "$op" INTERNAL_ERROR \
    "restore runtime configuration is unavailable" \
    mdbt_validate_image "database_image" "$image" "$op"
  mdbt_validate_internal_or_fail "$op" INTERNAL_ERROR \
    "restore runtime configuration is unavailable" \
    mdbt_validate_image "s5cmd_image" "$MDBR_S5CMD_IMAGE" "$op"
  mdbt_validate_internal_or_fail "$op" INTERNAL_ERROR \
    "restore runtime configuration is unavailable" \
    mdbt_validate_image "decompress_image" "$MDBR_DECOMPRESS_IMAGE" "$op"
  mdbt_validate_internal_or_fail "$op" INTERNAL_ERROR \
    "restore runtime configuration is unavailable" \
    mdbt_validate_uint "run_as_user" "$MDBR_RUN_AS_USER" "$op"
  mdbt_validate_internal_or_fail "$op" BACKUP_CONFIGURATION_UNAVAILABLE \
    "backup configuration is unavailable" \
    mdbt_validate_dns_label "backup_access_secret" "$BACKUP_ACCESS_SECRET" "$op"
  mdbt_validate_internal_or_fail "$op" BACKUP_CONFIGURATION_UNAVAILABLE \
    "backup configuration is unavailable" \
    mdbt_validate_secret_key "backup_access_key" "$BACKUP_ACCESS_KEY" "$op"
  mdbt_validate_internal_or_fail "$op" BACKUP_CONFIGURATION_UNAVAILABLE \
    "backup configuration is unavailable" \
    mdbt_validate_dns_label "backup_secret_access_secret" "$BACKUP_SECRET_ACCESS_SECRET" "$op"
  mdbt_validate_internal_or_fail "$op" BACKUP_CONFIGURATION_UNAVAILABLE \
    "backup configuration is unavailable" \
    mdbt_validate_secret_key "backup_secret_key" "$BACKUP_SECRET_KEY" "$op"

  # Volumes are discovered before the Pod template changes: a listing failure
  # here leaves the running database untouched.
  pvc_list="$(_mdbr_data_pvcs)" || rc=$?
  if (( rc != 0 )); then
    mdbt_fail "$op" "standby data volumes could not be listed" \
      "$("$data_fn" capture false)" 1 INTERNAL_ERROR
  fi
  if [[ -n "$pvc_list" ]]; then
    mapfile -t pvcs <<<"$pvc_list"
  fi
  if (( ${#pvcs[@]} == 0 )); then
    mdbt_fail "$op" "standby has no data volumes to restore" \
      "$("$data_fn" capture false)" 1 INTERNAL_ERROR
  fi

  # Resolve the exact object before stopping the database. The caller has
  # already asked the primary for this backup; this proves it is visible from
  # the standby's storage policy and rules out prefix siblings/duplicates.
  backup_object="$(_mdbr_exact_backup_object "$BACKUP_NAME")" || backup_rc=$?
  case "$backup_rc" in
    0) ;;
    2) mdbt_fail "$op" "physical backup is not available" \
         "$("$data_fn" capture false)" 1 BACKUP_NOT_FOUND ;;
    3) mdbt_fail "$op" "physical backup source is ambiguous" \
         "$("$data_fn" capture false)" 1 BACKUP_AMBIGUOUS ;;
    4) mdbt_fail "$op" "backup configuration is unavailable" \
         "$("$data_fn" capture false)" 1 BACKUP_CONFIGURATION_UNAVAILABLE ;;
    *) mdbt_fail "$op" "backup service is unavailable" \
         "$("$data_fn" capture false)" 1 BACKUP_SERVICE_UNAVAILABLE ;;
  esac

  sts_json="$(_kubectl get statefulset "$MDB" -o json 2>/dev/null)" || \
    mdbt_fail "$op" "standby workload is unavailable" \
      "$("$data_fn" capture false)" 1 DATABASE_NOT_READY
  original_strategy="$(jq -c '.spec.updateStrategy // {type:"RollingUpdate"}' <<<"$sts_json")"
  original_init="$(jq -c 'if (.spec | has("initContainers")) then .spec.initContainers else null end' \
    <<<"$CR_JSON")"
  restore_init="$(_mdbr_restore_init_containers "$image" "$backup_object" "$BACKUP_NAME")" || \
    mdbt_fail "$op" "restore hook could not be constructed" \
      "$("$data_fn" capture false)" 1 INTERNAL_ERROR
  combined_init="$(jq -nc --argjson original "${original_init:-null}" \
    --argjson restore "$restore_init" '($original // []) + $restore')"
  expected_init_count="$(jq -r 'length' <<<"$combined_init")"

  mapfile -t pods < <(mariadb_list_member_pods)
  if (( ${#pods[@]} == 0 || ${#pods[@]} != ${#pvcs[@]} )); then
    mdbt_fail "$op" "standby members do not match its data volumes" \
      "$("$data_fn" capture false)" 1 DATABASE_NOT_READY
  fi

  # Last look before the restore hook is armed. The following OnDelete strategy
  # prevents the template patch from restarting a Pod before every old member
  # has been selected for deletion.
  if ! recheck="$(mdbr_external_connections "$PRIMARY_POD" "$ROOT_PASSWORD")"; then
    mdbt_fail "$op" "connection usage could not be re-read before restoring" \
      "$("$data_fn" fence false)" 1 DATABASE_NOT_READY
  fi
  if (( "$(jq -r '.total' <<<"$recheck")" > MDBR_MAX_EXTERNAL_CONNECTIONS )); then
    mdbt_fail "$op" "standby acquired external connections while the backup was running" \
      "$("$data_fn" fence false)" 1 STANDBY_IN_USE
  fi

  if ! _mdbr_patch_sts_strategy '{"type":"OnDelete"}'; then
    mdbt_fail "$op" "standby restart policy could not be fenced" \
      "$("$data_fn" fence false)" 1 INTERNAL_ERROR
  fi
  if ! _mdbr_patch_init_containers "$combined_init"; then
    _mdbr_patch_sts_strategy "$original_strategy" || true
    mdbt_fail "$op" "standby restore hook could not be installed" \
      "$("$data_fn" fence false)" 1 INTERNAL_ERROR
  fi
  if ! _mdbr_wait_sts_init_count "$expected_init_count" "$WAIT_TIMEOUT"; then
    _mdbr_patch_init_containers "$original_init" || true
    _mdbr_patch_sts_strategy "$original_strategy" || true
    mdbt_fail "$op" "standby restore hook was not reconciled" \
      "$("$data_fn" fence false)" 1 RESTORE_TIMEOUT
  fi

  # Every replacement Pod restores its own PVC in initContainers. mysqld cannot
  # run concurrently with the wipe because Kubernetes does not start the main
  # container until all restore init containers have completed.
  if ! _mdbr_restart_members "$WAIT_TIMEOUT"; then
    mdbt_fail "$op" "standby restore did not complete" \
      "$("$data_fn" restore true)" 1 RESTORE_TIMEOUT
  fi

  mapfile -t pods < <(mariadb_list_member_pods)
  for pod in "${pods[@]}"; do
    if ! mariadb_exec "$pod" sh -ceu \
      'test "$(cat "$1/completed")" = "$2"' sh "$MDBR_RESTORE_DIR" "$BACKUP_NAME" \
      >/dev/null 2>&1; then
      mdbt_fail "$op" "standby restore marker could not be verified" \
        "$("$data_fn" restore true)" 1 RESTORE_FAILED
    fi
  done

  # Restore the user's init container list while OnDelete is still active, then
  # explicitly restart once more. This is the internal in-place pattern: the
  # restore finishes first, and the final delete makes MariaDB consume the new
  # datadir without carrying the one-shot hook in its template.
  if ! _mdbr_patch_init_containers "$original_init"; then
    mdbt_fail "$op" "standby restore hook could not be removed" \
      "$("$data_fn" finalize true)" 1 INTERNAL_ERROR
  fi
  expected_init_count="$(jq -r '(. // []) | length' <<<"$original_init")"
  if ! _mdbr_wait_sts_init_count "$expected_init_count" "$WAIT_TIMEOUT"; then
    mdbt_fail "$op" "standby clean template was not reconciled" \
      "$("$data_fn" finalize true)" 1 RESTORE_TIMEOUT
  fi
  if ! _mdbr_restart_members "$WAIT_TIMEOUT"; then
    mdbt_fail "$op" "standby did not restart on the restored datadir" \
      "$("$data_fn" finalize true)" 1 RESTORE_TIMEOUT
  fi
  if ! _mdbr_patch_sts_strategy "$original_strategy"; then
    mdbt_fail "$op" "standby restart policy could not be restored" \
      "$("$data_fn" finalize true)" 1 INTERNAL_ERROR
  fi

  mapfile -t pods < <(mariadb_list_member_pods)
  for pod in "${pods[@]}"; do
    if ! mariadb_exec "$pod" rm -rf -- "$MDBR_RESTORE_DIR" >/dev/null 2>&1; then
      log_warn "$op" "restored data is ready, but staging cleanup failed on ${pod}"
    fi
  done
  return 0
}
