#!/usr/bin/env bash
# =============================================================================
# lib/mariadb-physical-restore.sh
# Hand-rolled physical (mariabackup) restore for clusters whose operator has no
# physical bootstrapFrom (the legacy mmontes-era generation, whose bootstrapFrom
# backupRef/s3/volume are all LOGICAL-only). Reached from restore.sh only when
# `mdb_has_crd physicalbackups` is false; the current-generation path keeps
# driving bootstrapFrom.s3 Physical.
#
# AWS-style, like the operator path: always a NEW instance, never in place.
# Mechanism (Option A — PVC pre-adoption):
#   1. Pre-create the PVC the operator StatefulSet will use for the new instance
#      (<template>-<target>-0). If the name is wrong the StatefulSet makes its own
#      empty PVC instead — the verify step (below) catches that and FAILS.
#   2. A Job populates that PVC: an mc init container downloads the .xb from S3,
#      then a mariadb container runs `mbstream -x` + `mariabackup --prepare` and
#      chowns the datadir to the mysqld uid.
#   3. Create the MariaDB CR with NO bootstrapFrom → the operator's StatefulSet
#      adopts the pre-populated PVC → mysqld starts on the restored datadir.
#   4. FAIL-CLOSED verify: the pod must actually be bound to OUR PVC (not an
#      operator-created empty one), and user tables must exist. Anything short of
#      that is reported as a failure — never a false success.
#
# SAFETY NOTE: this restores into a fresh instance and never touches the source.
# But the whole flow is UNVALIDATED without a live legacy operator (PVC adoption,
# prepare/version compat, ownership). Treat as "implemented, pending live
# validation"; the verify step is what keeps a broken restore from reporting
# success. See docs — kept internal.
# =============================================================================

[[ -n "${_MARIADB_PHYSICAL_RESTORE_LOADED:-}" ]] && return 0
_MARIADB_PHYSICAL_RESTORE_LOADED=1

# Deploy-tunable knobs (internal config, not task inputs).
MARIADB_PVC_TEMPLATE="${MARIADB_PVC_TEMPLATE:-storage}"   # operator volumeClaimTemplate name
MARIADB_RUN_AS_USER="${MARIADB_RUN_AS_USER:-999}"          # mysqld uid to chown the datadir to
MC_IMAGE="${MC_IMAGE:-minio/mc:latest}"                    # image providing `mc` for the download initContainer

# mdbt_pr_pvc_name <target>
# The PVC name the operator StatefulSet will use for ordinal 0.
mdbt_pr_pvc_name() {
  printf '%s-%s-0' "$MARIADB_PVC_TEMPLATE" "${1:?target required}"
}

# mdbt_pr_source_object <bucket> <prefix> [name]
# Echo the object key (relative to the bucket) of the .xb to restore: the named
# one, else the lexically-latest .xb under the prefix. Empty when none is found.
mdbt_pr_source_object() {
  local bucket="$1" prefix="$2" name="${3:-}"
  if [[ -n "$name" ]]; then
    [[ "$name" == *.xb ]] || name="${name}.xb"
    printf '%s/%s' "$prefix" "$name"
    return 0
  fi
  local latest
  # `|| true`: an empty prefix makes grep exit non-zero, which under the caller's
  # set -e/pipefail would abort instead of yielding "no backup found".
  latest="$(mc ls "minio/${bucket}/${prefix}/" 2>/dev/null | awk '{print $NF}' | grep '\.xb$' | sort | tail -1 || true)"
  [[ -n "$latest" ]] && printf '%s/%s' "$prefix" "$latest"
  return 0
}

# mdbt_pr_pvc_manifest <name> <namespace> <size>
mdbt_pr_pvc_manifest() {
  jq -n --arg name "$1" --arg namespace "$2" --arg size "$3" \
    '{apiVersion: "v1", kind: "PersistentVolumeClaim",
      metadata: {name: $name, namespace: $namespace},
      spec: {accessModes: ["ReadWriteOnce"], resources: {requests: {storage: $size}}}}'
}

