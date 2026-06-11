#!/usr/bin/env bats

setup_file() {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
  export REPO_ROOT
}

@test "mariadb namespace inputs do not require mariadb-number names" {
  run grep -nF "pattern: '^mariadb-[0-9]+$'" \
    "${REPO_ROOT}/aqsh-tasks/tasks-mariadb.yaml"
  [ "$status" -ne 0 ]
}
