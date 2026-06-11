#!/usr/bin/env bats
# =============================================================================
# Integration tests for the MongoDB recovery task API.
# Requires a deployed MongoDB cluster in mongo-1 namespace.
# These tests verify the task endpoints accept requests, execute, and return
# structured results — they do NOT corrupt or wipe real data.
# =============================================================================

setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  deploy_mongodb "mongo-1"

  # Apply the recovery ConfigMap so G2 gate passes in pre-check tests
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 \
    apply -f - <<'CM_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: mongodb-recovery-config
  namespace: mongo-1
data:
  wipe-targets: ""
  recovery-version: "0"
CM_EOF

  # Patch the StatefulSet to add the data-recovery init container
  # Uses the same image as the mongodb container and partition=3 (locked)
  MONGO_IMAGE=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.spec.template.spec.containers[0].image}')
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 \
    patch statefulset mongodb --type=strategic -p "$(cat <<PATCH_EOF
{
  "spec": {
    "updateStrategy": {"rollingUpdate": {"partition": 3}},
    "template": {
      "spec": {
        "initContainers": [{
          "name": "data-recovery",
          "image": "${MONGO_IMAGE}",
          "command": ["/bin/bash", "-c"],
          "args": ["WIPE_TARGETS=\$(cat /recovery-config/wipe-targets 2>/dev/null || echo ''); MY_NAME=\$(hostname); if [ -n \"\$WIPE_TARGETS\" ] && echo \"\$WIPE_TARGETS\" | grep -qw \"\$MY_NAME\"; then echo \"[RECOVERY] Wiping data for \$MY_NAME\"; find /bitnami/mongodb/data/db -mindepth 1 -delete 2>/dev/null || true; echo \"[RECOVERY] Wipe complete.\"; else echo \"[RECOVERY] \$MY_NAME not in wipe targets, skip.\"; fi"],
          "volumeMounts": [
            {"name": "datadir", "mountPath": "/bitnami/mongodb"},
            {"name": "recovery-config-vol", "mountPath": "/recovery-config", "readOnly": true}
          ],
          "securityContext": {"runAsUser": 1001, "runAsNonRoot": true}
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

  echo "Waiting for MongoDB to be ready after STS patch..."
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 \
    rollout status statefulset/mongodb --timeout=300s || true
  _wait_for_mongodb_primary "mongo-1" "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" 120
}

setup() {
  load '../test_helper/common_setup'
}

teardown_file() {
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" delete ns mongo-1 --ignore-not-found
}

# ── recovery/status ───────────────────────────────────────────────────────────

@test "recovery/status returns 202 and completes successfully" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery/status" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"
}

@test "recovery/status result includes STS and CM fields" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery/status" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result // empty')
  sts=$(echo "$result" | jq -r '.sts // empty')
  cm_found=$(echo "$result" | jq -r '.configmap_found // empty')
  pods=$(echo "$result" | jq -r '.pods // empty')

  assert_equal "$sts" "mongodb"
  assert_equal "$cm_found" "true"
  [ -n "$pods" ]
}

# ── recovery/pre-check ────────────────────────────────────────────────────────

@test "recovery/pre-check returns 202 for a secondary pod" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery/pre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"
}

@test "recovery/pre-check result contains gates array" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery/pre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result // empty')
  gate_count=$(echo "$result" | jq '[.gates[] | select(.gate)] | length' 2>/dev/null || echo "0")
  [ "$gate_count" -ge "7" ]
}

@test "recovery/pre-check G1 reports init container present after STS patch" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery/pre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result // empty')
  g1_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G1") | .pass' 2>/dev/null || echo "null")
  assert_equal "$g1_pass" "true"
}

@test "recovery/pre-check G2 reports ConfigMap present" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery/pre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result // empty')
  g2_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G2") | .pass' 2>/dev/null || echo "null")
  assert_equal "$g2_pass" "true"
}

@test "recovery/pre-check G3 reports healthy sync source available" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery/pre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result // empty')
  g3_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G3") | .pass' 2>/dev/null || echo "null")
  assert_equal "$g3_pass" "true"
}

# ── recovery/fix-no-primary (diagnose only — safe read-only) ──────────────────

@test "recovery/fix-no-primary diagnose returns 202 and completes" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery/fix-no-primary" \
    '{"namespace":"mongo-1","level":"diagnose"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"
}

