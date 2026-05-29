setup_file() {
  load 'test_helper'
  mongodb_suite_setup --create-token
}

setup() {
  load 'test_helper'
}

@test "restart task completes successfully" {
  http_post "${MONGODB_AQSH_URL}/tasks/restart" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"
}

@test "restart advances StatefulSet generation and all replicas ready" {
  local before_generation
  before_generation=$(kubectl --context kind-cluster-a -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.status.observedGeneration}')

  http_post "${MONGODB_AQSH_URL}/tasks/restart" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  kubectl --context kind-cluster-a -n mongo-1 wait pod \
    -l app=mongodb \
    --for=condition=Ready --timeout=120s >/dev/null 2>&1

  local after_generation ready replicas
  after_generation=$(kubectl --context kind-cluster-a -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.status.observedGeneration}')
  ready=$(kubectl --context kind-cluster-a -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.status.readyReplicas}')
  replicas=$(kubectl --context kind-cluster-a -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.status.replicas}')

  echo "generation: ${before_generation} → ${after_generation}, ready: ${ready}/${replicas}"
  assert [ "$after_generation" -gt "$before_generation" ]
  assert_equal "$ready" "$replicas"
  assert [ "$ready" != "0" ]
}
