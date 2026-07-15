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
#   2. A Job populates that PVC: an s5cmd init container downloads the .xb from S3,
#      then a mariadb container runs `mbstream -x` + `mariabackup --prepare` and
#      chowns the datadir to the mysqld uid.
#   3. Create the MariaDB CR with NO bootstrapFrom → the operator's StatefulSet
#      adopts the pre-populated PVC → mysqld starts on the restored datadir.
#   4. FAIL-CLOSED verify: the pod must actually be bound to OUR PVC (not an
#      operator-created empty one), and user tables must exist. Anything short of
#      that is reported as a failure — never a false success.
#
# SAFETY NOTE: this restores into a fresh instance and never touches the source.
# The dedicated legacy-operator e2e validates PVC adoption, prepare/version
# compatibility, ownership, Ready reconciliation, and the restored row set.
# =============================================================================

[[ -n "${_MARIADB_PHYSICAL_RESTORE_LOADED:-}" ]] && return 0
_MARIADB_PHYSICAL_RESTORE_LOADED=1

# Deploy-tunable knobs (internal config, not task inputs).
MARIADB_PVC_TEMPLATE="${MARIADB_PVC_TEMPLATE:-storage}"   # operator volumeClaimTemplate name
MARIADB_RUN_AS_USER="${MARIADB_RUN_AS_USER:-999}"          # mysqld uid to chown the datadir to
S5CMD_IMAGE="${S5CMD_IMAGE:-peakcom/s5cmd:v2.3.0}"

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
  local latest listing rc=0
  listing="$(s5 --json ls "s3://${bucket}/${prefix}/" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    grep -qi 'no object found' <<<"$listing" && return 0
    return 2
  fi
  latest="$(jq -r 'select(.type == "file" and (.key | endswith(".xb"))) | .key' <<<"$listing" \
    | sort | tail -1 || true)"
  [[ -n "$latest" ]] && printf '%s' "${latest#s3://${bucket}/}"
  return 0
}

# mdbt_pr_s3_secret_manifest creates short-lived AWS-compatible credentials for
# the s5cmd init container. The endpoint is non-secret and stays in the Job.
mdbt_pr_s3_secret_manifest() {
  local name="$1" namespace="$2" access="$3" secret="$4"
  jq -n --arg name "$name" --arg namespace "$namespace" \
    --arg access "$access" --arg secret "$secret" \
    '{apiVersion:"v1",kind:"Secret",metadata:{name:$name,namespace:$namespace,
      labels:{"app.kubernetes.io/managed-by":"aqsh-mariadb-restore"}},
      type:"Opaque",stringData:{AWS_ACCESS_KEY_ID:$access,AWS_SECRET_ACCESS_KEY:$secret}}'
}

# mdbt_pr_pvc_manifest <name> <namespace> <size>
mdbt_pr_pvc_manifest() {
  jq -n --arg name "$1" --arg namespace "$2" --arg size "$3" \
    '{apiVersion: "v1", kind: "PersistentVolumeClaim",
      metadata: {name: $name, namespace: $namespace,
        labels: {"app.kubernetes.io/managed-by": "aqsh-mariadb-restore"}},
      spec: {accessModes: ["ReadWriteOnce"], resources: {requests: {storage: $size}}}}'
}

