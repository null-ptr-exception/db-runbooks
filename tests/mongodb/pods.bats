#!/usr/bin/env bats
# =============================================================================
# Integration tests for the MongoDB pods gateway task API
# (pods/list, pods/delete) — see docs/mongodb/pods.md.
#
# Self-contained, own throwaway 2-replica StatefulSet in namespace
# "mongo-pods". Neither task speaks the MongoDB wire protocol or reads a
# credential secret — both are pure Kubernetes-API operations against the
# StatefulSet's own Pods — so a bare `mongo:7` standalone (no replica-set
# init, no root user) answering readiness probes is enough. A second,
# unrelated bare Pod in the same namespace proves membership is exact
# (ownerReferences), not a label/name guess.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  PNS="mongo-pods"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=2h)
  export CTX_A CTX_B NS PNS AQSH_URL TEST_POD TOKEN

  local ctx="$CTX_A"

  kubectl --context "$ctx" create namespace "$PNS" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  kubectl --context "$ctx" -n "$PNS" apply -f - <<RB_EOF
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

  kubectl --context "$ctx" -n "$PNS" apply -f - <<STS_EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: ${PNS}
spec:
  replicas: 2
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
  namespace: ${PNS}
spec:
  clusterIP: None
  selector:
    app: mongodb
  ports:
    - port: 27017
      targetPort: 27017
STS_EOF

  echo "Waiting for StatefulSet rollout in ${PNS}..."
  kubectl --context "$ctx" -n "$PNS" rollout status statefulset/mongodb --timeout=300s

  # An unrelated, non-member Pod in the same namespace (no ownerReference to
  # the StatefulSet) — proves pods/list and pods/delete's membership check is
  # ownerReference-exact, not a namespace-wide dump.
  kubectl --context "$ctx" -n "$PNS" run unrelated \
    --image=busybox:1.36 --restart=Never -- sleep 3600
  kubectl --context "$ctx" -n "$PNS" wait pod unrelated --for=condition=Ready --timeout=60s
}

