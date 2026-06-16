#!/usr/bin/env bats
# =============================================================================
# Post-deploy smoke tests for MongoDB recovery prerequisites.
#
# Verifies that scripts/deploy.sh correctly wired up G1 and G2 prerequisites
# for each MongoDB namespace (mongo-1, mongo-2, mongo-3):
#
#   G1: StatefulSet has the data-recovery init container
#   G2: mongodb-recovery-config ConfigMap exists
#
# Also checks that the init container spec matches the standard mongo:N image
# values (volume=data, mountPath=/data/db, runAsUser=999) — NOT the Bitnami
# values (datadir, /bitnami/mongodb, 1001).
#
# Run after scripts/deploy.sh:
#   bats tests/mongodb/verify-recovery-prereqs.bats
#
# Requires: kubectl with kind-cluster-dbs context available.
# No aqsh token needed — all checks are read-only kubectl calls.
# =============================================================================

setup_file() {
  load '../test_helper/common_setup'
  common_setup

  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"

  # recovery.bats teardown_file may delete mongo-1 before this suite runs.
  # Re-deploy any missing namespaces so prereq checks have something to inspect.
  for ns in mongo-1 mongo-2 mongo-3; do
    if ! kubectl --context "$ctx" get ns "$ns" &>/dev/null; then
      echo "Namespace ${ns} missing — re-deploying..."
      deploy_mongodb "$ns" "$ctx"
      kubectl --context "$ctx" -n "$ns" apply \
        -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/recovery-configmap.yaml"
      local replicas img
      replicas=$(kubectl --context "$ctx" -n "$ns" \
        get statefulset mongodb -o jsonpath='{.spec.replicas}')
      img=$(kubectl --context "$ctx" -n "$ns" \
        get statefulset mongodb -o jsonpath='{.spec.template.spec.containers[0].image}')
      kubectl --context "$ctx" -n "$ns" \
        patch statefulset mongodb --type=strategic -p "$(cat <<PATCH
{
  "spec": {
    "updateStrategy": {"rollingUpdate": {"partition": ${replicas}}},
    "template": {
      "spec": {
        "initContainers": [{
          "name": "data-recovery",
          "image": "${img}",
          "command": ["/bin/bash", "-c"],
          "args": ["WIPE_TARGETS=\$(cat /recovery-config/wipe-targets 2>/dev/null || echo ''); MY_NAME=\$(hostname); if [ -n \"\$WIPE_TARGETS\" ] && echo \"\$WIPE_TARGETS\" | grep -qw \"\$MY_NAME\"; then echo '[RECOVERY] Wiping data for '\$MY_NAME; find /data/db -mindepth 1 -delete 2>/dev/null || true; echo '[RECOVERY] Wipe complete.'; else echo '[RECOVERY] '\$MY_NAME' not in wipe targets, skip.'; fi"],
          "volumeMounts": [
            {"name": "data", "mountPath": "/data/db"},
            {"name": "recovery-config-vol", "mountPath": "/recovery-config", "readOnly": true}
          ],
          "securityContext": {"runAsUser": 999, "runAsNonRoot": true}
        }],
        "volumes": [{"name": "recovery-config-vol", "configMap": {"name": "mongodb-recovery-config"}}]
      }
    }
  }
}
PATCH
)"
    fi
  done
}

setup() {
  load '../test_helper/common_setup'
}

# ---------------------------------------------------------------------------
# _ic_field <namespace> <jsonpath>
# Read a field from the data-recovery init container spec.
# ---------------------------------------------------------------------------
_ic_field() {
  local ns="$1" jp="$2"
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
  kubectl --context "$ctx" -n "$ns" get statefulset mongodb \
    -o jsonpath="{.spec.template.spec.initContainers[?(@.name=='data-recovery')]${jp}}" \
    2>/dev/null
}

# ---------------------------------------------------------------------------
# _assert_prereqs <namespace>
# Shared assertion logic — called per-namespace.
# ---------------------------------------------------------------------------
_assert_prereqs() {
  local ns="$1"
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"

  # G1: init container name present
  local ic_names
  ic_names=$(kubectl --context "$ctx" -n "$ns" get statefulset mongodb \
    -o jsonpath='{.spec.template.spec.initContainers[*].name}' 2>/dev/null)
  echo "[$ns] initContainers: $ic_names" >&2
  [[ "$ic_names" == *"data-recovery"* ]]

  # G2: ConfigMap exists
  kubectl --context "$ctx" -n "$ns" get configmap mongodb-recovery-config \
    --ignore-not-found -o name | grep -q "configmap/mongodb-recovery-config"

  # Init container volume name must be 'data' (not Bitnami's 'datadir')
  local vol_name
  vol_name=$(_ic_field "$ns" '.volumeMounts[0].name')
  echo "[$ns] ic.volumeMounts[0].name: $vol_name" >&2
  [ "$vol_name" = "data" ]

  # Init container mount path must be /data/db (not /bitnami/mongodb)
  local mount_path
  mount_path=$(_ic_field "$ns" '.volumeMounts[0].mountPath')
  echo "[$ns] ic.volumeMounts[0].mountPath: $mount_path" >&2
  [ "$mount_path" = "/data/db" ]

  # Init container must run as user 999 (standard mongo:N, not 1001 Bitnami)
  local run_as_user
  run_as_user=$(_ic_field "$ns" '.securityContext.runAsUser')
  echo "[$ns] ic.securityContext.runAsUser: $run_as_user" >&2
  [ "$run_as_user" = "999" ]

  # Wipe path in args must reference /data/db, not /bitnami
  local args
  args=$(_ic_field "$ns" '.args[0]')
  echo "[$ns] ic.args contains /data/db: $(echo "$args" | grep -c '/data/db')" >&2
  echo "$args" | grep -q '/data/db'
  echo "$args" | grep -qv '/bitnami'

  # Partition must be locked (>= replica count so no pod auto-restarts)
  local partition replicas
  partition=$(kubectl --context "$ctx" -n "$ns" get statefulset mongodb \
    -o jsonpath='{.spec.updateStrategy.rollingUpdate.partition}' 2>/dev/null)
  replicas=$(kubectl --context "$ctx" -n "$ns" get statefulset mongodb \
    -o jsonpath='{.spec.replicas}' 2>/dev/null)
  echo "[$ns] partition=$partition replicas=$replicas" >&2
  [ -n "$partition" ]
  [ "$partition" -ge "$replicas" ]
}

