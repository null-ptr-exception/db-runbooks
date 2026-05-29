setup_file() {
  load 'test_helper'
  mongodb_suite_setup --create-token

  MONGO_POD_A=$(kubectl --context "$CTX_A" -n mongo-1 \
    get pod -l app=mongodb -o jsonpath='{.items[0].metadata.name}')
  MONGO_POD_B=$(kubectl --context "$CTX_B" -n mongo-2 \
    get pod -l app=mongodb -o jsonpath='{.items[0].metadata.name}')
  export MONGO_POD_A MONGO_POD_B
}

setup() {
  load 'test_helper'
}

mongosh_a() {
  kubectl --context "$CTX_A" -n mongo-1 exec "$MONGO_POD_A" -- \
    mongosh --quiet --norc --eval "$1"
}

mongosh_b() {
  kubectl --context "$CTX_B" -n mongo-2 exec "$MONGO_POD_B" -- \
    mongosh --quiet --norc --eval "$1"
}

@test "aqsh-mongodb on cluster-a is reachable" {
  http_post "${MONGODB_AQSH_URL}/tasks/common%2Fhello" '{"name": "replication-test-a"}'
  assert_equal "$HTTP_CODE" "202"
}

@test "cross-cluster TCP: mongo-1 on cluster-a connects to mongo-2 on cluster-b via Istio Gateway" {
  run mongosh_a "try { new Mongo('mongodb.kind-b.test:30090'); print('connected') } catch(e) { print('failed: ' + e.message) }"
  assert_output --partial "connected"
}

@test "cross-cluster TCP: mongo-2 on cluster-b connects to mongo-1 on cluster-a via Istio Gateway" {
  run mongosh_b "try { new Mongo('mongodb.kind-a.test:30090'); print('connected') } catch(e) { print('failed: ' + e.message) }"
  assert_output --partial "connected"
}

@test "restart task completes on cluster-a (mongo-1)" {
  http_post "${MONGODB_AQSH_URL}/tasks/restart" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"
}