# mdbt_pr_job_manifest <jobname> <namespace> <pvc> <bucket> <object> <endpoint> <accessSecret> <accessKey> <secretKey>
# A Job that downloads the .xb (mc init container) then extracts + prepares it
# into the datadir PVC (mariadb container), leaving a restored, chowned datadir.
mdbt_pr_job_manifest() {
  local jobname="$1" namespace="$2" pvc="$3" bucket="$4" object="$5" endpoint="$6"
  local accessSecret="$7" accessKey="$8" secretKey="$9" image="${10}"
  jq -n \
    --arg jobname "$jobname" --arg namespace "$namespace" --arg pvc "$pvc" \
    --arg bucket "$bucket" --arg object "$object" --arg endpoint "$endpoint" \
    --arg accessSecret "$accessSecret" --arg accessKey "$accessKey" --arg secretKey "$secretKey" \
    --arg image "$image" --arg mcImage "$MC_IMAGE" --argjson uid "$MARIADB_RUN_AS_USER" \
    '{
      apiVersion: "batch/v1", kind: "Job",
      metadata: {name: $jobname, namespace: $namespace},
      spec: {
        backoffLimit: 1,
        template: {spec: {
          restartPolicy: "Never",
          securityContext: {runAsUser: $uid, fsGroup: $uid},
          volumes: [
            {name: "datadir", persistentVolumeClaim: {claimName: $pvc}},
            {name: "work", emptyDir: {}}
          ],
          initContainers: [{
            name: "download", image: $mcImage,
            command: ["sh","-c","mc alias set s3 \"$MC_ENDPOINT\" \"$MC_ACCESS\" \"$MC_SECRET\" --api S3v4 && mc cp \"s3/\"$MC_OBJECT /work/backup.xb"],
            env: [
              {name: "MC_ENDPOINT", value: $endpoint},
              {name: "MC_OBJECT", value: ($bucket + "/" + $object)},
              {name: "MC_ACCESS", valueFrom: {secretKeyRef: {name: $accessSecret, key: $accessKey}}},
              {name: "MC_SECRET", valueFrom: {secretKeyRef: {name: $accessSecret, key: $secretKey}}}
            ],
            volumeMounts: [{name: "work", mountPath: "/work"}]
          }],
          containers: [{
            name: "prepare", image: $image,
            command: ["sh","-c","set -e; mbstream -x -C /datadir < /work/backup.xb; mariabackup --prepare --target-dir=/datadir; chown -R $(id -u):$(id -g) /datadir"],
            volumeMounts: [
              {name: "datadir", mountPath: "/datadir"},
              {name: "work", mountPath: "/work"}
            ]
          }]
        }}
      }
    }'
}

# mdbt_pr_mariadb_manifest <target> <namespace> <image> <size> <secret> <key> <apiVersion>
# The restored MariaDB — NO bootstrapFrom; it stands up on the adopted PVC.
mdbt_pr_mariadb_manifest() {
  jq -n \
    --arg target "$1" --arg namespace "$2" --arg image "$3" --arg size "$4" \
    --arg secret "$5" --arg key "$6" --arg apiVersion "$7" \
    '{apiVersion: $apiVersion, kind: "MariaDB",
      metadata: {name: $target, namespace: $namespace},
      spec: {image: $image, replicas: 1,
        rootPasswordSecretKeyRef: {name: $secret, key: $key},
        storage: {size: $size}}}'
}

