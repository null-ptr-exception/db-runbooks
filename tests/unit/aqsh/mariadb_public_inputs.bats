#!/usr/bin/env bats

setup_file() {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
  TASKS_FILE="${REPO_ROOT}/aqsh-tasks/tasks-mariadb.yaml"
  export TASKS_FILE
}

# Print the input names for one top-level task in their declared order. This is
# intentionally a small structural parser: task keys use two-space indentation,
# `input` uses four spaces, and input entries use six spaces in the AQSH config.
task_inputs() {
  awk -v wanted="$1" '
    $0 == "  " wanted ":" { in_task=1; in_input=0; next }
    # Task keys may contain a slash (blue-green/create, replication/attach), so
    # the next-task boundary must match those too — otherwise a slashed task
    # silently absorbs the inputs of every task declared after it.
    in_task && /^  [A-Za-z0-9_\/-]+:$/ { exit }
    in_task && /^    input:$/ { in_input=1; next }
    in_task && in_input && /^      - name: / {
      sub(/^      - name: /, "")
      print
    }
  ' "${TASKS_FILE}"
}

@test "snapshot tasks expose only user decisions as public inputs" {
  run task_inputs backup
  [ "$status" -eq 0 ]
  [ "$output" = "namespace" ]

  run task_inputs physical-backup
  [ "$status" -eq 0 ]
  [ "$output" = $'namespace\ndry_run\nwait_timeout\nconfirm' ]

  run task_inputs logical-backup
  [ "$status" -eq 0 ]
  [ "$output" = $'namespace\ndry_run\nwait_timeout\nconfirm' ]

  run task_inputs list-backups
  [ "$status" -eq 0 ]
  [ "$output" = "namespace" ]

  run task_inputs delete-backup
  [ "$status" -eq 0 ]
  [ "$output" = $'namespace\nbackup\ndry_run\nconfirm' ]

  run task_inputs restore
  [ "$status" -eq 0 ]
  [ "$output" = $'namespace\ntarget_time\ndry_run\nwait_timeout\nconfirm' ]

  run task_inputs logical-restore
  [ "$status" -eq 0 ]
  [ "$output" = $'namespace\nbackup\ndry_run\nwait_timeout\nconfirm' ]
}

@test "cross-cluster replication tasks expose only user decisions as public inputs" {
  # The peer address is derived from the namespace via the mesh Service naming
  # convention, and the connection-guard policy is deploy-time config. Neither
  # may drift into the public API: a caller-supplied peer host would let an
  # authenticated call point replication at an arbitrary endpoint.
  run task_inputs "replication/attach"
  [ "$status" -eq 0 ]
  [ "$output" = $'namespace\ndry_run\nconfirm\nwait_timeout\nexpected_action' ]

  # rebuild is the one task that needs the peer's AQSH: only the primary's
  # cluster can back its own database up. The token is per-call by nature; the
  # address is deploy-time config that stays optional here so a deployment
  # without it set is still operable.
  run task_inputs "replication/rebuild"
  [ "$status" -eq 0 ]
  [ "$output" = $'namespace\ndry_run\nconfirm\nwait_timeout\npeer_token\npeer_aqsh_url' ]

  run task_inputs "replication/status"
  [ "$status" -eq 0 ]
  [ "$output" = $'namespace\ninclude_peer' ]

  run task_inputs "replication/detach"
  [ "$status" -eq 0 ]
  [ "$output" = $'namespace\ndry_run\nconfirm' ]
}
