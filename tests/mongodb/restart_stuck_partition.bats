#!/usr/bin/env bats
# =============================================================================
# E2E proof that k8s_sts_restart auto-detects and unlocks a stuck
# rollingUpdate.partition before restarting.
#
# MongoDB recovery/reset (aqsh-tasks/lib/mongodb-recovery.sh) deliberately
# leaves rollingUpdate.partition set to the replica count as a StatefulSet's
# normal resting state once recovery tooling is installed on it - that
# blocks *any* pod from rolling, including a later plain `restart` call:
# `kubectl rollout status` considers a partitioned rollout complete once
# updatedReplicas >= replicas-partition, which is already true (>= 0) when
# partition >= replicas, so restart previously reported success ("Done:
# N/N ready") without a single pod actually being recreated.
#
# This deploys a SEPARATE 1-replica StatefulSet in its own
# "mongo-stuck-partition" namespace (RollingUpdate strategy, the default),
# manually patches partition to the replica count to simulate the locked
# resting state, then calls restart and asserts: the response reports
# partition_reset=true, the live partition is back to 0 afterward, and the
# pod was actually recreated (uid changed) - proving the unlock+restart
# happened for real, not just a partition patch with no rollout.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  PNS="mongo-stuck-partition"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"
  CHART_DIR="$(cd "${BATS_TEST_DIRNAME}/../chart" && pwd)"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=1h)
  export CTX_A CTX_B NS PNS AQSH_URL TEST_POD TOKEN

  local ctx="$CTX_A"

  kubectl --context "$ctx" create namespace "$PNS" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  # Grant aqsh's SA the same ClusterRole within mongo-stuck-partition.
  # RoleBinding only — no ClusterRole change, since resourceNames match
  # "mongodb" / "mongodb-credentials" regardless of namespace.
  kubectl --context "$ctx" -n "$PNS" apply -f - <<'RB_EOF'
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

  helm template mongo-stuck-partition "$CHART_DIR" \
    --set mongodb.enabled=true \
    --set mongodb.namespace="$PNS" \
    | kubectl --context "$ctx" -n "$PNS" apply -f -

  kubectl --context "$ctx" -n "$PNS" rollout status statefulset/mongodb --timeout=180s
}

teardown_file() {
  kubectl --context "kind-cluster-a" delete namespace "mongo-stuck-partition" --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

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

wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-300}"
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE

    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && { echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2; return 1; }

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Task ${task_id} timed out after ${max_wait}s" >&2
  return 1
}

@test "restart auto-unlocks a partition stuck at the replica count and actually restarts" {
  local pod before_uid
  pod=$(kubectl --context "$CTX_A" -n "$PNS" get pod -l app=mongodb \
    -o jsonpath='{.items[0].metadata.name}')
  kubectl --context "$CTX_A" -n "$PNS" wait pod "$pod" --for=condition=Ready --timeout=120s
  before_uid=$(kubectl --context "$CTX_A" -n "$PNS" get pod "$pod" -o jsonpath='{.metadata.uid}')

  # Simulate the locked resting state MongoDB recovery/reset leaves behind:
  # partition == replica count (1), which blocks every pod from rolling.
  kubectl --context "$CTX_A" -n "$PNS" patch statefulset mongodb --type=merge \
    -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":1}}}}'

  http_post "${AQSH_URL}/tasks/restart" "{\"namespace\": \"${PNS}\"}"
  assert_equal "$HTTP_CODE" "202"
  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')

  wait_for_task "$AQSH_URL" "$task_id" 180

  local result strategy partition_reset ready replicas after_uid live_partition
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  strategy=$(echo "$result" | jq -r '.strategy')
  partition_reset=$(echo "$result" | jq -r '.partition_reset')
  ready=$(echo "$result" | jq -r '.ready')
  replicas=$(echo "$result" | jq -r '.replicas')
  assert_equal "$strategy" "RollingUpdate"
  assert_equal "$partition_reset" "true"
  assert_equal "$ready" "$replicas"

  live_partition=$(kubectl --context "$CTX_A" -n "$PNS" get statefulset mongodb \
    -o jsonpath='{.spec.updateStrategy.rollingUpdate.partition}')
  assert_equal "$live_partition" "0"

  after_uid=$(kubectl --context "$CTX_A" -n "$PNS" get pod "$pod" -o jsonpath='{.metadata.uid}')
  [ "$before_uid" != "$after_uid" ]
}
