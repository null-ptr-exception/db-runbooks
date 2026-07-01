#!/usr/bin/env bats
# =============================================================================
# E2E proof that k8s_sts_restart's OnDelete branch (aqsh-tasks/lib/k8s.sh)
# correctly detects updateStrategy=OnDelete and waits for a real pod cycle,
# rather than trivially reporting success without anything actually
# restarting.
#
# For updateStrategy=OnDelete, `kubectl rollout restart statefulset` only
# bumps the pod template's restartedAt annotation — the vanilla StatefulSet
# controller does NOT proactively delete/recreate pods under OnDelete (that's
# the point of the strategy: an operator or human decides when to cycle each
# pod). Nothing in k8s_sts_restart itself deletes a pod, and its first
# `kubectl wait --for=condition=Ready=False` is wrapped in `|| true` (a timeout
# there is silently swallowed). So a naive test that just calls restart
# against an OnDelete StatefulSet with no operator present would report
# success even though nothing was recreated — this test closes that gap by
# playing the role of the operator: deleting the pod mid-flight so the real
# NotReady -> Ready wait path executes, then asserting the pod's UID changed.
#
# mongodb.bats already covers the RollingUpdate path against mongo-1; this
# file deploys a SEPARATE 1-replica StatefulSet in its own "mongo-ondelete"
# namespace via the shared test chart with mongodb.updateStrategy=OnDelete
# (tests/chart/templates/mongodb.yaml), so it doesn't touch or race with
# mongo-1's fixture. Reuses the "mongodb" StatefulSet/Secret names, so the
# existing aqsh-mongo-manager ClusterRole's resourceNames already cover it —
# only a namespace-scoped RoleBinding is added, no ClusterRole change (same
# pattern as recovery_bitnami_profile.bats).
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  ONS="mongo-ondelete"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"
  CHART_DIR="$(cd "${BATS_TEST_DIRNAME}/../chart" && pwd)"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=1h)
  export CTX_A CTX_B NS ONS AQSH_URL TEST_POD TOKEN

  local ctx="$CTX_A"

  kubectl --context "$ctx" create namespace "$ONS" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  # Grant aqsh's SA the same ClusterRole within mongo-ondelete. RoleBinding
  # only — no ClusterRole change, since resourceNames match "mongodb" /
  # "mongodb-credentials" regardless of namespace.
  kubectl --context "$ctx" -n "$ONS" apply -f - <<'RB_EOF'
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

  helm template mongo-ondelete "$CHART_DIR" \
    --set mongodb.enabled=true \
    --set mongodb.namespace="$ONS" \
    --set mongodb.updateStrategy=OnDelete \
    | kubectl --context "$ctx" -n "$ONS" apply -f -

  # kubectl rollout status doesn't support OnDelete strategy StatefulSets
  # ("rollout status is only available for RollingUpdate strategy type") —
  # wait on pod readiness directly instead, the same way k8s_sts_restart's
  # own OnDelete branch does.
  kubectl --context "$ctx" -n "$ONS" wait pod \
    -l app=mongodb --for=condition=Ready --timeout=180s
}

teardown_file() {
  kubectl --context "kind-cluster-a" delete namespace "mongo-ondelete" --ignore-not-found 2>/dev/null || true
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

@test "restart exercises the OnDelete branch: waits for an operator-driven pod cycle" {
  local pod before_uid
  pod=$(kubectl --context "$CTX_A" -n "$ONS" get pod -l app=mongodb \
    -o jsonpath='{.items[0].metadata.name}')
  kubectl --context "$CTX_A" -n "$ONS" wait pod "$pod" --for=condition=Ready --timeout=120s
  before_uid=$(kubectl --context "$CTX_A" -n "$ONS" get pod "$pod" -o jsonpath='{.metadata.uid}')

  http_post "${AQSH_URL}/tasks/restart" "{\"namespace\": \"${ONS}\"}"
  assert_equal "$HTTP_CODE" "202"
  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')

  # Simulate the operator/human action OnDelete strategy requires: the
  # StatefulSet controller will not evict/recreate this pod on its own after
  # `kubectl rollout restart` bumps the template annotation — something else
  # has to delete it. A short sleep lets the queued task's own
  # `kubectl rollout restart statefulset` call land first.
  sleep 5
  kubectl --context "$CTX_A" -n "$ONS" delete pod "$pod" --wait=false

  wait_for_task "$AQSH_URL" "$task_id" 180

  local result strategy ready replicas after_uid
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  strategy=$(echo "$result" | jq -r '.strategy')
  ready=$(echo "$result" | jq -r '.ready')
  replicas=$(echo "$result" | jq -r '.replicas')
  assert_equal "$strategy" "OnDelete"
  assert_equal "$ready" "$replicas"

  after_uid=$(kubectl --context "$CTX_A" -n "$ONS" get pod "$pod" -o jsonpath='{.metadata.uid}')
  [ "$before_uid" != "$after_uid" ]
}
