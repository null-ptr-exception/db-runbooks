#!/usr/bin/env bats
#
# Cross-cluster replication e2e: cluster-b's standby attached to cluster-a's
# primary through the mesh stand-in (see tests/chart/templates/replication-mesh.yaml).
#
# The tests run in order and share state — bats executes a file top to bottom,
# and the flow here IS the runbook:
#
#   unlinked → assess (rebuild, because a fresh standby has no history)
#            → attach re-seeds and links → attach again is a no-op → detach
#
# SLOW. The rebuild takes a full physical backup on cluster-a, destroys the
# standby, and re-seeds it; budget ~15 minutes for that test alone.

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
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE
    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && return 1
    sleep 5
    elapsed=$((elapsed + 5))
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

# expect_task_ok <url> <task> <payload> [timeout]
expect_task_ok() {
  local rc=0
  run_task "$@" || rc=$?
  if (( rc != 0 )); then
    echo "expected the task to succeed (rc=${rc}); response: ${TASK_RESPONSE}" >&2
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

@test "mesh services exist with the derived names on both clusters" {
  # The task derives <namespace>-rw; if the chart named it anything else the
  # rest of this file would be testing a fiction.
  run kubectl --context "$CTX_B" -n "$DB_NS" get svc "${DB_NS}-rw" -o jsonpath='{.spec.type}'
  assert_success
  assert_output "ExternalName"

  run kubectl --context "$CTX_A" -n "$DB_NS" get svc "${DB_NS}-rw" -o jsonpath='{.spec.type}'
  assert_success
  assert_output "ExternalName"
}

@test "standby can reach the primary through the mesh stand-in" {
  # Proves the data path before any task depends on it: a failure here is
  # infrastructure, not task logic.
  local host="${DB_NS}-rw.${DB_NS}.svc.cluster.local"
  run kubectl --context "$CTX_B" -n "$DB_NS" exec mariadb-0 -c mariadb -- \
    sh -c "mariadb -h ${host} -P 30091 --connect-timeout=10 -u root -p\"\$MARIADB_ROOT_PASSWORD\" -N -B -e 'SELECT 1' 2>&1"
  assert_success
  assert_output --partial "1"
}

# --- assessment ---------------------------------------------------------------

@test "status reports the standby as unlinked before any attach" {
  expect_task_ok "$AQSH_B_URL" "replication/status" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns}')"

  local data
  data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.local.multiClusterEnabled')" "false"
  assert_equal "$(echo "$data" | jq -r '.local.linkRunning')" "false"
}

@test "status can reach the peer through the mesh stand-in" {
  # Guards the deploy-time config path end to end: if REPL_PEER_PORT_DEFAULT is
  # not actually reaching the scripts, the peer probe fails and this is the
  # first place it shows.
  expect_task_ok "$AQSH_B_URL" "replication/status" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns}')"

  local data
  data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.peer.probed')" "true"
  assert_equal "$(echo "$data" | jq -r '.peer.reachable')" "true"
}

@test "attach dry run assesses a fresh standby as needing a rebuild" {
  # A standby that has never replicated has no GTID position to resume from.
  expect_task_ok "$AQSH_B_URL" "replication/attach" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns}')"

  local data
  data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.action')" "rebuild"
  assert_equal "$(echo "$data" | jq -r '.actionReason')" "NO_REPLICATION_HISTORY"
  assert_equal "$(echo "$data" | jq -r '.changed')" "false"
}

@test "attach without peer_token cannot take the re-seed path" {
  # The re-seed needs a fresh backup from the primary's own AQSH; without a
  # token there is no way to ask for one. Rejected before anything is touched.
  expect_task_reason "INVALID_REQUEST" "$AQSH_B_URL" "replication/attach" \
    "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns, dry_run: "false", confirm: "true"}')"
}

@test "attach honours expected_action" {
  expect_task_reason "UNEXPECTED_ACTION" "$AQSH_B_URL" "replication/attach" \
    "$(jq -nc --arg ns "$DB_NS" \
      '{namespace: $ns, dry_run: "false", confirm: "true", expected_action: "attach"}')"
}

@test "attach requires confirm" {
  expect_task_reason "INVALID_REQUEST" "$AQSH_B_URL" "replication/attach" \
    "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns, dry_run: "false"}')"
}

# --- re-seed ------------------------------------------------------------------

@test "attach requires confirm before the re-seed path" {
  expect_task_reason "INVALID_REQUEST" "$AQSH_B_URL" "replication/attach" \
    "$(jq -nc --arg ns "$DB_NS" --arg tok "$TOKEN" \
      '{namespace: $ns, peer_token: $tok, dry_run: "false"}')"
}

