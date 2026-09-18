#!/usr/bin/env bats
#
# mariadb-operator 0.24 cross-cluster replication e2e. This suite has no
# ExternalMariaDB or multiCluster API; the cross-cluster link is native SQL.
#
# One scenario owns the full lifecycle. Individual runbook steps are ordinary
# functions, not Bats tests that accidentally depend on earlier tests/files.
# Run this file alone via scripts/local-e2e/run.sh for a fresh daemon/fixture.
# Budget roughly 15 minutes for the physical backup and in-place restore.

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="db-ops"
  DB_NS="mariadb-1"
  AQSH_A_URL="http://aqsh-mariadb.kind-a.test:30080"
  AQSH_B_URL="http://aqsh-mariadb.kind-b.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=60m)

  # Never delete another file's restore target to make autodetection pass.
  # Each file owns its cleanup; a dirty fixture is a visible setup failure.
  local instances
  instances="$(kubectl --context "$CTX_A" -n "$DB_NS" get mariadb -o json)"
  [[ "$(jq -r '[.items[].metadata.name] | sort | join(",")' <<<"$instances")" == mariadb ]] || {
    echo 'replication requires a fresh single-instance primary fixture' >&2
    return 1
  }

  export CTX_A CTX_B NS DB_NS AQSH_A_URL AQSH_B_URL TEST_POD TOKEN
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

kexec() {
  kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"
}

http_post() {
  local url="$1" body="$2" response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\\n%{http_code}' \
    -X POST '${url}' \
    -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Content-Type: application/json' \
    -d '${body}'")
  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-540}"
  local deadline=$(( $(date +%s) + max_wait )) status

  while (( $(date +%s) < deadline )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE
    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && return 1
    sleep 5
  done
  echo "task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 2
}

# aqsh wraps the script's stdout in result.data as a STRING, and that string is
# itself the response envelope ({status, operation, message, data, reason}).
# The task's own payload is one level further in, at .data — the same two-step
# unwrap bg_peer_call_task does.
_task_envelope() {
  echo "$TASK_RESPONSE" | jq -c '
    .result.data as $raw
    | (($raw | if type == "string" then (try fromjson catch null) else . end) // .result // {})
  '
}

_task_result_data() {
  _task_envelope | jq -c '.data // .'
}

_task_result_reason() {
  _task_envelope | jq -r '.reason // ""'
}

# run_task <url> <task> <payload> [timeout] -> sets TASK_RESPONSE; returns the task rc
run_task() {
  local url="$1" task="${2//\//%2F}" payload="$3" timeout="${4:-540}" task_id
  TASK_RESPONSE=""
  http_post "${url}/tasks/${task}" "$payload"
  [[ "$HTTP_CODE" == "202" ]] || { echo "submit failed: $HTTP_CODE $HTTP_BODY" >&2; return 3; }
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]] || { echo "no task id: $HTTP_BODY" >&2; return 3; }
  wait_for_task "$url" "$task_id" "$timeout"
}

# These wrap run_task rather than using assert_success/assert_failure, because
# those read $status/$output — which only exist after bats' own `run`, and
# `run` would put TASK_RESPONSE in a subshell where the assertions cannot see
# it. They also print the task response on failure, so a red test says why.

# submit_task <task> <url> <payload> [timeout]
submit_task() {
  local task="$1" url="$2" rc=0
  shift 2
  run_task "$url" "$task" "$@" || rc=$?
  if (( rc != 0 )); then
    echo "expected the task to succeed (rc=${rc}); response: ${TASK_RESPONSE}" >&2
    return 1
  fi
}

# submit_allow_failure <task> <url> <payload>
submit_allow_failure() {
  local task="$1" url="$2"
  shift 2
  if run_task "$url" "$task" "$@"; then
    echo "expected $task to fail, but it succeeded" >&2
    return 1
  fi
}

# expect_task_reason <reason> <url> <task> <payload> [timeout]
# Asserts the task FAILED with a specific public reason code.
expect_task_reason() {
  local want="$1" got rc=0
  shift
  run_task "$@" || rc=$?
  if (( rc == 0 )); then
    echo "expected the task to fail with ${want}, but it succeeded; response: ${TASK_RESPONSE}" >&2
    return 1
  fi
  got="$(_task_result_reason)"
  if [[ "$got" != "$want" ]]; then
    echo "expected reason ${want}, got '${got}'; response: ${TASK_RESPONSE}" >&2
    return 1
  fi
}

# --- mesh stand-in ------------------------------------------------------------

