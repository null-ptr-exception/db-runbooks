#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/recovery/setup-data-recovery.sh
#
# One-time, operator-run bootstrap for the MongoDB recovery mechanism:
#   1. Apply the recovery ConfigMap (satisfies gate G2)
#   2. Patch the target StatefulSet to add the data-recovery init container,
#      locking the rolling-update partition to the current replica count
#      (satisfies gate G1; no pods restart until a wipe lowers the partition)
#
# This is NOT an aqsh task — it needs StatefulSet-patch RBAC broader than the
# aqsh service account is granted (see docs/mongodb/recovery.md "RBAC
# Requirements"). Run it once per StatefulSet, by a cluster operator, before
# any recovery/* task is called against that namespace.
#
# This is the single source of truth for the init-container/wipe-script
# shape — docs/mongodb/recovery.md and tests/mongodb/recovery.bats's
# setup_file both call this script instead of duplicating the heredoc.
#
# Usage:
#   setup-data-recovery.sh --context CTX --namespace NS --sts NAME \
#     --profile bitnami|standard [--configmap NAME]
#
# Profile differences:
#   bitnami  — volume "datadir" mounted at /bitnami/mongodb, runAsUser 1001
#   standard — volume "data"    mounted at /data/db,         runAsUser 999
# =============================================================================

CONTEXT=""
NAMESPACE=""
STS=""
PROFILE=""
CONFIGMAP="mongodb-recovery-config"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="${2:?--context requires a value}"; shift 2 ;;
    --namespace) NAMESPACE="${2:?--namespace requires a value}"; shift 2 ;;
    --sts) STS="${2:?--sts requires a value}"; shift 2 ;;
    --profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
    --configmap) CONFIGMAP="${2:?--configmap requires a value}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$CONTEXT" || -z "$NAMESPACE" || -z "$STS" || -z "$PROFILE" ]] && {
  echo "Usage: $0 --context CTX --namespace NS --sts NAME --profile bitnami|standard [--configmap NAME]" >&2
  exit 1
}

case "$PROFILE" in
  bitnami)
    VOLUME_NAME="datadir"
    MOUNT_PATH="/bitnami/mongodb"
    WIPE_PATH="/bitnami/mongodb/data/db"
    RUN_AS_USER="1001"
    ;;
  standard)
    VOLUME_NAME="data"
    MOUNT_PATH="/data/db"
    WIPE_PATH="/data/db"
    RUN_AS_USER="999"
    ;;
  *)
    echo "Unknown --profile '${PROFILE}': must be 'bitnami' or 'standard'" >&2
    exit 1
    ;;
esac

STS_INFO=$(kubectl --context "$CONTEXT" -n "$NAMESPACE" get statefulset "$STS" \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\t"}{.spec.replicas}')
IMAGE="${STS_INFO%%$'\t'*}"
REPLICAS="${STS_INFO#*$'\t'}"
[[ -n "$IMAGE" ]] || { echo "Could not read image from statefulset/${STS}" >&2; exit 1; }
[[ -n "$REPLICAS" && "$REPLICAS" =~ ^[0-9]+$ && "$REPLICAS" -gt 0 ]] || {
  echo "Could not read a positive replica count from statefulset/${STS} (got '${REPLICAS}') — refusing to set partition, which would not lock the StatefulSet" >&2
  exit 1
}

echo "Applying recovery ConfigMap '${CONFIGMAP}' in namespace '${NAMESPACE}'..."
kubectl --context "$CONTEXT" -n "$NAMESPACE" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CONFIGMAP}
data:
  wipe-targets: ""
  recovery-version: "0"
EOF

echo "Patching statefulset/${STS} (profile=${PROFILE}, image=${IMAGE}, partition=${REPLICAS})..."
kubectl --context "$CONTEXT" -n "$NAMESPACE" patch statefulset "$STS" --type=strategic -p "$(cat <<EOF
{
  "spec": {
    "updateStrategy": {"rollingUpdate": {"partition": ${REPLICAS}}},
    "template": {
      "spec": {
        "initContainers": [{
          "name": "data-recovery",
          "image": "${IMAGE}",
          "command": ["/bin/bash", "-c"],
          "args": ["WIPE_TARGETS=\$(cat /recovery-config/wipe-targets 2>/dev/null || echo ''); MY_NAME=\$(hostname); if [ -n \"\$WIPE_TARGETS\" ] && echo \"\$WIPE_TARGETS\" | grep -qw \"\$MY_NAME\"; then echo \"[RECOVERY] Wiping data for \$MY_NAME\"; find ${WIPE_PATH} -mindepth 1 -delete 2>/dev/null || true; echo '[RECOVERY] Wipe complete.'; else echo \"[RECOVERY] \$MY_NAME not in wipe targets, skip.\"; fi"],
          "volumeMounts": [
            {"name": "${VOLUME_NAME}", "mountPath": "${MOUNT_PATH}"},
            {"name": "recovery-config-vol", "mountPath": "/recovery-config", "readOnly": true}
          ],
          "securityContext": {"runAsUser": ${RUN_AS_USER}, "runAsNonRoot": true}
        }],
        "volumes": [{"name": "recovery-config-vol", "configMap": {"name": "${CONFIGMAP}"}}]
      }
    }
  }
}
EOF
)"

echo "Done. Partition is locked at ${REPLICAS} — no pods restart until a wipe lowers it."
echo "This script does not read /etc/aqsh/config/mongodb.env. recovery/* tasks auto-detect data_path/mount_path live from mongod's real dbPath, so no action is normally needed — only set RECOVERY_DATA_PATH_DEFAULT=${WIPE_PATH} / RECOVERY_MOUNT_PATH_DEFAULT=${MOUNT_PATH} there if detection can't resolve this deployment's convention (data_path/mount_path are not task inputs; see CLAUDE.md \"Configuration Layers\")."
