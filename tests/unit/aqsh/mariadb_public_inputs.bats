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

# Check the actual E2E request against the declared API, without starting Kind.
assert_legacy_blue_green_payload() {
  local task="$1" expression payload unknown
  expression="$(python3 - "$BATS_TEST_DIRNAME/../../mariadb-legacy/replication_link.bats" "$task" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r'submit_allow_failure "' + re.escape(sys.argv[2])
                  + r'".*?\n\s*\'([^\n]+)\'\)"', source, re.S)
if not match:
    raise SystemExit("Cannot locate the literal E2E payload for " + sys.argv[2])
print(match.group(1))
PY
)" || return 1
  payload="$(jq -nc --arg ns mariadb-1 --arg peer http://peer "$expression")" || return 1
  unknown="$(jq -nr --argjson payload "$payload" --arg allowed "$(task_inputs "$task")" \
    '($payload | keys) - ($allowed | split("\n")) | join(",")')" || return 1
  [[ -z "$unknown" ]] || { echo "$task E2E sends undeclared inputs: $unknown" >&2; return 1; }
}

@test "legacy blue-green create E2E payload matches the public API" {
  assert_legacy_blue_green_payload blue-green/create
}

@test "legacy blue-green switchover E2E payload matches the public API" {
  assert_legacy_blue_green_payload blue-green/switchover
}

@test "snapshot tasks expose only user decisions as public inputs" {
  run task_inputs backup
  [ "$status" -eq 0 ]
  [ "$output" = "namespace" ]

  run task_inputs physical-backup
  [ "$status" -eq 0 ]
  # target is a deliberate user decision (Primary/Replica/PreferReplica); attach
  # rebuild passes Primary so the standby is not seeded from replica slave state.
  [ "$output" = $'namespace\ndry_run\nwait_timeout\nconfirm\ntarget' ]

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

  run task_inputs restore-in-place
  [ "$status" -eq 0 ]
  [ "$output" = $'namespace\nbackup\ndry_run\nconfirm' ]

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
  [ "$output" = $'namespace\ndry_run\nconfirm\nexpected_action' ]

  # Re-seeding is not a replication/rebuild endpoint: attach owns that decision
  # and uses the shared restore-in-place primitive internally.
  run task_inputs "replication/rebuild"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run task_inputs "replication/status"
  [ "$status" -eq 0 ]
  [ "$output" = $'namespace\ninclude_peer' ]

  run task_inputs "replication/detach"
  [ "$status" -eq 0 ]
  [ "$output" = $'namespace\ndry_run\nconfirm' ]
}