teardown_file() {
  kubectl --context "kind-cluster-a" delete namespace "mongo-pods" --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

# ---------------------------------------------------------------------------
# Helpers (same pattern as ops.bats / sts_orphan_delete.bats)
# ---------------------------------------------------------------------------

kexec() {
  kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"
}

http_post() {
  local url="$1" body="$2"
  local response
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
  while ((elapsed < max_wait)); do
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
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "Task ${task_id} still not terminal after ${max_wait}s (status: ${status})" >&2
  return 1
}

run_pods_task() {
  local endpoint="$1" body="$2" max_wait="${3:-120}"
  http_post "${AQSH_URL}/tasks/pods%2F${endpoint}" "$body"
  [[ "$HTTP_CODE" == "202" ]] || { echo "submit ${endpoint} got HTTP ${HTTP_CODE}: ${HTTP_BODY}" >&2; return 1; }
  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task_any "$AQSH_URL" "$task_id" "$max_wait" || return 1
  RESULT_DATA=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  export RESULT_DATA
}

# ── pods/list ────────────────────────────────────────────────────────────────

@test "pods/list reports exactly the StatefulSet's member pods" {
  run_pods_task "list" "{\"namespace\":\"${PNS}\"}"
  assert_equal "$TASK_STATUS" "completed"

  assert_equal "$(echo "$RESULT_DATA" | jq -r '.instance')" "mongodb"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.count')" "2"

  local names
  names=$(echo "$RESULT_DATA" | jq -r '.pods[].name' | sort | paste -sd,)
  assert_equal "$names" "mongodb-0,mongodb-1"

  local pod0
  pod0=$(echo "$RESULT_DATA" | jq -c '.pods[] | select(.name == "mongodb-0")')
  assert_equal "$(echo "$pod0" | jq -r '.ordinal')" "0"
  assert_equal "$(echo "$pod0" | jq -r '.phase')" "Running"
  assert_equal "$(echo "$pod0" | jq -r '.ready')" "1/1"
  [[ "$(echo "$pod0" | jq -r '.node')" != "null" ]]
}

@test "pods/list excludes a non-member Pod sharing the namespace" {
  run_pods_task "list" "{\"namespace\":\"${PNS}\"}"
  assert_equal "$TASK_STATUS" "completed"
  local unrelated_count
  unrelated_count=$(echo "$RESULT_DATA" | jq '[.pods[] | select(.name == "unrelated")] | length')
  assert_equal "$unrelated_count" "0"
}

# ── pods/delete gating ───────────────────────────────────────────────────────

@test "pods/delete rejects dry_run=true with confirm=true" {
  run_pods_task "delete" "{\"namespace\":\"${PNS}\",\"target_pod\":\"mongodb-1\",\"dry_run\":\"true\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"
}

@test "pods/delete requires confirm=true when dry_run=false" {
  run_pods_task "delete" "{\"namespace\":\"${PNS}\",\"target_pod\":\"mongodb-1\",\"dry_run\":\"false\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"
}

@test "pods/delete requires pod_uid when dry_run=false" {
  run_pods_task "delete" "{\"namespace\":\"${PNS}\",\"target_pod\":\"mongodb-1\",\"dry_run\":\"false\",\"confirm\":\"true\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"
}

# Note: there is no "dry_run=flase (typo)" test here — the tasks.yaml
# pattern for `dry_run` (`^(true|false)$`) already rejects it at submission
# (HTTP 400, before the script — and its own belt-and-braces literal
# comparison — ever runs), the same "not worth double-testing a format
# guard" call fcv.bats/profiler.bats make for their own pattern-guarded
# inputs. dry_run is safety-critical (an unrecognized value must never be
# silently treated as false and fall through to a real delete), which is
# exactly why it gets a strict enum pattern instead of the free-form
# `type: string` most other boolean-ish inputs use.

@test "pods/delete rejects a target_pod that is not a member of the StatefulSet" {
  run_pods_task "delete" "{\"namespace\":\"${PNS}\",\"target_pod\":\"unrelated\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "POD_NOT_MEMBER"
}

# ── pods/delete execution ────────────────────────────────────────────────────

@test "pods/delete dry_run previews the delete without touching the pod" {
  run_pods_task "delete" "{\"namespace\":\"${PNS}\",\"target_pod\":\"mongodb-1\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "DRY_RUN_READY"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.deleted')" "false"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.force')" "false"
  [[ -n "$(echo "$RESULT_DATA" | jq -r '.pod_uid')" ]]
  [[ "$(echo "$RESULT_DATA" | jq -r '.pod_uid')" != "null" ]]

  kubectl --context "$CTX_A" -n "$PNS" get pod mongodb-1 >/dev/null
}

@test "pods/delete confirmed deletes the pod and the StatefulSet recreates it" {
  run_pods_task "delete" "{\"namespace\":\"${PNS}\",\"target_pod\":\"mongodb-1\"}"
  assert_equal "$TASK_STATUS" "completed"
  local pod_uid
  pod_uid=$(echo "$RESULT_DATA" | jq -r '.pod_uid')
  [[ -n "$pod_uid" && "$pod_uid" != "null" ]]

  run_pods_task "delete" "{\"namespace\":\"${PNS}\",\"target_pod\":\"mongodb-1\",\"dry_run\":\"false\",\"confirm\":\"true\",\"pod_uid\":\"${pod_uid}\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "POD_DELETED"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.deleted')" "true"

  kubectl --context "$CTX_A" -n "$PNS" wait pod mongodb-1 --for=condition=Ready --timeout=180s

  run_pods_task "list" "{\"namespace\":\"${PNS}\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.count')" "2"
}

@test "pods/delete on an already-gone target reports POD_ALREADY_DELETED, not POD_NOT_MEMBER" {
  # Scale down by one so mongodb-1 (the highest ordinal) is deleted by the
  # StatefulSet controller itself and stays gone (not recreated) — the
  # regression this guards against is delete.sh deriving membership from a
  # live-pods list, where an already-gone target simply isn't present and
  # so was misreported POD_NOT_MEMBER instead of the intended idempotent
  # POD_ALREADY_DELETED short-circuit.
  kubectl --context "$CTX_A" -n "$PNS" scale statefulset/mongodb --replicas=1
  kubectl --context "$CTX_A" -n "$PNS" wait pod mongodb-1 --for=delete --timeout=120s

  run_pods_task "delete" "{\"namespace\":\"${PNS}\",\"target_pod\":\"mongodb-1\"}"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "POD_ALREADY_DELETED"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.deleted')" "false"

  kubectl --context "$CTX_A" -n "$PNS" scale statefulset/mongodb --replicas=2
  kubectl --context "$CTX_A" -n "$PNS" wait pod mongodb-1 --for=condition=Ready --timeout=180s
}

@test "pods/delete rejects a confirm whose pod_uid no longer matches a same-name replacement" {
  run_pods_task "delete" "{\"namespace\":\"${PNS}\",\"target_pod\":\"mongodb-1\"}"
  assert_equal "$TASK_STATUS" "completed"
  local stale_uid
  stale_uid=$(echo "$RESULT_DATA" | jq -r '.pod_uid')
  [[ -n "$stale_uid" && "$stale_uid" != "null" ]]

  # Recreate mongodb-1 out from under the dry-run's observation, independent
  # of the task under test, so its live UID no longer matches stale_uid —
  # simulating a retry issued after the StatefulSet already replaced it.
  kubectl --context "$CTX_A" -n "$PNS" delete pod mongodb-1 --wait=true --timeout=60s
  kubectl --context "$CTX_A" -n "$PNS" wait pod mongodb-1 --for=condition=Ready --timeout=180s
  local new_uid
  new_uid=$(kubectl --context "$CTX_A" -n "$PNS" get pod mongodb-1 -o jsonpath='{.metadata.uid}')
  assert_not_equal "$new_uid" "$stale_uid"

  run_pods_task "delete" "{\"namespace\":\"${PNS}\",\"target_pod\":\"mongodb-1\",\"dry_run\":\"false\",\"confirm\":\"true\",\"pod_uid\":\"${stale_uid}\"}"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "POD_REPLACED"

  # The replacement Pod must survive the rejected delete untouched.
  local after_uid
  after_uid=$(kubectl --context "$CTX_A" -n "$PNS" get pod mongodb-1 -o jsonpath='{.metadata.uid}')
  assert_equal "$after_uid" "$new_uid"
}
