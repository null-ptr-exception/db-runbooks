#!/usr/bin/env bats
# =============================================================================
# Integration tests for the sts/orphan-delete task (aqsh-mongodb)
# (see docs/mongodb/sts-orphan-delete.md).
#
# Dedicated throwaway namespace, single-replica bare `mongo:7` StatefulSet —
# no replica-set init, no credentials. This task never speaks the MongoDB
# wire protocol or reads a credential secret; it only calls `kubectl delete
# statefulset --cascade=orphan`, so a standalone mongod answering readiness
# probes is enough to prove the STS is deleted while its Pod keeps running.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  ANS="mongo-sts-orphan"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=1h)
  export CTX_A CTX_B NS ANS AQSH_URL TEST_POD TOKEN

  local ctx="$CTX_A"
  kubectl --context "$ctx" create namespace "$ANS" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  kubectl --context "$ctx" -n "$ANS" apply -f - <<'RB_EOF'
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
    namespace: mongo-core
RB_EOF

  kubectl --context "$ctx" -n "$ANS" apply -f - <<STS_EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: ${ANS}
spec:
  replicas: 1
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
          args: ["--bind_ip_all"]
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
---
apiVersion: v1
kind: Service
metadata:
  name: mongodb
  namespace: ${ANS}
spec:
  clusterIP: None
  selector:
    app: mongodb
  ports:
    - port: 27017
      targetPort: 27017
STS_EOF

  kubectl --context "$ctx" -n "$ANS" rollout status statefulset/mongodb --timeout=300s
}

teardown_file() {
  local ctx="kind-cluster-a"
  # If the confirmed-delete test ran, the StatefulSet is already gone —
  # the orphaned pod/pvc still belong to the namespace, so deleting the
  # namespace cleans them up regardless of which tests ran.
  kubectl --context "$ctx" delete namespace "mongo-sts-orphan" \
    --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

# ---------------------------------------------------------------------------

kexec() { kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"; }

http_post() {
  local url="$1" body="$2" response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\\n%{http_code}' \
    -X POST '${url}' \
    -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Content-Type: application/json' \
    -d '${body}'")
  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

wait_for_task_any() {
  local base_url="$1" task_id="$2" max_wait="${3:-300}"
  local elapsed=0 status
  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE
    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    if [[ "$status" == "completed" || "$status" == "failed" ]]; then
      TASK_STATUS="$status"
      export TASK_STATUS
      return 0
    fi
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "Task ${task_id} still not terminal after ${max_wait}s (status: ${status})" >&2
  return 1
}

# submit a body to sts/orphan-delete and wait; exports TASK_STATUS,
# TASK_RESPONSE and RESULT_DATA (the .result.data payload).
run_orphan_delete_task() {
  local body="$1" max_wait="${2:-120}"
  http_post "${AQSH_URL}/tasks/sts%2Forphan-delete" "$body"
  [[ "$HTTP_CODE" == "202" ]] || { echo "submit got HTTP ${HTTP_CODE}: ${HTTP_BODY}" >&2; return 1; }
  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task_any "$AQSH_URL" "$task_id" "$max_wait" || return 1
  RESULT_DATA=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  export RESULT_DATA
}

# ---------------------------------------------------------------------------

@test "sts/orphan-delete default dry_run previews without changing anything" {
  run_orphan_delete_task "{\"namespace\":\"${ANS}\"}"
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.dry_run')" "true"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.sts')" "mongodb"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.replicas')" "1"
  assert_equal "$(echo "$RESULT_DATA" | jq -cr '.would_orphan_pods')" '["mongodb-0"]'

  # StatefulSet must still exist — dry-run makes no cluster changes.
  kubectl --context "$CTX_A" -n "$ANS" get statefulset mongodb >/dev/null
}

@test "sts/orphan-delete rejects dry_run=true with confirm=true" {
  run_orphan_delete_task "{\"namespace\":\"${ANS}\",\"dry_run\":\"true\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code // .error')" "INVALID_INPUT"
}

@test "sts/orphan-delete rejects dry_run=false without confirm" {
  run_orphan_delete_task "{\"namespace\":\"${ANS}\",\"dry_run\":\"false\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code // .error')" "INVALID_INPUT"
}

@test "sts/orphan-delete confirmed deletes only the StatefulSet, pod keeps running" {
  local pod_uid_before
  pod_uid_before=$(kubectl --context "$CTX_A" -n "$ANS" \
    get pod mongodb-0 -o jsonpath='{.metadata.uid}')

  run_orphan_delete_task "{\"namespace\":\"${ANS}\",\"dry_run\":\"false\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.sts')" "mongodb"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.replicas')" "1"
  assert_equal "$(echo "$RESULT_DATA" | jq -cr '.orphaned_pods')" '["mongodb-0"]'

  # StatefulSet controller object is gone...
  run kubectl --context "$CTX_A" -n "$ANS" get statefulset mongodb
  assert_failure

  # ...but the Pod (same identity, untouched) and its PVC are still there.
  local pod_uid_after
  pod_uid_after=$(kubectl --context "$CTX_A" -n "$ANS" \
    get pod mongodb-0 -o jsonpath='{.metadata.uid}')
  assert_equal "$pod_uid_after" "$pod_uid_before"

  local pod_phase
  pod_phase=$(kubectl --context "$CTX_A" -n "$ANS" \
    get pod mongodb-0 -o jsonpath='{.status.phase}')
  assert_equal "$pod_phase" "Running"

  kubectl --context "$CTX_A" -n "$ANS" get pvc data-mongodb-0 >/dev/null
}