# ── Per-namespace checks ──────────────────────────────────────────────────────

@test "mongo-1: G1 init container and G2 ConfigMap present with correct non-Bitnami spec" {
  _assert_prereqs "mongo-1"
}

@test "mongo-2: G1 init container and G2 ConfigMap present with correct non-Bitnami spec" {
  _assert_prereqs "mongo-2"
}

@test "mongo-3: G1 init container and G2 ConfigMap present with correct non-Bitnami spec" {
  _assert_prereqs "mongo-3"
}

# ── ConfigMap content ─────────────────────────────────────────────────────────

@test "mongo-1: recovery ConfigMap has empty wipe-targets on fresh deploy" {
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
  local wipe
  wipe=$(kubectl --context "$ctx" -n mongo-1 get configmap mongodb-recovery-config \
    -o jsonpath='{.data.wipe-targets}' 2>/dev/null)
  [ -z "$wipe" ]
}

# ── Idempotency: re-applying deploy does not break the setup ─────────────────

@test "mongo-1: recovery ConfigMap apply is idempotent (re-apply does not error)" {
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
  local root_dir
  root_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  kubectl --context "$ctx" -n mongo-1 apply \
    -f "${root_dir}/k8s/cluster-dbs/mongodb/recovery-configmap.yaml"
}

@test "mongo-1: STS strategic patch is idempotent (re-applying init container does not duplicate)" {
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
  local ic_count
  ic_count=$(kubectl --context "$ctx" -n mongo-1 get statefulset mongodb \
    -o jsonpath='{.spec.template.spec.initContainers[*].name}' 2>/dev/null \
    | tr ' ' '\n' | grep -c '^data-recovery$' || true)
  echo "data-recovery count: $ic_count" >&2
  [ "$ic_count" = "1" ]
}

# ── API smoke test via aqsh: G1 + G2 pass on pre-check ───────────────────────
#
# Requires a live aqsh-mongodb endpoint (MONGODB_AQSH_URL) and a valid TOKEN.
# Skipped automatically if TOKEN is empty (common_setup called without
# --create-token).

@test "mongo-1: recovery/pre-check G1 and G2 pass (requires aqsh endpoint)" {
  [ -n "${TOKEN:-}" ] || skip "TOKEN not set — re-run with common_setup --create-token"

  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-0","data_path":"/data/db","mount_path":"/data/db"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id" 120

  local gates
  gates=$(echo "$TASK_RESPONSE" | jq -r '.result.data.gates // empty')

  local g1_pass g2_pass
  g1_pass=$(echo "$gates" | jq -r '.[] | select(.gate=="G1") | .pass')
  g2_pass=$(echo "$gates" | jq -r '.[] | select(.gate=="G2") | .pass')

  echo "G1 pass: $g1_pass" >&2
  echo "G2 pass: $g2_pass" >&2

  assert_equal "$g1_pass" "true"
  assert_equal "$g2_pass" "true"
}

# ── Guard: Bitnami One-Time Setup patch must NOT be applied to this repo ──────
#
# The Bitnami patch uses volume name 'datadir', mount path '/bitnami/mongodb',
# and runAsUser 1001.  Applied to a standard mongo:7 StatefulSet it silently
# does nothing during a wipe (find targets the wrong directory) while G1 still
# passes (init container name is correct).  These tests catch that mistake.

@test "mongo-1: init container volume name is NOT Bitnami 'datadir'" {
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
  local vol_names
  vol_names=$(kubectl --context "$ctx" -n mongo-1 get statefulset mongodb \
    -o jsonpath='{.spec.template.spec.initContainers[?(@.name=="data-recovery")].volumeMounts[*].name}' \
    2>/dev/null)
  echo "volumeMount names: $vol_names" >&2
  [[ "$vol_names" != *"datadir"* ]]
}

@test "mongo-1: init container args do NOT reference Bitnami path /bitnami" {
  local args
  args=$(_ic_field "mongo-1" '.args[0]')
  echo "args (first 120 chars): ${args:0:120}" >&2
  [[ "$args" != *"/bitnami"* ]]
}

@test "mongo-1: init container does NOT run as Bitnami user 1001" {
  local run_as_user
  run_as_user=$(_ic_field "mongo-1" '.securityContext.runAsUser')
  echo "runAsUser: $run_as_user" >&2
  [ "$run_as_user" != "1001" ]
}
