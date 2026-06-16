#!/usr/bin/env bats
# =============================================================================
# Integration tests for credential_user parameter in recovery tasks.
#
# Covers:
#   A1  pre-check passes when credential_user provided directly
#   A2  recover end-to-end with credential_user
#   A3  credential_user overrides a wrong credential_user_key (key is ignored)
#   E1  task fails when credential_secret does not exist
#   E2  task fails when credential_user_key points to a missing key in the secret
#   F1  fix-no-primary diagnose works with credential_user
#   F2  fix-no-primary unfreeze works with credential_user on healthy cluster
#
# Uses a dedicated namespace (mongo-cred) so it does not interfere with
# recovery.bats which owns mongo-1.
# =============================================================================

setup_file() {
  load '../test_helper/common_setup'
  export TOKEN_DURATION=2h
  common_setup --create-token

  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
  local ns="mongo-cred"

  # ── Namespace + RBAC ────────────────────────────────────────────────────────
  kubectl --context "$ctx" create ns "$ns" --dry-run=client -o yaml \
    | kubectl --context "$ctx" apply -f -

  kubectl --context "$ctx" -n "$ns" apply -f - <<'RBAC_EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: aqsh-mongo-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aqsh-mongo-manager
subjects:
  - kind: ServiceAccount
    name: kube-auth-proxy
    namespace: db-ops
RBAC_EOF

  # ── Credentials secret: password only style ─────────────────────────────────
  # Store only the password key — username is intentionally absent so tests
  # must supply it via credential_user.  We also keep MONGO_ROOT_USER for
  # normal-path coverage (A tests that don't pass credential_user directly).
  if ! kubectl --context "$ctx" -n "$ns" get secret mongodb-credentials &>/dev/null; then
    kubectl --context "$ctx" -n "$ns" create secret generic mongodb-credentials \
      --from-literal="MONGO_ROOT_USER=mongo-cred-admin" \
      --from-literal="MONGO_ROOT_PASS=$(openssl rand -base64 16 | tr -d '=+/')"
  fi

  # Export for use in @test bodies
  export _CRED_USER _CRED_PASS
  _CRED_USER=$(kubectl --context "$ctx" -n "$ns" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  _CRED_PASS=$(kubectl --context "$ctx" -n "$ns" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)

  # ── 3-replica RS StatefulSet ─────────────────────────────────────────────────
  kubectl --context "$ctx" -n "$ns" apply -f - <<'STS_EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
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
STS_EOF

  echo "Waiting for 3-replica rollout in ${ns}..."
  kubectl --context "$ctx" -n "$ns" rollout status statefulset/mongodb --timeout=300s

  # ── RS init ──────────────────────────────────────────────────────────────────
  _init_mongodb_rs "$ns" "$ctx" 3
  _wait_for_mongodb_primary "$ns" "$ctx" 180

  # Create root user (auth off but gates always authenticate)
  local elapsed=0
  while (( elapsed < 60 )); do
    if kubectl --context "$ctx" -n "$ns" exec mongodb-0 -- mongosh --quiet --norc \
      "mongodb://localhost:27017/admin" --eval "
        try {
          db.getSiblingDB('admin').createUser({
            user:'${_CRED_USER}',pwd:'${_CRED_PASS}',
            roles:[{role:'root',db:'admin'}]});
          print('created');
        } catch(e) {
          if(/already exists/.test(e.message)){print('exists');} else{throw e;}
        }" >/dev/null 2>&1; then
      break
    fi
    sleep 5; elapsed=$((elapsed + 5))
  done

  # ── Recovery prerequisites (G1 + G2) ────────────────────────────────────────
  kubectl --context "$ctx" -n "$ns" apply -f - <<'CM_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: mongodb-recovery-config
data:
  wipe-targets: ""
  recovery-version: "0"
CM_EOF

  kubectl --context "$ctx" -n "$ns" \
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
        "volumes": [{"name": "recovery-config-vol", "configMap": {"name": "mongodb-recovery-config"}}]
      }
    }
  }
}
PATCH_EOF
)"

  kubectl --context "$ctx" -n "$ns" rollout status statefulset/mongodb --timeout=300s || true
  _wait_for_mongodb_primary "$ns" "$ctx" 120
}

setup() {
  load '../test_helper/common_setup'
}

teardown_file() {
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" \
    delete ns mongo-cred --ignore-not-found
}

# ---------------------------------------------------------------------------
# Helper: extract data field from completed task response
# ---------------------------------------------------------------------------
_task_data() { echo "$TASK_RESPONSE" | jq -r '.result.data // empty'; }
_gate_pass()  { _task_data | jq -r ".gates[] | select(.gate==\"$1\") | .pass" 2>/dev/null || echo "null"; }

# ── A: credential_user provided directly ─────────────────────────────────────

@test "A1: pre-check passes all gates when credential_user supplied directly" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    "{\"namespace\":\"mongo-cred\",\"target_pod\":\"mongodb-2\",
      \"credential_user\":\"${_CRED_USER}\",
      \"data_path\":\"/data/db\",\"mount_path\":\"/data/db\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local fail_count
  fail_count=$(_task_data | jq '.fail // 0')
  assert_equal "$fail_count" "0"
}

