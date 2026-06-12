#!/usr/bin/env bats
# =============================================================================
# Integration tests for the MongoDB recovery task API.
# Requires a deployed MongoDB RS cluster in mongo-1 namespace (3 replicas).
# These tests verify the task endpoints accept requests, execute, and return
# structured results.
#
# mongo-1 runs with --replSet rs0 --bind_ip_all (no --auth), so authorization
# is not enforced — but the recovery gates always authenticate, and MongoDB
# rejects authentication for a nonexistent user even with authorization off.
# setup_file therefore explicitly creates the root user from the
# mongodb-credentials secret after RS init (idempotent).
# =============================================================================

setup_file() {
  load '../test_helper/common_setup'
  # This file runs 2 full recovers + initial-sync waits on top of long
  # rollouts; the default 30m token can expire mid-file.
  export TOKEN_DURATION=2h
  common_setup --create-token

  # deploy_mongodb sets up namespace, RBAC, credentials secret, and nodeport.
  # It deploys mongo-1.yaml (standalone single-replica) as a baseline.
  deploy_mongodb "mongo-1"

  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"

  # Upgrade to 3-replica RS: apply RS-mode StatefulSet inline.
  # mongo-1.yaml stays as single-replica standalone for the normal deploy.sh path;
  # recovery integration tests need a full RS to exercise G3/G7/replSetSyncFrom.
  kubectl --context "$ctx" -n mongo-1 apply -f - <<'RS_EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: mongo-1
spec:
  replicas: 3
  selector:
    matchLabels:
      app: mongodb
  serviceName: mongodb
  template:
    metadata:
      labels:
        app: mongodb
        app.kubernetes.io/name: mongodb
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
      containers:
        - name: mongodb
          image: mongo:7
          command: ["mongod"]
          args: ["--replSet", "rs0", "--bind_ip_all"]
          ports:
            - containerPort: 27017
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
            readOnlyRootFilesystem: false
          readinessProbe:
            exec:
              command: ["mongosh", "--quiet", "--norc", "--eval", "db.adminCommand('ping').ok"]
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          volumeMounts:
            - name: data
              mountPath: /data/db
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
RS_EOF

  echo "Waiting for 3-replica RS rollout in mongo-1..."
  kubectl --context "$ctx" -n mongo-1 \
    rollout status statefulset/mongodb --timeout=300s

  # Initialize replica set (member 0 has priority 2 → deterministic primary)
  _init_mongodb_rs "mongo-1" "$ctx" 3
  _wait_for_mongodb_primary "mongo-1" "$ctx" 180

  # Ensure the root user from mongodb-credentials actually exists in MongoDB.
  # Auth is not enforced here, but the recovery gates always authenticate and
  # MongoDB rejects auth for nonexistent users even with authorization off.
  # (It usually already exists: the standalone mongo-1.yaml entrypoint created
  # it on mongodb-0's PVC — do not rely on that accident.)
  local mongo_user mongo_pass
  mongo_user=$(kubectl --context "$ctx" -n mongo-1 get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  mongo_pass=$(kubectl --context "$ctx" -n mongo-1 get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)
  local user_elapsed=0
  while (( user_elapsed < 60 )); do
    # createUser must run on the primary; retry until the election settles.
    if kubectl --context "$ctx" -n mongo-1 exec mongodb-0 -- mongosh --quiet --norc \
      "mongodb://localhost:27017/admin" --eval "
        try {
          db.getSiblingDB('admin').createUser({user:'${mongo_user}', pwd:'${mongo_pass}', roles:[{role:'root',db:'admin'}]});
          print('root user created');
        } catch(e) {
          if (/already exists/.test(e.message)) { print('root user exists'); }
          else { throw e; }
        }" >/dev/null 2>&1; then
      break
    fi
    sleep 5; user_elapsed=$((user_elapsed + 5))
  done

  # Apply the recovery ConfigMap (G2 gate requires it)
  kubectl --context "$ctx" -n mongo-1 apply -f - <<'CM_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: mongodb-recovery-config
  namespace: mongo-1
data:
  wipe-targets: ""
  recovery-version: "0"
CM_EOF

  # Patch the StatefulSet to add the data-recovery init container (uses /data/db)
  # and lock partition=3 so only deliberate partition changes restart pods.
  kubectl --context "$ctx" -n mongo-1 \
    patch statefulset mongodb --type=strategic -p "$(cat <<'PATCH_EOF'
{
  "spec": {
    "updateStrategy": {"rollingUpdate": {"partition": 3}},
    "template": {
      "spec": {
        "initContainers": [{
          "name": "data-recovery",
          "image": "mongo:7",
          "command": ["/bin/bash", "-c"],
          "args": ["WIPE_TARGETS=$(cat /recovery-config/wipe-targets 2>/dev/null || echo ''); MY_NAME=$(hostname); if [ -n \"$WIPE_TARGETS\" ] && echo \"$WIPE_TARGETS\" | grep -qw \"$MY_NAME\"; then echo \"[RECOVERY] Wiping data for $MY_NAME\"; find /data/db -mindepth 1 -delete 2>/dev/null || true; echo \"[RECOVERY] Wipe complete.\"; else echo \"[RECOVERY] $MY_NAME not in wipe targets, skip.\"; fi"],
          "volumeMounts": [
            {"name": "data", "mountPath": "/data/db"},
            {"name": "recovery-config-vol", "mountPath": "/recovery-config", "readOnly": true}
          ],
          "securityContext": {"runAsUser": 999, "runAsNonRoot": true}
        }],
        "volumes": [{
          "name": "recovery-config-vol",
          "configMap": {"name": "mongodb-recovery-config"}
        }]
      }
    }
  }
}
PATCH_EOF
)"

  echo "Waiting for MongoDB to stabilise after init-container patch..."
  kubectl --context "$ctx" -n mongo-1 \
    rollout status statefulset/mongodb --timeout=300s || true
  _wait_for_mongodb_primary "mongo-1" "$ctx" 120
}

