#!/usr/bin/env bash
# =============================================================================
# lib/mariadb-replication-rebuild.sh
# Re-seed a standby whose history can no longer resume replication.
#
# Called by replication/attach when its assessment says so. It is a library
# function rather than a separate task on purpose: the assessment already knows
# which path is needed, so making the caller read that verdict and switch to a
# different endpoint would hand an internal decision back to them to execute.
#
#   1. ask the primary's AQSH for a FRESH physical backup, and wait for it
#   2. quiesce the standby (stop it without the operator restarting it)
#   3. overwrite each data volume IN PLACE from that backup
#   4. resume, and let the operator bring the instance back
#
# The MariaDB CR and its PVCs are never deleted. An earlier version did delete
# them — because `bootstrapFrom` only applies to a brand-new instance — which
# made this irreversible: a failure after the delete left no standby at all.
# Overwriting the datadir directly needs no CR-level restore mechanism, so a
# failure leaves the instance in place to retry or inspect, and every failure
# path below resumes it rather than leaving it stopped.
#
# The backup carries its own replication coordinates (`xtrabackup_binlog_info`,
# `xtrabackup_slave_info`), so nothing here has to derive a GTID position.
#
# Step 1 takes a fresh backup rather than reusing the newest object in the
# bucket: a stale one restores the standby to a position that may again predate
# the primary's retained binlog, failing the very check that sent us here.
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

MDBR_PEER_TASK_TIMEOUT="${REPL_PEER_TASK_TIMEOUT_DEFAULT:-900}"
# The operator's volumeClaimTemplate name, which prefixes every data PVC it
# creates (<template>-<mdb>-<ordinal>). Same knob the hand-rolled restore uses.
MDBR_PVC_TEMPLATE="${MARIADB_PVC_TEMPLATE:-storage}"
# mysqld's uid, to hand the restored datadir back to.
MDBR_RUN_AS_USER="${MARIADB_RUN_AS_USER:-999}"
MDBR_S5CMD_IMAGE="${S5CMD_IMAGE:-peakcom/s5cmd:v2.3.0}"
# Needs bunzip2/gunzip; the MariaDB image ships neither. Busybox covers both.
MDBR_DECOMPRESS_IMAGE="${REPL_DECOMPRESS_IMAGE_DEFAULT:-alpine:3.20}"
# How long to wait for the pods to actually go away before overwriting.
MDBR_QUIESCE_TIMEOUT="${REPL_QUIESCE_TIMEOUT_DEFAULT:-300}"

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

# --- quiesce / resume --------------------------------------------------------

# _mdbr_quiesce <op> <data_fn> <replicas_out_var>
# Stop the database so its datadir can be rewritten. The operator reconciles the
# StatefulSet's replica count back, so reconciliation is suspended first.
_mdbr_quiesce() {
  local op="$1" data_fn="$2" out_var="$3" replicas elapsed=0 running

  replicas="$(_kubectl get statefulset "$MDB" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  if [[ -z "$replicas" || "$replicas" == "0" ]]; then
    mdbt_fail "$op" "standby is not running" "$("$data_fn" quiesce false)" 1 DATABASE_NOT_READY
  fi
  printf -v "$out_var" '%s' "$replicas"

  if ! _kubectl patch "$MARIADB_RESOURCE" "$MDB" --type merge \
    -p '{"spec":{"suspend":true}}' >/dev/null 2>&1; then
    mdbt_fail "$op" "standby could not be quiesced" \
      "$("$data_fn" quiesce false)" 1 INTERNAL_ERROR
  fi
  if ! _kubectl scale statefulset "$MDB" --replicas=0 >/dev/null 2>&1; then
    _mdbr_resume "$replicas"
    mdbt_fail "$op" "standby could not be quiesced" \
      "$("$data_fn" quiesce false)" 1 INTERNAL_ERROR
  fi

  # Overwriting a datadir while mysqld still holds it would corrupt it, so wait
  # for the pods to be gone rather than assuming the scale took effect.
  while (( elapsed < MDBR_QUIESCE_TIMEOUT )); do
    running="$(_kubectl get pods -l "app.kubernetes.io/instance=${MDB}" \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$running" == "0" ]] && return 0
    sleep 5
    elapsed=$(( elapsed + 5 ))
  done

  _mdbr_resume "$replicas"
  mdbt_fail "$op" "standby did not stop in time" \
    "$("$data_fn" quiesce false)" 1 RESTORE_TIMEOUT
}

# _mdbr_resume <replicas>
# Best-effort restore of the running state. Called on every failure path after
# quiesce, so a half-finished rebuild never leaves the database stopped.
_mdbr_resume() {
  local replicas="$1"
  _kubectl scale statefulset "$MDB" --replicas="$replicas" >/dev/null 2>&1 || true
  _kubectl patch "$MARIADB_RESOURCE" "$MDB" --type merge \
    -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
}