@test "A1: pre-check G3 passes when credential_user supplied directly" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    "{\"namespace\":\"mongo-cred\",\"target_pod\":\"mongodb-2\",
      \"credential_user\":\"${_CRED_USER}\",
      \"data_path\":\"/data/db\",\"mount_path\":\"/data/db\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  assert_equal "$(_gate_pass G3)" "true"
}

@test "A2: recover end-to-end with credential_user — pod wipes and rejoins RS" {
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
  local before_uid
  before_uid=$(kubectl --context "$ctx" -n mongo-cred \
    get pod mongodb-2 -o jsonpath='{.metadata.uid}')

  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Frecover" \
    "{\"namespace\":\"mongo-cred\",\"target_pod\":\"mongodb-2\",
      \"credential_user\":\"${_CRED_USER}\",
      \"wait_timeout\":\"300\",
      \"data_path\":\"/data/db\",\"mount_path\":\"/data/db\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id" 540

  # Task reports pod reached Running
  local reached
  reached=$(_task_data | jq -r '.reached_running // empty')
  assert_equal "$reached" "true"

  # Pod was genuinely recreated
  local after_uid
  after_uid=$(kubectl --context "$ctx" -n mongo-cred \
    get pod mongodb-2 -o jsonpath='{.metadata.uid}')
  [ "$before_uid" != "$after_uid" ]

  # wipe-targets cleared by auto-reset
  local wipe_targets
  wipe_targets=$(kubectl --context "$ctx" -n mongo-cred \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  assert_equal "$wipe_targets" ""

  # Wait for rejoin
  kubectl --context "$ctx" -n mongo-cred \
    wait pod mongodb-2 --for=condition=Ready --timeout=180s >/dev/null 2>&1 || true
  _wait_for_rs_healthy "mongo-cred" "mongodb-2" "$ctx" 180
}

@test "A3: credential_user is used even when credential_user_key is a wrong key name" {
  # credential_user_key="NONEXISTENT_KEY" would fail the normal path,
  # but credential_user should make the key lookup be skipped entirely.
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    "{\"namespace\":\"mongo-cred\",\"target_pod\":\"mongodb-2\",
      \"credential_user\":\"${_CRED_USER}\",
      \"credential_user_key\":\"NONEXISTENT_KEY\",
      \"data_path\":\"/data/db\",\"mount_path\":\"/data/db\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  # Must complete successfully — wrong key name is ignored when credential_user is set
  local fail_count
  fail_count=$(_task_data | jq '.fail // 0')
  assert_equal "$fail_count" "0"
}

# ── E: error handling ─────────────────────────────────────────────────────────

@test "E1: pre-check fails when credential_secret does not exist" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    "{\"namespace\":\"mongo-cred\",\"target_pod\":\"mongodb-2\",
      \"credential_secret\":\"nonexistent-secret\",
      \"data_path\":\"/data/db\",\"mount_path\":\"/data/db\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  # Expect failed status — wait_for_task returns 1 on failure
  run wait_for_task "$MONGODB_AQSH_URL" "$task_id" 120
  assert_failure

  # Result must indicate error
  local task_status
  task_status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty')
  assert_equal "$task_status" "failed"
}

@test "E1: failed task result contains the secret name for diagnosis" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    "{\"namespace\":\"mongo-cred\",\"target_pod\":\"mongodb-2\",
      \"credential_secret\":\"nonexistent-secret\",
      \"data_path\":\"/data/db\",\"mount_path\":\"/data/db\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  run wait_for_task "$MONGODB_AQSH_URL" "$task_id" 120
  assert_failure

  echo "$TASK_RESPONSE" | grep -q "nonexistent-secret"
}

@test "E2: pre-check fails when credential_user_key points to a missing key in the secret" {
  # No credential_user — falls back to key lookup; key does not exist → empty value → error
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    "{\"namespace\":\"mongo-cred\",\"target_pod\":\"mongodb-2\",
      \"credential_user_key\":\"DOES_NOT_EXIST\",
      \"data_path\":\"/data/db\",\"mount_path\":\"/data/db\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  run wait_for_task "$MONGODB_AQSH_URL" "$task_id" 120
  assert_failure

  local task_status
  task_status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty')
  assert_equal "$task_status" "failed"
}

# ── F: fix-no-primary with credential_user ───────────────────────────────────

@test "F1: fix-no-primary diagnose returns PRIMARY_EXISTS when credential_user supplied" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Ffix-no-primary" \
    "{\"namespace\":\"mongo-cred\",\"level\":\"diagnose\",
      \"credential_user\":\"${_CRED_USER}\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local diagnosis
  diagnosis=$(_task_data | jq -r '.diagnosis // empty')
  assert_equal "$diagnosis" "PRIMARY_EXISTS"
}

@test "F2: fix-no-primary unfreeze succeeds on healthy cluster with credential_user" {
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Ffix-no-primary" \
    "{\"namespace\":\"mongo-cred\",\"level\":\"unfreeze\",
      \"credential_user\":\"${_CRED_USER}\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  # unfreeze on a healthy cluster: all 3 pods should succeed
  local success_count
  success_count=$(_task_data | jq '.success_count // 0')
  [ "$success_count" -eq 3 ]
}