db_sql() {
  local ctx="$1" query="$2"
  kubectl --context "$ctx" -n "$DB_NS" exec mariadb-0 -c mariadb -- \
    sh -c 'export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"; exec mariadb -u root -N -B -e "$1"' sh "$query"
}

wait_for_marker_rows() {
  local expected="$1" actual="" deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    if actual="$(db_sql "$CTX_B" 'SELECT COUNT(*) FROM replication_e2e.marker')"; then
      [[ "$actual" == "$expected" ]] && return 0
    fi
    sleep 2
  done
  echo "replicated row count: expected=$expected actual=$actual" >&2
  return 1
}

@test "v24 cross-cluster replication lifecycle preserves CR and PVC identity" {
  local data
  echo "mesh services exist with the derived names on both clusters" >&3
  # The task derives <namespace>-rw; if the chart named it anything else the
  # rest of this file would be testing a fiction.
  run kubectl --context "$CTX_B" -n "$DB_NS" get svc "${DB_NS}-rw" -o jsonpath='{.spec.type}'
  assert_success
  assert_output "ExternalName"

  run kubectl --context "$CTX_A" -n "$DB_NS" get svc "${DB_NS}-rw" -o jsonpath='{.spec.type}'
  assert_success
  assert_output "ExternalName"

  echo "standby can reach the primary through the mesh stand-in" >&3
  # Proves the data path before any task depends on it: a failure here is
  # infrastructure, not task logic.
  local host="${DB_NS}-rw"
  run kubectl --context "$CTX_B" -n "$DB_NS" exec mariadb-0 -c mariadb -- \
    sh -c "mariadb -h ${host} -P 30091 --connect-timeout=10 -u root -p\"\$MARIADB_ROOT_PASSWORD\" -N -B -e 'SELECT 1' 2>&1"
  assert_success
  assert_output --partial "1"

  echo "status reports the standby as unlinked before any attach" >&3
  submit_task "replication/status" "$AQSH_B_URL" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns}')"

  data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.local.replicationConfigured')" "false"
  assert_equal "$(echo "$data" | jq -r '.local.linkRunning')" "false"

  echo "status can reach the peer through the mesh stand-in" >&3
  # Guards the deploy-time config path end to end: if REPL_PEER_PORT_DEFAULT is
  # not actually reaching the scripts, the peer probe fails and this is the
  # first place it shows.
  submit_task "replication/status" "$AQSH_B_URL" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns}')"

  data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.peer.probed')" "true"
  assert_equal "$(echo "$data" | jq -r '.peer.reachable')" "true"

  echo "attach dry run assesses a fresh standby as needing a rebuild" >&3
  # B has a persistent, deployment-owned server_id but no replication history.
  submit_task "replication/attach" "$AQSH_B_URL" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns}')"

  data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.action')" "rebuild"
  assert_equal "$(echo "$data" | jq -r '.actionReason')" "NO_REPLICATION_HISTORY"
  assert_equal "$(echo "$data" | jq -r '.checks.server_ids_distinct')" "true"
  assert_equal "$(echo "$data" | jq -r '.changed')" "false"

  echo "attach honours expected_action" >&3
  expect_task_reason "UNEXPECTED_ACTION" "$AQSH_B_URL" "replication/attach" \
    "$(jq -nc --arg ns "$DB_NS" \
      '{namespace: $ns, dry_run: "false", confirm: "true", expected_action: "attach"}')"

  echo "attach requires confirm" >&3
  expect_task_reason "INVALID_REQUEST" "$AQSH_B_URL" "replication/attach" \
    "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns, dry_run: "false"}')"

  echo "attach requires confirm before the re-seed path" >&3
  expect_task_reason "INVALID_REQUEST" "$AQSH_B_URL" "replication/attach" \
    "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns, dry_run: "false"}')"

  db_sql "$CTX_A" 'CREATE DATABASE replication_e2e;
    CREATE TABLE replication_e2e.marker (id INT PRIMARY KEY);
    INSERT INTO replication_e2e.marker VALUES (1);'
  echo "attach re-seeds the standby and establishes replication" >&3
  # SLOW: physical backup on cluster-a, then one-shot init restore + two Pod
  # replacements + link on cluster-b. One call — the caller does not switch
  # endpoints on the verdict.
  #
  # The identities are captured first: an in-place re-seed must not replace the
  # MariaDB CR or its PVCs, and comparing UIDs is the one check that cannot be
  # satisfied by a delete-and-recreate that merely looks similar.
  local cr_before pvc_before pod_before
  cr_before="$(kubectl --context "$CTX_B" -n "$DB_NS" get mariadb mariadb -o jsonpath='{.metadata.uid}')"
  pvc_before="$(kubectl --context "$CTX_B" -n "$DB_NS" get pvc storage-mariadb-0 -o jsonpath='{.metadata.uid}')"
  pod_before="$(kubectl --context "$CTX_B" -n "$DB_NS" get pod mariadb-0 -o jsonpath='{.metadata.uid}')"
  [ -n "$cr_before" ] && [ -n "$pvc_before" ] && [ -n "$pod_before" ]

  submit_task "replication/attach" "$AQSH_B_URL" \
    "$(jq -nc --arg ns "$DB_NS" \
      '{namespace: $ns, dry_run: "false", confirm: "true"}')" \
    1800

  data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.changed')" "true"
  assert_equal "$(echo "$data" | jq -r '.stage')" "attached"

  run kubectl --context "$CTX_B" -n "$DB_NS" get mariadb mariadb -o jsonpath='{.metadata.uid}'
  assert_output "$cr_before"
  run kubectl --context "$CTX_B" -n "$DB_NS" get pvc storage-mariadb-0 -o jsonpath='{.metadata.uid}'
  assert_output "$pvc_before"
  run kubectl --context "$CTX_B" -n "$DB_NS" get pod mariadb-0 -o jsonpath='{.metadata.uid}'
  assert_success
  refute_output "$pod_before"
  run kubectl --context "$CTX_B" -n "$DB_NS" get mariadb mariadb -o jsonpath='{.spec.initContainers}'
  assert_success
  assert_output ""
  run kubectl --context "$CTX_B" -n "$DB_NS" get statefulset mariadb \
    -o jsonpath='{.spec.updateStrategy.type}'
  assert_success
  assert_output "RollingUpdate"

  echo "status reports a running link after the rebuild" >&3
  submit_task "replication/status" "$AQSH_B_URL" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns}')"

  data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.local.replicationConfigured')" "true"
  assert_equal "$(echo "$data" | jq -r '.local.linkRunning')" "true"
  assert_equal "$(echo "$data" | jq -r '.local.sourceMatchesPeer')" "true"
  assert_equal "$(echo "$data" | jq -r '.local.sourceHost')" \
    "${DB_NS}-rw"

  run kubectl --context "$CTX_B" -n "$DB_NS" get mariadb mariadb \
    -o jsonpath='{.spec.multiCluster}'
  assert_success
  assert_output ""

  echo "attach on an already-linked standby is a successful no-op" >&3
  # Re-running the step must not fail because the end state already holds, and
  # must not re-derive an assessment: local maintenance writes can carry the
  # standby's server_id, so a healthy linked standby may otherwise look
  # divergent and be condemned to a rebuild.
  submit_task "replication/attach" "$AQSH_B_URL" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns}')"

  data="$(_task_result_data)"
  if [[ "$(echo "$data" | jq -r '.actionReason')" != "ALREADY_ATTACHED" ]]; then
    echo "idempotent attach diagnostics: $(echo "$data" | jq -c \
      '{actionReason,checks,replication}')" >&3
  fi
  assert_equal "$(echo "$data" | jq -r '.actionReason')" "ALREADY_ATTACHED"
  assert_equal "$(echo "$data" | jq -r '.changed')" "false"

  echo "backup data and subsequent writes reach the standby" >&3
  wait_for_marker_rows 1
  db_sql "$CTX_A" 'INSERT INTO replication_e2e.marker VALUES (2);'
  wait_for_marker_rows 2

  echo "standby restart preserves server_id and replication" >&3
  run db_sql "$CTX_B" 'SELECT @@server_id'
  assert_success
  assert_output 100
  kubectl --context "$CTX_B" -n "$DB_NS" delete pod mariadb-0 --wait=true
  kubectl --context "$CTX_B" -n "$DB_NS" wait --for=create pod/mariadb-0 --timeout=60s
  kubectl --context "$CTX_B" -n "$DB_NS" wait pod mariadb-0 --for=condition=Ready --timeout=300s
  run db_sql "$CTX_B" 'SELECT @@server_id'
  assert_success
  assert_output 100
  db_sql "$CTX_A" 'INSERT INTO replication_e2e.marker VALUES (3);'
  wait_for_marker_rows 3
  submit_task "replication/status" "$AQSH_B_URL" "$(jq -nc --arg ns "$DB_NS" '{namespace:$ns}')"
  assert_equal "$(_task_result_data | jq -r '.local.linkRunning')" true

  echo "detach dry run leaves the link in place" >&3
  submit_task "replication/detach" "$AQSH_B_URL" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns}')"
  assert_equal "$(_task_result_data | jq -r '.changed')" "false"

  submit_task "replication/status" "$AQSH_B_URL" \
    "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns, include_peer: "false"}')"
  assert_equal "$(_task_result_data | jq -r '.local.linkRunning')" "true"

  echo "detach removes only the SQL link" >&3
  submit_task "replication/detach" "$AQSH_B_URL" \
    "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns, dry_run: "false", confirm: "true"}')"
  assert_equal "$(_task_result_data | jq -r '.changed')" "true"

  # SQL status is authoritative on v24; no operator topology object is touched.
  submit_task "replication/status" "$AQSH_B_URL" \
    "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns, include_peer: "false"}')"
  assert_equal "$(_task_result_data | jq -r '.local.replicationConfigured')" "false"
  assert_equal "$(_task_result_data | jq -r '.local.linkRunning')" "false"

  # The managed instance and its storage remain present.
  run kubectl --context "$CTX_B" -n "$DB_NS" get mariadb mariadb
  assert_success

  # PVC identity also survives the detach.
  run kubectl --context "$CTX_B" -n "$DB_NS" get pvc storage-mariadb-0
  assert_success

  echo "detach on an already-detached standby succeeds" >&3
  # Re-running a runbook step must not fail because the end state already holds.
  submit_task "replication/detach" "$AQSH_B_URL" \
    "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns, dry_run: "false", confirm: "true"}')"
  assert_equal "$(_task_result_data | jq -r '.changed')" "false"


  echo "public in-place restore uses an exact backup and preserves identity" >&3
  submit_task "physical-backup" "$AQSH_A_URL" \
    "$(jq -nc --arg ns "$DB_NS" '{namespace:$ns,dry_run:"false",confirm:"true",target:"Primary"}')" 900
  local backup
  backup="$(_task_result_data | jq -r '.backupName')"
  [[ -n "$backup" && "$backup" != null ]]
  assert_equal "$(_task_result_data | jq -r '.created')" true
  submit_task "restore-in-place" "$AQSH_B_URL" \
    "$(jq -nc --arg ns "$DB_NS" --arg backup "$backup" '{namespace:$ns,backup:$backup}')"
  assert_equal "$(_task_result_data | jq -r '.changed')" false
  submit_task "restore-in-place" "$AQSH_B_URL" \
    "$(jq -nc --arg ns "$DB_NS" --arg backup "$backup" '{namespace:$ns,backup:$backup,dry_run:"false",confirm:"true"}')" 1800
  assert_equal "$(_task_result_data | jq -r '.state')" COMPLETED
  assert_equal "$(_task_result_data | jq -r '.inPlace')" true
  run kubectl --context "$CTX_B" -n "$DB_NS" get mariadb mariadb -o jsonpath='{.metadata.uid}'
  assert_success
  assert_output "$cr_before"
  run kubectl --context "$CTX_B" -n "$DB_NS" get pvc storage-mariadb-0 -o jsonpath='{.metadata.uid}'
  assert_success
  assert_output "$pvc_before"
  wait_for_marker_rows 3

  echo "v24 still rejects unsupported blue-green operations without mutation" >&3
  submit_allow_failure "blue-green/create" "$AQSH_A_URL" \
    "$(jq -nc --arg ns "$DB_NS" --arg peer "$AQSH_B_URL" \
      '{namespace:$ns,blue_name:"mariadb",green_name:"unused-green",green_image:"mariadb:10.6",peer_aqsh_url:$peer,peer_token:"unused"}')"
  assert_equal "$(_task_result_reason)" OPERATION_UNAVAILABLE
  submit_allow_failure "blue-green/switchover" "$AQSH_A_URL" \
    "$(jq -nc --arg ns "$DB_NS" --arg peer "$AQSH_B_URL" \
      '{namespace:$ns,blue_name:"mariadb",green_name:"unused-green",peer_aqsh_url:$peer,peer_token:"unused"}')"
  assert_equal "$(_task_result_reason)" OPERATION_UNAVAILABLE
  run kubectl --context "$CTX_A" -n "$DB_NS" get mariadb -o jsonpath='{.items[*].metadata.name}'
  assert_success
  assert_output mariadb
  wait_for_marker_rows 3
}
