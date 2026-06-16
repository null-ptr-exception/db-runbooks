#!/usr/bin/env bats
#
# Blue-green deployment tests require aqsh on both clusters with
# cross-cluster communication via Istio gateway.
# TODO: port to 2-cluster pattern with dual aqsh helmfile releases.

setup_file() {
  skip "blue-green tests not yet ported to 2-cluster pattern"
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

@test "blue-green status task reads Blue multiCluster state" {
  skip "not yet ported"
}

@test "blue-green create requires confirm" {
  skip "not yet ported"
}

@test "blue-green switchover guardrails block before mutating anything" {
  skip "not yet ported"
}

@test "blue-green delete requires confirm" {
  skip "not yet ported"
}
