#!/usr/bin/env bats
# =============================================================================
# Integration tests for G7 regression and wipe+reset split flow.
#
# Covers:
#   C1  G7 blocks TARGET_IS_PRIMARY when target is the current primary
#   C2  G7 passes when target is a secondary
#   D1  wipe → wait Running → manual reset → status shows active_recovery:false
#   D2  wipe without reset → ConfigMap wipe-targets stays set (expected behaviour)
#
# Uses a dedicated namespace (mongo-wr) to avoid conflict with recovery.bats.
# =============================================================================

setup_file() {
  load '../test_helper/common_setup'
  export TOKEN_DURATION=2h
  common_setup --create-token

  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
  local ns="mongo-wr"

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

  if ! kubectl --context "$ctx" -n "$ns" get secret mongodb-credentials &>/dev/null; then
    kubectl --context "$ctx" -n "$ns" create secret generic mongodb-credentials \
      --from-literal="MONGO_ROOT_USER=mongo-wr-admin" \
      --from-literal="MONGO_ROOT_PASS=$(openssl rand -base64 16 | tr -d '=+/')"
  fi

  export _WR_USER _WR_PASS
  _WR_USER=$(kubectl --context "$ctx" -n "$ns" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  _WR_PASS=$(kubectl --context "$ctx" -n "$ns" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)

  # ── Headless Service (required for RS DNS: mongodb-N.mongodb.<ns>.svc.cluster.local) ──
  kubectl --context "$ctx" -n "$ns" apply -f - <<'SVC_EOF'
apiVersion: v1
kind: Service
metadata:
  name: mongodb
spec:
  clusterIP: None
  selector:
    app: mongodb
  ports:
    - port: 27017
      targetPort: 27017
SVC_EOF

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

  _init_mongodb_rs "$ns" "$ctx" 3
  _wait_for_mongodb_primary "$ns" "$ctx" 180

  # Create root user
  local elapsed=0
  while (( elapsed < 60 )); do
    if kubectl --context "$ctx" -n "$ns" exec mongodb-0 -- mongosh --quiet --norc \
      "mongodb://localhost:27017/admin" --eval "
        try {
          db.getSiblingDB('admin').createUser({
            user:'${_WR_USER}',pwd:'${_WR_PASS}',
            roles:[{role:'root',db:'admin'}]});
          print('created');
        } catch(e) {
          if(/already exists/.test(e.message)){print('exists');} else{throw e;}
        }" >/dev/null 2>&1; then
      break
    fi
    sleep 5; elapsed=$((elapsed + 5))
  done

  # ── Recovery prerequisites ────────────────────────────────────────────────────
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
    delete ns mongo-wr --ignore-not-found
}

_task_data() { echo "$TASK_RESPONSE" | jq -r '.result.data // empty'; }

# ── C: G7 regression ─────────────────────────────────────────────────────────
#
# With the G7 fix, _recovery_gate_g7 uses h.setName to skip standalone pods
# and checks db.hello().isWritablePrimary for RS members.
# These tests confirm primary detection is correct and ordinal-agnostic.

@test "C1: pre-check G7 blocks TARGET_IS_PRIMARY when target is the current primary" {
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"

  # Find the actual primary (may not always be mongodb-0 after elections)
  local primary_pod
  primary_pod=$(_find_primary_pod "mongo-wr" "$ctx")
  echo "Current primary: $primary_pod" >&2

  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    "{\"namespace\":\"mongo-wr\",\"target_pod\":\"${primary_pod}\",
      \"data_path\":\"/data/db\",\"mount_path\":\"/data/db\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local g7_pass g7_code
  g7_pass=$(_task_data | jq -r '.gates[] | select(.gate=="G7") | .pass' 2>/dev/null || echo "null")
  g7_code=$(_task_data | jq -r '.gates[] | select(.gate=="G7") | .code // empty' 2>/dev/null)
  echo "G7 pass=$g7_pass code=$g7_code" >&2
  assert_equal "$g7_pass" "false"
  assert_equal "$g7_code" "TARGET_IS_PRIMARY"
}

@test "C2: pre-check G7 passes when target is a secondary" {
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"

  # Find a non-primary pod
  local primary_pod secondary_pod=""
  primary_pod=$(_find_primary_pod "mongo-wr" "$ctx")
  for p in mongodb-0 mongodb-1 mongodb-2; do
    [[ "$p" != "$primary_pod" ]] && { secondary_pod="$p"; break; }
  done
  echo "Primary: $primary_pod  Secondary target: $secondary_pod" >&2

  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fpre-check" \
    "{\"namespace\":\"mongo-wr\",\"target_pod\":\"${secondary_pod}\",
      \"data_path\":\"/data/db\",\"mount_path\":\"/data/db\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local g7_pass
  g7_pass=$(_task_data | jq -r '.gates[] | select(.gate=="G7") | .pass' 2>/dev/null || echo "null")
  echo "G7 pass=$g7_pass" >&2
  assert_equal "$g7_pass" "true"
}

# ── D: wipe + reset split flow ────────────────────────────────────────────────

@test "D1: manual wipe then reset clears active_recovery flag" {
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"

  # Step 1: wipe mongodb-2
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fwipe" \
    '{"namespace":"mongo-wr","target_pod":"mongodb-2",
      "data_path":"/data/db","mount_path":"/data/db"}'
  assert_equal "$HTTP_CODE" "202"
  local wipe_task_id
  wipe_task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$wipe_task_id" 120

  # Step 2: wait for pod to terminate then come back Running with a new UID.
  # (The "before" UID is read here, AFTER submitting wipe, so kubernetes may have
  #  already bumped the pod — capture it before the loop.)
  echo "Waiting for mongodb-2 to terminate and restart..." >&2
  local before_uid after_uid elapsed=0
  before_uid=$(kubectl --context "$ctx" -n mongo-wr \
    get pod mongodb-2 -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "none")
  echo "UID before wipe restart: $before_uid" >&2

  # Phase 1: wait until pod is gone or UID changed (restart in progress)
  until [[ "$(kubectl --context "$ctx" -n mongo-wr \
      get pod mongodb-2 -o jsonpath='{.metadata.uid}' 2>/dev/null || echo '')" \
      != "$before_uid" ]]; do
    [[ $elapsed -ge 300 ]] && { echo "Pod did not restart within 300s" >&2; break; }
    sleep 5; elapsed=$((elapsed + 5))
  done

  # Phase 2: wait until pod is Running (reset elapsed so each phase gets its own 300s budget)
  elapsed=0
  until kubectl --context "$ctx" -n mongo-wr \
      get pod mongodb-2 -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; do
    [[ $elapsed -ge 300 ]] && { echo "Pod did not reach Running within 300s" >&2; break; }
    sleep 5; elapsed=$((elapsed + 5))
  done

  after_uid=$(kubectl --context "$ctx" -n mongo-wr \
    get pod mongodb-2 -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "none")
  echo "UID after restart: $after_uid" >&2
  [ "$before_uid" != "$after_uid" ]  # pod genuinely restarted

  # Step 3: manual reset
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Freset" \
    '{"namespace":"mongo-wr"}'
  assert_equal "$HTTP_CODE" "202"
  local reset_task_id
  reset_task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$reset_task_id"

  # Step 4: status must show no active recovery
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fstatus" \
    '{"namespace":"mongo-wr"}'
  assert_equal "$HTTP_CODE" "202"
  local status_task_id
  status_task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$status_task_id"

  local active_recovery wipe_targets
  active_recovery=$(_task_data | jq -r '.active_recovery')
  wipe_targets=$(_task_data | jq -r '.wipe_targets // empty')
  assert_equal "$active_recovery" "false"
  assert_equal "$wipe_targets" ""

  # Wait for mongodb-2 to rejoin RS before next test
  kubectl --context "$ctx" -n mongo-wr \
    wait pod mongodb-2 --for=condition=Ready --timeout=180s >/dev/null 2>&1 || true
  _wait_for_rs_healthy "mongo-wr" "mongodb-2" "$ctx" 180
}

@test "D2: wipe without reset — wipe-targets stays set in ConfigMap (expected behaviour)" {
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"

  # wipe mongodb-2
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Fwipe" \
    '{"namespace":"mongo-wr","target_pod":"mongodb-2",
      "data_path":"/data/db","mount_path":"/data/db"}'
  assert_equal "$HTTP_CODE" "202"
  local wipe_task_id
  wipe_task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$wipe_task_id" 120

  # Wait for pod to terminate and come back (UID change confirms init container ran)
  echo "Waiting for mongodb-2 to restart..." >&2
  local before_uid_d2 elapsed=0
  before_uid_d2=$(kubectl --context "$ctx" -n mongo-wr \
    get pod mongodb-2 -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "none")
  until [[ "$(kubectl --context "$ctx" -n mongo-wr \
      get pod mongodb-2 -o jsonpath='{.metadata.uid}' 2>/dev/null || echo '')" \
      != "$before_uid_d2" ]]; do
    [[ $elapsed -ge 300 ]] && break
    sleep 5; elapsed=$((elapsed + 5))
  done
  # Wait until Running again (reset elapsed so Phase 2 gets its own 300s budget)
  elapsed=0
  until kubectl --context "$ctx" -n mongo-wr \
      get pod mongodb-2 -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; do
    [[ $elapsed -ge 300 ]] && break
    sleep 5; elapsed=$((elapsed + 5))
  done

  # Do NOT call reset — verify wipe-targets is still set
  local wipe_targets
  wipe_targets=$(kubectl --context "$ctx" -n mongo-wr \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  echo "wipe-targets after wipe (no reset): '${wipe_targets}'" >&2
  assert_equal "$wipe_targets" "mongodb-2"

  # Cleanup: reset so subsequent tests start clean
  http_post "${MONGODB_AQSH_URL}/tasks/recovery%2Freset" \
    '{"namespace":"mongo-wr"}'
  local reset_task_id
  reset_task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$reset_task_id" || true

  kubectl --context "$ctx" -n mongo-wr \
    wait pod mongodb-2 --for=condition=Ready --timeout=180s >/dev/null 2>&1 || true
  _wait_for_rs_healthy "mongo-wr" "mongodb-2" "$ctx" 180
}
