#!/usr/bin/env bats
#
# Replication tests require MariaDB + aqsh on both clusters.
# TODO: port to 2-cluster pattern with dual aqsh + mariadb helmfile releases
#       and Istio gateway for cross-cluster mariadb connectivity.

setup_file() {
  skip "replication tests not yet ported to 2-cluster pattern"
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

@test "mariadb aqsh on cluster-a is reachable" {
  skip "not yet ported"
}

@test "mariadb aqsh on cluster-b is reachable" {
  skip "not yet ported"
}

@test "cross-cluster mariadb connectivity via gateway" {
  skip "not yet ported"
}

@test "restart task completes on cluster-a" {
  skip "not yet ported"
}

@test "restart task completes on cluster-b" {
  skip "not yet ported"
}