setup() {
  load '../test_helper/common_setup'
}

teardown_file() {
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" delete ns mongo-1 --ignore-not-found
}

# ── recovery/status ───────────────────────────────────────────────────────────

@test "recovery/status returns 202 and completes successfully" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fstatus" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"
}

@test "recovery/status result includes STS and CM fields" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fstatus" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local sts cm_found pods
  sts=$(echo "$result" | jq -r '.sts // empty')
  cm_found=$(echo "$result" | jq -r '.configmap_found // empty')
  pods=$(echo "$result" | jq -r '.pods // empty')

  assert_equal "$sts" "mongodb"
  assert_equal "$cm_found" "true"
  [ -n "$pods" ]
}

@test "recovery/status shows 3 pods with phase info" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fstatus" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local pod_count
  pod_count=$(echo "$result" | jq '[.pods[]] | length' 2>/dev/null || echo "0")
  [ "$pod_count" -eq 3 ]
}

# ── recovery/pre-check ────────────────────────────────────────────────────────

@test "recovery/pre-check returns 202 for a secondary pod" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2","data_path":"/data/db","mount_path":"/data/db"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"
}

@test "recovery/pre-check result contains 8 gates" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2","data_path":"/data/db","mount_path":"/data/db"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local gate_count
  gate_count=$(echo "$result" | jq '[.gates[] | select(.gate)] | length' 2>/dev/null || echo "0")
  [ "$gate_count" -ge 8 ]
}

@test "recovery/pre-check G1 reports init container present after STS patch" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2","data_path":"/data/db","mount_path":"/data/db"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g1_pass
  g1_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G1") | .pass' 2>/dev/null || echo "null")
  assert_equal "$g1_pass" "true"
}

@test "recovery/pre-check G2 reports ConfigMap present" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2","data_path":"/data/db","mount_path":"/data/db"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g2_pass
  g2_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G2") | .pass' 2>/dev/null || echo "null")
  assert_equal "$g2_pass" "true"
}

@test "recovery/pre-check G3 reports healthy sync source and primary available" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2","data_path":"/data/db","mount_path":"/data/db"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g3_pass
  g3_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G3") | .pass' 2>/dev/null || echo "null")
  assert_equal "$g3_pass" "true"
}

@test "recovery/pre-check G4 reports oplog window sufficient" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2","data_path":"/data/db","mount_path":"/data/db"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g4_pass
  g4_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G4") | .pass' 2>/dev/null || echo "null")
  # G4 may pass clean or warn with OPLOG_RESIZE_NEEDED (pre-check is read-only
  # and never resizes), but must not be false on a fresh small cluster
  [ "$g4_pass" = "true" ]
}