@test "recovery/fix-no-primary diagnose shows PRIMARY_EXISTS for healthy cluster" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery/fix-no-primary" \
    '{"namespace":"mongo-1","level":"diagnose"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result // empty')
  diagnosis=$(echo "$result" | jq -r '.diagnosis // empty')
  primary_count=$(echo "$result" | jq -r '.primary_count // 0')
  assert_equal "$diagnosis" "PRIMARY_EXISTS"
  [ "$primary_count" -ge "1" ]
}

@test "recovery/fix-no-primary rejects unknown level" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery/fix-no-primary" \
    '{"namespace":"mongo-1","level":"invalid-level"}'
  # aqsh validates pattern — should reject with 4xx
  [ "$HTTP_CODE" != "202" ] || {
    local task_id
    task_id=$(echo "$HTTP_BODY" | jq -r '.id')
    if wait_for_task "$MONGODB_AQSH_URL" "$task_id" 30; then
      result=$(echo "$TASK_RESPONSE" | jq -r '.result // empty')
      echo "$result" | grep -q '"error"'
    fi
  }
}

# ── recovery/reset (idempotent — safe to run on a clean cluster) ──────────────

@test "recovery/reset clears wipe-target and resets partition" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery/reset" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  # Verify wipe-targets is empty
  wipe_targets=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  assert_equal "$wipe_targets" ""
}

@test "recovery/reset result includes partition and sts fields" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery/reset" '{"namespace":"mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result // empty')
  sts=$(echo "$result" | jq -r '.sts // empty')
  partition=$(echo "$result" | jq -r '.partition // empty')
  assert_equal "$sts" "mongodb"
  assert_equal "$partition" "3"
}

# ── recovery/recover (full end-to-end — wipes a secondary, verifies re-sync) ──

@test "recovery/recover wipes secondary mongodb-2 and it rejoins as healthy SECONDARY" {
  # Sanity: capture the secondary's pre-wipe UID so we can prove it restarted
  before_uid=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 \
    get pod mongodb-2 -o jsonpath='{.metadata.uid}')

  http_post "${MONGODB_AQSH_URL}/tasks/recovery/recover" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2","wait_timeout":"300"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  # Orchestrator reports success and a restart
  local result
  result=$(echo "$TASK_RESPONSE" | jq -r '.result // empty')
  reached=$(echo "$result" | jq -r '.reached_running // empty')
  assert_equal "$reached" "true"

  # The pod was genuinely recreated
  after_uid=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 \
    get pod mongodb-2 -o jsonpath='{.metadata.uid}')
  [ "$before_uid" != "$after_uid" ]

  # wipe-targets was cleared (reset ran)
  wipe_targets=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  assert_equal "$wipe_targets" ""

  # Wait for mongodb-2 to finish initial sync and report SECONDARY/health=1
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 wait pod mongodb-2 \
    --for=condition=Ready --timeout=180s >/dev/null 2>&1 || true

  user=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 \
    get secret mongodb-credentials -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  pass=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 \
    get secret mongodb-credentials -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)

  local elapsed=0 state=""
  while (( elapsed < 180 )); do
    state=$(kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mongo-1 \
      exec mongodb-0 -- mongosh --quiet --norc \
      "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin" \
      --eval "var m=rs.status().members.filter(function(x){return x.name.indexOf('mongodb-2')!==-1;})[0]; print(m?m.stateStr+','+m.health:'NONE,0');" 2>/dev/null | tail -1 | tr -d '\r')
    [[ "$state" == "SECONDARY,1" || "$state" == "PRIMARY,1" ]] && break
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "mongodb-2 final RS state: ${state}"
  [[ "$state" == "SECONDARY,1" || "$state" == "PRIMARY,1" ]]
}

# ── Missing required parameters ───────────────────────────────────────────────

@test "recovery/pre-check rejects request with missing target_pod" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery/pre-check" '{"namespace":"mongo-1"}'
  [ "$HTTP_CODE" != "202" ]
}

@test "recovery/recover rejects request with missing target_pod" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery/recover" '{"namespace":"mongo-1"}'
  [ "$HTTP_CODE" != "202" ]
}

@test "recovery/wipe rejects request with missing target_pod" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery/wipe" '{"namespace":"mongo-1"}'
  [ "$HTTP_CODE" != "202" ]
}

@test "recovery/fix-no-primary rejects request with missing level" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery/fix-no-primary" '{"namespace":"mongo-1"}'
  [ "$HTTP_CODE" != "202" ]
}