@test "attach re-seeds the standby and establishes replication" {
  # SLOW: physical backup on cluster-a, then quiesce + in-place datadir
  # overwrite + link on cluster-b. One call — the caller does not switch
  # endpoints on the verdict.
  #
  # The identities are captured first: an in-place re-seed must not replace the
  # MariaDB CR or its PVCs, and comparing UIDs is the one check that cannot be
  # satisfied by a delete-and-recreate that merely looks similar.
  local cr_before pvc_before
  cr_before="$(kubectl --context "$CTX_B" -n "$DB_NS" get mariadb mariadb -o jsonpath='{.metadata.uid}')"
  pvc_before="$(kubectl --context "$CTX_B" -n "$DB_NS" get pvc storage-mariadb-0 -o jsonpath='{.metadata.uid}')"
  [ -n "$cr_before" ] && [ -n "$pvc_before" ]

  expect_task_ok "$AQSH_B_URL" "replication/attach" \
    "$(jq -nc --arg ns "$DB_NS" --arg tok "$TOKEN" \
      '{namespace: $ns, peer_token: $tok, dry_run: "false", confirm: "true", wait_timeout: "900"}')" \
    1800

  local data
  data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.changed')" "true"
  assert_equal "$(echo "$data" | jq -r '.stage')" "attached"

  run kubectl --context "$CTX_B" -n "$DB_NS" get mariadb mariadb -o jsonpath='{.metadata.uid}'
  assert_output "$cr_before"
  run kubectl --context "$CTX_B" -n "$DB_NS" get pvc storage-mariadb-0 -o jsonpath='{.metadata.uid}'
  assert_output "$pvc_before"
}

@test "status reports a running link after the rebuild" {
  expect_task_ok "$AQSH_B_URL" "replication/status" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns}')"

  local data
  data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.local.multiClusterEnabled')" "true"
  assert_equal "$(echo "$data" | jq -r '.local.linkRunning')" "true"
  assert_equal "$(echo "$data" | jq -r '.local.desiredPrimary')" "${DB_NS}-rw"
}

@test "attach on an already-linked standby is a successful no-op" {
  # Re-running the step must not fail because the end state already holds, and
  # must not re-derive an assessment: the operator's own post-restore writes
  # carry the standby's server_id, so a healthy linked standby always looks
  # "written to" and would be condemned to a rebuild.
  expect_task_ok "$AQSH_B_URL" "replication/attach" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns}')"

  local data
  data="$(_task_result_data)"
  assert_equal "$(echo "$data" | jq -r '.actionReason')" "ALREADY_ATTACHED"
  assert_equal "$(echo "$data" | jq -r '.changed')" "false"
}

# --- detach -------------------------------------------------------------------

@test "detach dry run leaves the link in place" {
  expect_task_ok "$AQSH_B_URL" "replication/detach" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns}')"
  assert_equal "$(_task_result_data | jq -r '.changed')" "false"

  run kubectl --context "$CTX_B" -n "$DB_NS" get mariadb mariadb -o jsonpath='{.spec.multiCluster.enabled}'
  assert_output "true"
}

@test "detach removes the link and its endpoint references" {
  expect_task_ok "$AQSH_B_URL" "replication/detach" \
    "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns, dry_run: "false", confirm: "true"}')"
  assert_equal "$(_task_result_data | jq -r '.changed')" "true"

  # The whole multiCluster block is removed, not just flipped to enabled:false —
  # leaving `members` behind would point the CR at ExternalMariaDB objects that
  # no longer exist. So `.enabled` reads as empty, not "false".
  run kubectl --context "$CTX_B" -n "$DB_NS" get mariadb mariadb -o jsonpath='{.spec.multiCluster.enabled}'
  assert_output ""

  # The ExternalMariaDB objects the attach created are gone too.
  run kubectl --context "$CTX_B" -n "$DB_NS" get externalmariadb "${DB_NS}-rw"
  assert_failure

  # And the multiCluster block itself is gone — leaving `members` behind would
  # point the CR at ExternalMariaDB objects that no longer exist, and would make
  # the next detach look like fresh work instead of a no-op.
  run kubectl --context "$CTX_B" -n "$DB_NS" get mariadb mariadb -o jsonpath='{.spec.multiCluster.members}'
  assert_output ""
}

@test "detach on an already-detached standby succeeds" {
  # Re-running a runbook step must not fail because the end state already holds.
  expect_task_ok "$AQSH_B_URL" "replication/detach" \
    "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns, dry_run: "false", confirm: "true"}')"
  assert_equal "$(_task_result_data | jq -r '.changed')" "false"
}