# --- the in-place restore job ------------------------------------------------

# _mdbr_restore_job_manifest <job> <pvc> <image>
# Download the backup, decompress it if needed, then wipe and repopulate the
# datadir. Built as JSON so no value is interpolated into YAML.
_mdbr_restore_job_manifest() {
  local job="$1" pvc="$2" image="$3"
  jq -n \
    --arg job "$job" --arg ns "$NAMESPACE" --arg pvc "$pvc" --arg image "$image" \
    --arg s5cmd "$MDBR_S5CMD_IMAGE" --arg decompress "$MDBR_DECOMPRESS_IMAGE" \
    --arg endpoint "$BACKUP_ENDPOINT" --arg bucket "$BACKUP_BUCKET" --arg prefix "$BACKUP_PREFIX" \
    --arg accessSecret "$BACKUP_ACCESS_SECRET" --arg accessKey "$BACKUP_ACCESS_KEY" \
    --arg secretSecret "$BACKUP_SECRET_ACCESS_SECRET" --arg secretKey "$BACKUP_SECRET_KEY" \
    --argjson uid "$MDBR_RUN_AS_USER" \
    '{
      apiVersion: "batch/v1", kind: "Job",
      metadata: {name: $job, namespace: $ns,
        labels: {"app.kubernetes.io/managed-by": "aqsh-mariadb-replication"}},
      spec: {
        backoffLimit: 0,
        template: {spec: {
          restartPolicy: "Never",
          automountServiceAccountToken: false,
          securityContext: {runAsUser: 0},
          volumes: [
            {name: "datadir", persistentVolumeClaim: {claimName: $pvc}},
            {name: "work", emptyDir: {}}
          ],
          initContainers: [
            {
              name: "download", image: $s5cmd,
              command: ["/s5cmd"],
              # Restricted to physical-backup objects: the prefix is shared
              # with logical backups, and a *.sql.gz would decompress into
              # something mbstream cannot read.
              args: ["--endpoint-url", $endpoint, "cp",
                     ("s3://" + $bucket + "/" + $prefix + "/*.xb*"), "/work/"],
              env: [
                {name: "AWS_ACCESS_KEY_ID", valueFrom: {secretKeyRef: {name: $accessSecret, key: $accessKey}}},
                {name: "AWS_SECRET_ACCESS_KEY", valueFrom: {secretKeyRef: {name: $secretSecret, key: $secretKey}}}
              ],
              volumeMounts: [{name: "work", mountPath: "/work"}]
            },
            {
              name: "decompress", image: $decompress,
              command: ["sh", "-c"],
              # Newest by NAME, not mtime: every object was written by the
              # download step moments ago, so mtime ordering is meaningless.
              # The operator names them physicalbackup-<timestamp>.xb[.ext], so
              # lexical order is chronological order.
              args: ["set -eu; f=$(ls -1 /work/ | grep -E \"[.]xb([.].*)?$\" | sort | tail -1); [ -n \"$f\" ] || { echo \"no physical backup object found under the prefix\" >&2; exit 1; }; echo \"selected: $f\"; case \"$f\" in *.bz2) bunzip2 -c \"/work/$f\" > /work/backup.xb ;; *.gz) gunzip -c \"/work/$f\" > /work/backup.xb ;; *.xb) [ \"$f\" = backup.xb ] || mv \"/work/$f\" /work/backup.xb ;; *) echo \"unsupported backup object: $f\" >&2; exit 1 ;; esac; ls -l /work/backup.xb"],
              volumeMounts: [{name: "work", mountPath: "/work"}]
            }
          ],
          containers: [{
            name: "restore", image: $image,
            command: ["bash", "-c"],
            # Wipe IN PLACE, then unpack: mbstream will not populate a non-empty
            # datadir, and leaving stale files behind would mix two databases.
            args: [("set -euo pipefail; find /datadir -mindepth 1 -delete; mbstream -x -C /datadir < /work/backup.xb; mariadb-backup --prepare --target-dir=/datadir; chown -R " + ($uid|tostring) + ":" + ($uid|tostring) + " /datadir")],
            volumeMounts: [
              {name: "datadir", mountPath: "/datadir"},
              {name: "work", mountPath: "/work"}
            ]
          }]
        }}
      }
    }'
}

# --- orchestration -----------------------------------------------------------

