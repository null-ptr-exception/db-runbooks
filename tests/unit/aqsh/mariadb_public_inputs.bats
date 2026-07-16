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
    in_task && /^  [A-Za-z0-9_-]+:$/ { exit }
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
}
