#!/usr/bin/env bats

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
}

@test "registry is reachable on localhost:5005" {
  run curl -sf http://localhost:5005/v2/_catalog
  assert_success
}

@test "cross-cluster: cluster-a curl reaches cluster-b nginx via nginx.kind-b.test" {
  local pod
  pod=$(kubectl --context "$CTX_A" -n infra-a get pod -l app=curl -o jsonpath='{.items[0].metadata.name}')
  run kubectl --context "$CTX_A" -n infra-a exec "$pod" -- \
    curl -sf -o /dev/null -w '%{http_code}' http://nginx.kind-b.test:30080
  assert_success
  assert_output "200"
}

@test "cross-cluster: cluster-b curl reaches cluster-a nginx via nginx.kind-a.test" {
  local pod
  pod=$(kubectl --context "$CTX_B" -n infra-b get pod -l app=curl -o jsonpath='{.items[0].metadata.name}')
  run kubectl --context "$CTX_B" -n infra-b exec "$pod" -- \
    curl -sf -o /dev/null -w '%{http_code}' http://nginx.kind-a.test:30080
  assert_success
  assert_output "200"
}
