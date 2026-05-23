#!/usr/bin/env bats

load helpers.bash

setup() {
  setup_env
  require_multi_mode
}

@test "region-a mariadb-1 primary and region-b mariadb-1 replica are healthy" {
  run bash -ceu '
    kubectl --context kind-cluster-region-a -n mariadb-1 exec mariadb-0 -- \
      mariadb -N -e "SHOW MASTER STATUS\\G" | grep -q "File:"
  '
  assert_success

  run bash -ceu '
    kubectl --context kind-cluster-region-b -n mariadb-1 exec mariadb-0 -- \
      mariadb -N -e "SHOW SLAVE STATUS\\G" | grep -q "Slave_IO_Running: Yes"
  '
  assert_success
}

@test "mariadb cross-region replication syncs writes and lag stays below 30s" {
  run bash -ceu '
    ROOT_PASS=$(kubectl --context kind-cluster-region-a -n mariadb-1 get secret mariadb -o jsonpath="{.data.password}" | base64 -d)
    kubectl --context kind-cluster-region-a -n mariadb-1 exec mariadb-0 -- \
      mariadb -uroot -p"${ROOT_PASS}" -e "CREATE DATABASE IF NOT EXISTS cross_region_test; CREATE TABLE IF NOT EXISTS cross_region_test.replication_probe (id INT PRIMARY KEY, note VARCHAR(64)); REPLACE INTO cross_region_test.replication_probe (id,note) VALUES (1,'ok');"
  '
  assert_success

  run wait_for_replication '
    ROOT_PASS_B=$(kubectl --context kind-cluster-region-b -n mariadb-1 get secret mariadb -o jsonpath="{.data.password}" | base64 -d)
    VALUE=$(kubectl --context kind-cluster-region-b -n mariadb-1 exec mariadb-0 -- mariadb -N -uroot -p"${ROOT_PASS_B}" -e "SELECT note FROM cross_region_test.replication_probe WHERE id=1;" 2>/dev/null | tr -d "\\r")
    [ "$VALUE" = "ok" ]
  '
  assert_success

  run bash -ceu '
    kubectl --context kind-cluster-region-b -n mariadb-1 exec mariadb-0 -- \
      mariadb -N -e "SHOW SLAVE STATUS\\G" | awk -F": " "/Seconds_Behind_Master/ {print \$2; exit}"
  '
  assert_success
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -lt 30 ]
}