# mdbt_pr_verify <target> <namespace> <pvc> <root_secret> <root_key>
# FAIL-CLOSED post-restore check. Returns 0 only when BOTH hold:
#   (a) pod <target>-0 is actually bound to OUR pvc (adoption worked, not a fresh
#       empty PVC the StatefulSet made because our name was wrong), and
#   (b) at least one non-system table exists (the datadir carries real data).
# Any query failure or a zero user-table count returns non-zero → caller reports
# a failure, never a success.
mdbt_pr_verify() {
  local target="$1" namespace="$2" pvc="$3" root_secret="$4" root_key="$5"
  local pod="${target}-0"

  local bound
  bound="$(_kubectl get pod "$pod" -o jsonpath='{.spec.volumes[?(@.name=="'"$MARIADB_PVC_TEMPLATE"'")].persistentVolumeClaim.claimName}' 2>/dev/null)"
  # StatefulSet mounts the datadir volume under the volumeClaimTemplate name;
  # fall back to scanning all volumes if the operator names it differently.
  if [[ "$bound" != "$pvc" ]]; then
    bound="$(_kubectl get pod "$pod" -o jsonpath='{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\n"}{end}' 2>/dev/null | grep -Fx "$pvc" || true)"
    [[ "$bound" == "$pvc" ]] || return 2   # our PVC was NOT adopted
  fi

  local pw count
  pw="$(_kubectl get secret "$root_secret" -o "jsonpath={.data.${root_key}}" 2>/dev/null | base64 -d 2>/dev/null || true)"
  [[ -n "$pw" ]] || return 3
  count="$(_kubectl exec "$pod" -- env MYSQL_PWD="$pw" mariadb -N -u root -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys');" \
    2>/dev/null | tr -dc '0-9')"
  [[ -n "$count" && "$count" -gt 0 ]] || return 4   # no user tables → empty/failed restore
  return 0
}

# mdbt_pr_plan <bucket> <object> <pvc> <target> — dry-run plan payload.
mdbt_pr_plan() {
  jq -n --arg bucket "$1" --arg object "$2" --arg pvc "$3" --arg target "$4" \
    '{mode: "hand-rolled",
      source: ("s3://" + $bucket + "/" + $object),
      pvc: $pvc, target: $target,
      steps: [
        "pre-create PVC",
        "Job: mc download + mbstream -x + mariabackup --prepare + chown",
        "create MariaDB (adopts the PVC; no bootstrapFrom)",
        "fail-closed verify: PVC adoption + user tables exist"
      ]}'
}

# mdbt_pr_orchestrate <target> <namespace> <image> <size> <root_secret> <root_key>
#   <bucket> <object> <endpoint> <accessSecret> <accessKey> <secretKey> <apiVersion> <wait_timeout>
# Full hand-rolled restore. Explicit return codes (called from an `if`, so the
# caller's set -e/ERR trap does not fire on an internal failure):
#   0 ok · 10 PVC apply · 11 Job apply/complete · 12 MariaDB apply
#   13 not Ready · 14 verify failed (adoption or empty data)
mdbt_pr_orchestrate() {
  local target="$1" namespace="$2" image="$3" size="$4" root_secret="$5" root_key="$6"
  local bucket="$7" object="$8" endpoint="$9" accessSecret="${10}" accessKey="${11}" secretKey="${12}"
  local apiVersion="${13}" wait_timeout="${14}"
  local pvc jobname
  pvc="$(mdbt_pr_pvc_name "$target")"
  jobname="${target}-prepare"

  mdbt_pr_pvc_manifest "$pvc" "$namespace" "$size" | _kubectl apply -f - >/dev/null 2>&1 || return 10
  mdbt_pr_job_manifest "$jobname" "$namespace" "$pvc" "$bucket" "$object" "$endpoint" \
    "$accessSecret" "$accessKey" "$secretKey" "$image" | _kubectl apply -f - >/dev/null 2>&1 || return 11
  _kubectl wait --for=condition=complete "job/${jobname}" --timeout="$wait_timeout" >/dev/null 2>&1 || return 11
  mdbt_pr_mariadb_manifest "$target" "$namespace" "$image" "$size" "$root_secret" "$root_key" "$apiVersion" \
    | _kubectl apply -f - >/dev/null 2>&1 || return 12
  mdbt_wait_mariadb_ready "$target" "$wait_timeout" >/dev/null 2>&1 || return 13
  mdbt_pr_verify "$target" "$namespace" "$pvc" "$root_secret" "$root_key" || return 14
  return 0
}
