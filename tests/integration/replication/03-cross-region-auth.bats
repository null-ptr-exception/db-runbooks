#!/usr/bin/env bats

load helpers.bash

setup() {
  setup_env
  require_multi_mode
}

@test "region-b mariadb endpoint accepts token from cluster-apps-minio" {
  run kubectl --context kind-cluster-apps-minio -n app-a create token test-client --duration=10m
  assert_success
  TOKEN="$output"

  run retry_curl "http://${REGION_B_IP}:30080/mariadb/health" "200" "$TOKEN"
  assert_success
}

@test "region-b mongodb endpoint accepts token from cluster-apps-minio" {
  run kubectl --context kind-cluster-apps-minio -n app-a create token test-client --duration=10m
  assert_success
  TOKEN="$output"

  run retry_curl "http://${REGION_B_IP}:30080/mongodb/health" "200" "$TOKEN"
  assert_success
}