@test "recovery/pre-check G5 reports data size within limit" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2","data_path":"/data/db","mount_path":"/data/db"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g5_pass
  g5_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G5") | .pass' 2>/dev/null || echo "null")
  assert_equal "$g5_pass" "true"
}

@test "recovery/pre-check G6 reports PVC space sufficient" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2","data_path":"/data/db","mount_path":"/data/db"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g6_pass
  g6_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G6") | .pass' 2>/dev/null || echo "null")
  # G6 may warn if df is unavailable, but must not block
  [ "$g6_pass" = "true" ]
}

@test "recovery/pre-check G7 blocks when target is mongodb-0 (primary)" {
  # mongodb-0 is deterministically primary (priority 2 set in _init_mongodb_rs).
  # G7 should detect this and return pass=false with code POD0_IS_PRIMARY.
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-0","data_path":"/data/db","mount_path":"/data/db"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id" 120 || true  # task completes even with gate failure

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g7_pass g7_code
  g7_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G7") | .pass' 2>/dev/null || echo "null")
  g7_code=$(echo "$result" | jq -r '.gates[] | select(.gate=="G7") | .code' 2>/dev/null || echo "null")
  assert_equal "$g7_pass" "false"
  assert_equal "$g7_code" "POD0_IS_PRIMARY"
}

@test "recovery/pre-check G7 passes when target is a secondary (mongodb-2)" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2","data_path":"/data/db","mount_path":"/data/db"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g7_pass
  g7_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G7") | .pass' 2>/dev/null || echo "null")
  assert_equal "$g7_pass" "true"
}

@test "recovery/pre-check G8 reports no RECOVERING members on healthy cluster" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2","data_path":"/data/db","mount_path":"/data/db"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local g8_pass g8_warn
  g8_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G8") | .pass' 2>/dev/null || echo "null")
  g8_warn=$(echo "$result" | jq -r '.gates[] | select(.gate=="G8") | .warn' 2>/dev/null || echo "null")
  assert_equal "$g8_pass" "true"
  assert_equal "$g8_warn" "null"  # no warn on healthy cluster
}

# ── recovery/fix-no-primary (diagnose only — safe read-only) ──────────────────

@test "recovery/fix-no-primary diagnose returns 202 and completes" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Ffix-no-primary" \
    '{"namespace":"mongo-1","level":"diagnose"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"
}

@test "recovery/fix-no-primary diagnose shows PRIMARY_EXISTS for healthy cluster" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Ffix-no-primary" \
    '{"namespace":"mongo-1","level":"diagnose"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local diagnosis primary_count secondary_count
  diagnosis=$(echo "$result" | jq -r '.diagnosis // empty')
  primary_count=$(echo "$result" | jq -r '.primary_count // 0')
  secondary_count=$(echo "$result" | jq -r '.secondary_count // 0')
  assert_equal "$diagnosis" "PRIMARY_EXISTS"
  [ "$primary_count" -ge 1 ]
  [ "$secondary_count" -ge 2 ]  # 3-member RS has 2 secondaries
}

@test "recovery/fix-no-primary rejects unknown level" {
  # tasks.yaml declares a pattern for `level`, so aqsh must reject this at
  # submission time — anything else (202) is a config regression.
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Ffix-no-primary" \
    '{"namespace":"mongo-1","level":"invalid-level"}'
  [ "$HTTP_CODE" != "202" ]
}

# ── recovery/reset (idempotent — safe to run on a clean cluster) ──────────────

@test "recovery/reset clears wipe-target and resets partition" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Freset" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local wipe_targets
  wipe_targets=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  assert_equal "$wipe_targets" ""
}

@test "recovery/reset result includes partition and sts fields" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Freset" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local sts partition
  sts=$(echo "$result" | jq -r '.sts // empty')
  partition=$(echo "$result" | jq -r '.partition // empty')
  assert_equal "$sts" "mongodb"
  assert_equal "$partition" "3"
}

# ── recovery/recover (full end-to-end — wipes a secondary, verifies re-sync) ──