# mdbr_rebuild_standby <op> <data_fn>
# Reads from the caller's scope: NAMESPACE, MDB, MARIADB_RESOURCE, CR_JSON,
# PRIMARY_POD, ROOT_PASSWORD, PEER_AQSH_URL, PEER_TOKEN, WAIT_TIMEOUT, and the
# BACKUP_* set left by mdbt_resolve_backup_location. <data_fn> is a
# caller-supplied function taking <stage> <changed> that builds the public
# result payload, so the calling task keeps one consistent result shape.
#
# Returns 0 once the standby is back up on the restored data. Every failure path
# calls mdbt_fail (which exits) after resuming the instance.
mdbr_rebuild_standby() {
  local op="$1" data_fn="$2"
  local image replicas="" recheck job pvc rc=0 job_err
  local -a pvcs=() jobs=()

  image="$(jq -r '.spec.image // empty' <<<"$CR_JSON")"
  if [[ -z "$image" ]]; then
    mdbt_fail "$op" "database image could not be resolved" \
      "$("$data_fn" capture false)" 1 INTERNAL_ERROR
  fi

  # Volumes are discovered BEFORE anything stops: a listing failure here is
  # harmless, while the same failure after quiesce would leave the database down
  # with nothing done.
  mapfile -t pvcs < <(_mdbr_data_pvcs) || rc=$?
  _mdbr_data_pvcs >/dev/null || rc=1
  if (( rc != 0 )); then
    mdbt_fail "$op" "standby data volumes could not be listed" \
      "$("$data_fn" capture false)" 1 INTERNAL_ERROR
  fi
  if (( ${#pvcs[@]} == 0 )); then
    mdbt_fail "$op" "standby has no data volumes to restore" \
      "$("$data_fn" capture false)" 1 INTERNAL_ERROR
  fi

  # --- step 1: fresh backup on the primary ------------------------------------
  # Only the primary's own cluster can back its database up. Nothing has been
  # touched yet, so a failure here is completely safe.
  if ! mdbt_peer_call_task "$PEER_AQSH_URL" "$PEER_TOKEN" "physical-backup" \
    "$(jq -nc --arg ns "$NAMESPACE" --arg t "$WAIT_TIMEOUT" \
      '{namespace: $ns, dry_run: "false", confirm: "true", wait_timeout: ($t + "s")}')" \
    "$MDBR_PEER_TASK_TIMEOUT" >/dev/null; then
    mdbt_fail "$op" "a fresh backup could not be produced on the primary" \
      "$("$data_fn" backup false)" 1 PEER_OPERATION_FAILED
  fi

  # --- step 2: last look before the data is overwritten -----------------------
  # The caller's connection guard ran before the backup, which takes minutes —
  # long enough for a client to connect. This is the last moment it matters.
  if ! recheck="$(mdbr_external_connections "$PRIMARY_POD" "$ROOT_PASSWORD")"; then
    mdbt_fail "$op" "connection usage could not be re-read before restoring" \
      "$("$data_fn" quiesce false)" 1 DATABASE_NOT_READY
  fi
  if (( "$(jq -r '.total' <<<"$recheck")" > MDBR_MAX_EXTERNAL_CONNECTIONS )); then
    mdbt_fail "$op" "standby acquired external connections while the backup was running" \
      "$("$data_fn" quiesce false)" 1 STANDBY_IN_USE
  fi

  _mdbr_quiesce "$op" "$data_fn" replicas

  # --- step 3: overwrite each datadir in place --------------------------------
  # One Job per volume: a PVC is ReadWriteOnce, so they cannot share a pod. They
  # run concurrently because the pods are already gone.
  for pvc in "${pvcs[@]}"; do
    job="restore-${pvc}"
    _kubectl delete job "$job" --ignore-not-found >/dev/null 2>&1 || true
    if ! _mdbr_restore_job_manifest "$job" "$pvc" "$image" | _kubectl apply -f - >/dev/null 2>&1; then
      _mdbr_resume "$replicas"
      mdbt_fail "$op" "standby restore could not be started" \
        "$("$data_fn" restore true)" 1 RESTORE_FAILED
    fi
    jobs+=("$job")
  done

  for job in "${jobs[@]}"; do
    if ! _kubectl wait --for=condition=complete "job/${job}" \
      --timeout="${WAIT_TIMEOUT}s" >/dev/null 2>&1; then
      # The reason lives in the Job's own logs; the public result stays generic.
      job_err="$(_kubectl logs "job/${job}" --tail=20 2>&1 || true)"
      log_error "$op" "restore job ${job} did not complete: ${job_err}"
      _mdbr_resume "$replicas"
      mdbt_fail "$op" "standby restore did not complete" \
        "$("$data_fn" restore true)" 1 RESTORE_FAILED
    fi
  done

  # --- step 4: resume ---------------------------------------------------------
  _mdbr_resume "$replicas"
  if ! mdbt_wait_mariadb_ready "$MDB" "${WAIT_TIMEOUT}s" >/dev/null 2>&1; then
    mdbt_fail "$op" "standby did not become ready after restore" \
      "$("$data_fn" restore true)" 1 RESTORE_TIMEOUT
  fi

  for job in "${jobs[@]}"; do
    _kubectl delete job "$job" --ignore-not-found >/dev/null 2>&1 || true
  done

  return 0
}