# mdbt_pr_job_manifest <jobname> <namespace> <pvc> <bucket> <object> <endpoint> <image>
# A Job that downloads the .xb (s5cmd init container) then extracts + prepares it
# into the datadir PVC (mariadb container), leaving a restored, chowned datadir.
mdbt_pr_job_manifest() {
  local jobname="$1" namespace="$2" pvc="$3" bucket="$4" object="$5" endpoint="$6"
  local image="$7"
  jq -n \
    --arg jobname "$jobname" --arg namespace "$namespace" --arg pvc "$pvc" \
    --arg bucket "$bucket" --arg object "$object" --arg endpoint "$endpoint" \
    --arg image "$image" --arg s5cmdImage "$S5CMD_IMAGE" --argjson uid "$MARIADB_RUN_AS_USER" \
    '{
      apiVersion: "batch/v1", kind: "Job",
      metadata: {name: $jobname, namespace: $namespace,
        labels: {"app.kubernetes.io/managed-by": "aqsh-mariadb-restore"}},
      spec: {
        backoffLimit: 0,
        template: {spec: {
          restartPolicy: "Never",
          automountServiceAccountToken: false,
          securityContext: {runAsUser: $uid, fsGroup: $uid},
          volumes: [
            {name: "datadir", persistentVolumeClaim: {claimName: $pvc}},
            {name: "work", emptyDir: {}}
          ],
          initContainers: [{
            name: "download", image: $s5cmdImage,
            command: ["/s5cmd"],
            args: ["--endpoint-url", $endpoint, "cp", ("s3://" + $bucket + "/" + $object), "/work/backup.xb"],
            env: [
              {name: "AWS_ACCESS_KEY_ID", valueFrom: {secretKeyRef: {name: ($jobname + "-s3"), key: "AWS_ACCESS_KEY_ID"}}},
              {name: "AWS_SECRET_ACCESS_KEY", valueFrom: {secretKeyRef: {name: ($jobname + "-s3"), key: "AWS_SECRET_ACCESS_KEY"}}}
            ],
            volumeMounts: [{name: "work", mountPath: "/work"}]
          }],
          containers: [{
            name: "prepare", image: $image,
            securityContext: {runAsUser: 0, allowPrivilegeEscalation: false},
            command: ["sh","-c", ("set -e; mbstream -x -C /datadir < /work/backup.xb; mariabackup --prepare --target-dir=/datadir; chown -R " + ($uid|tostring) + ":" + ($uid|tostring) + " /datadir")],
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
# The restored legacy MariaDB — NO bootstrapFrom; it stands up on the adopted
# PVC.  The mmontes-era CRD requires volumeClaimTemplate (the current generation
# renamed this surface to storage), so this manifest intentionally uses the
# legacy schema.
mdbt_pr_mariadb_manifest() {
  jq -n \
    --arg target "$1" --arg namespace "$2" --arg image "$3" --arg size "$4" \
    --arg secret "$5" --arg key "$6" --arg apiVersion "$7" \
    '{apiVersion: $apiVersion, kind: "MariaDB",
      metadata: {name: $target, namespace: $namespace,
        labels: {"app.kubernetes.io/managed-by": "aqsh-mariadb-restore"}},
      spec: {image: $image, replicas: 1,
        rootPasswordSecretKeyRef: {name: $secret, key: $key},
        volumeClaimTemplate: {
          accessModes: ["ReadWriteOnce"],
          resources: {requests: {storage: $size}}
        }}}'
}

# mdbt_pr_verify <target> <namespace> <pvc> <root_secret> <root_key>
# FAIL-CLOSED post-restore check. Returns 0 only when BOTH hold:
#   (a) pod <target>-0 is actually bound to OUR pvc (adoption worked, not a fresh
#       empty PVC the StatefulSet made because our name was wrong), and
#   (b) at least one non-system table exists (the datadir carries real data).
# Any query failure or a zero user-table count returns non-zero → caller reports
# a failure, never a success.
mdbt_pr_verify() {
  local target="$1" namespace="$2" pvc="$3"
  local pod="${target}-0"

  local bound
  bound="$(_kubectl get pod "$pod" -o jsonpath='{.spec.volumes[?(@.name=="'"$MARIADB_PVC_TEMPLATE"'")].persistentVolumeClaim.claimName}' 2>/dev/null)"
  # StatefulSet mounts the datadir volume under the volumeClaimTemplate name;
  # fall back to scanning all volumes if the operator names it differently.
  if [[ "$bound" != "$pvc" ]]; then
    bound="$(_kubectl get pod "$pod" -o jsonpath='{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\n"}{end}' 2>/dev/null | grep -Fx "$pvc" || true)"
    [[ "$bound" == "$pvc" ]] || return 2   # our PVC was NOT adopted
  fi

  local count
  count="$(_kubectl exec -c "${MARIADB_CONTAINER:-mariadb}" "$pod" -- sh -c \
    'test -n "$MARIADB_ROOT_PASSWORD" && MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -N -u root -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('"'"'mysql'"'"','"'"'information_schema'"'"','"'"'performance_schema'"'"','"'"'sys'"'"');"' \
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
        "Job: s5cmd download + mbstream -x + mariabackup --prepare + chown",
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

  # Refuse collisions: a retry must never unpack over an existing datadir or
  # reuse an immutable/partially failed Job.
  _kubectl get pvc "$pvc" >/dev/null 2>&1 && return 10
  _kubectl get job "$jobname" >/dev/null 2>&1 && return 11
  _kubectl get mariadb "$target" >/dev/null 2>&1 && return 12

  local access secret
  access="$(_kubectl get secret "$accessSecret" -o "jsonpath={.data.${accessKey}}" 2>/dev/null | base64 -d 2>/dev/null)" || return 10
  secret="$(_kubectl get secret "$accessSecret" -o "jsonpath={.data.${secretKey}}" 2>/dev/null | base64 -d 2>/dev/null)" || return 10
  [[ -n "$access" && -n "$secret" ]] || return 10
  mdbt_pr_s3_secret_manifest "${jobname}-s3" "$namespace" "$access" "$secret" \
    | _kubectl create -f - >/dev/null 2>&1 || return 10
  if ! mdbt_pr_pvc_manifest "$pvc" "$namespace" "$size" | _kubectl create -f - >/dev/null 2>&1; then
    _kubectl delete secret "${jobname}-s3" --ignore-not-found >/dev/null 2>&1 || true
    return 10
  fi
  mdbt_pr_job_manifest "$jobname" "$namespace" "$pvc" "$bucket" "$object" "$endpoint" "$image" \
    | _kubectl create -f - >/dev/null 2>&1 || {
      _kubectl delete secret "${jobname}-s3" --ignore-not-found >/dev/null 2>&1 || true
      return 11
    }
  if ! _kubectl wait --for=condition=complete "job/${jobname}" --timeout="$wait_timeout" >/dev/null 2>&1; then
    _kubectl delete secret "${jobname}-s3" --ignore-not-found >/dev/null 2>&1 || true
    return 11
  fi
  _kubectl delete secret "${jobname}-s3" --ignore-not-found >/dev/null 2>&1 || return 11
  mdbt_pr_mariadb_manifest "$target" "$namespace" "$image" "$size" "$root_secret" "$root_key" "$apiVersion" \
    | _kubectl create -f - >/dev/null 2>&1 || return 12
  mdbt_wait_mariadb_ready "$target" "$wait_timeout" >/dev/null 2>&1 || return 13
  mdbt_pr_verify "$target" "$namespace" "$pvc" "$root_secret" "$root_key" || return 14
  return 0
}