@test "recovery/recover wipes secondary mongodb-2 and it rejoins as healthy SECONDARY" {
  # Capture pre-wipe UID to prove the pod actually restarted
  local before_uid
  before_uid=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 \
    get pod mongodb-2 -o jsonpath='{.metadata.uid}')

  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Frecover" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2","wait_timeout":"300","data_path":"/data/db","mount_path":"/data/db"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id" 540

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')

  # Orchestrator reports success
  local reached
  reached=$(echo "$result" | jq -r '.reached_running // empty')
  assert_equal "$reached" "true"

  # sync_source_set is timing-dependent on a freshly wiped member: the gates'
  # credentials only authenticate once initial sync has cloned admin.system.users,
  # so replSetSyncFrom usually fails (false) unless the tiny dataset syncs within
  # the retry window. Both outcomes are valid; recovery success must not depend on it.
  local sync_src_set
  sync_src_set=$(echo "$result" | jq -r '.sync_source_set // "MISSING"')
  [ "$sync_src_set" != "MISSING" ]
  [[ "$sync_src_set" == "true" || "$sync_src_set" == "false" ]]

  # Pod was genuinely recreated (UID changed)
  local after_uid
  after_uid=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 \
    get pod mongodb-2 -o jsonpath='{.metadata.uid}')
  [ "$before_uid" != "$after_uid" ]

  # wipe-targets cleared by reset
  local wipe_targets
  wipe_targets=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  assert_equal "$wipe_targets" ""

  # Wait for mongodb-2 to finish initial sync and rejoin RS
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 wait pod mongodb-2 \
    --for=condition=Ready --timeout=180s >/dev/null 2>&1 || true

  local elapsed=0 state=""
  while (( elapsed < 180 )); do
    state=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 \
      exec mongodb-0 -- mongosh --quiet --norc \
      "mongodb://localhost:27017/admin" \
      --eval "var m=rs.status().members.filter(function(x){return x.name.indexOf('mongodb-2')!==-1;})[0]; print(m?m.stateStr+','+m.health:'NONE,0');" \
      2>/dev/null | tail -1 | tr -d '\r')
    [[ "$state" == "SECONDARY,1" || "$state" == "PRIMARY,1" ]] && break
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "mongodb-2 final RS state: ${state}"
  [[ "$state" == "SECONDARY,1" || "$state" == "PRIMARY,1" ]]
}

@test "recovery/recover result includes sync_source_set as boolean" {
  # This test runs a second recover on mongodb-2 (idempotent — G-gates will re-pass)
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Frecover" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2","wait_timeout":"300","data_path":"/data/db","mount_path":"/data/db"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id" 540

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local sync_src_set
  sync_src_set=$(echo "$result" | jq -r '.sync_source_set // "MISSING"')
  [ "$sync_src_set" != "MISSING" ]
  [[ "$sync_src_set" == "true" || "$sync_src_set" == "false" ]]

  # Timing-dependent (see first recover test): true only if initial sync cloned
  # admin users within the replSetSyncFrom retry window.
  if [[ "$sync_src_set" == "true" ]]; then
    echo "sync_source_set=true — replSetSyncFrom executed successfully on real cluster"
  else
    echo "sync_source_set=false — replSetSyncFrom was retried but failed (non-fatal, recovery still succeeded)"
    local reached
    reached=$(echo "$result" | jq -r '.reached_running // empty')
    assert_equal "$reached" "true"
  fi
}

@test "recovery/status shows no active_recovery after recover" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fstatus" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  local active_recovery wipe_targets
  # No `// empty` here: jq's // treats boolean false as falsy and would erase it
  active_recovery=$(echo "$result" | jq -r '.active_recovery')
  wipe_targets=$(echo "$result" | jq -r '.wipe_targets // empty')
  assert_equal "$active_recovery" "false"
  assert_equal "$wipe_targets" ""
}

# ── Missing required parameters ───────────────────────────────────────────────

@test "recovery/pre-check rejects request with missing target_pod" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" '{"namespace":"mongo-1"}'
  [ "$HTTP_CODE" != "202" ]
}

@test "recovery/recover rejects request with missing target_pod" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Frecover" '{"namespace":"mongo-1"}'
  [ "$HTTP_CODE" != "202" ]
}

@test "recovery/wipe rejects request with missing target_pod" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fwipe" '{"namespace":"mongo-1"}'
  [ "$HTTP_CODE" != "202" ]
}

@test "recovery/fix-no-primary rejects request with missing level" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Ffix-no-primary" '{"namespace":"mongo-1"}'
  [ "$HTTP_CODE" != "202" ]
}
