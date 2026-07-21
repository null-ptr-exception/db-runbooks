#!/usr/bin/env bats

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load 'setup_suite'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="db-ops"
  MARIADB_AQSH_URL="http://aqsh-mariadb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  # Stand up a throwaway mariadb-3 instance on cluster-a (isolated from mariadb-1).
  deploy_throwaway_mariadb "mariadb-3" "$CTX_A" || return 1

  export CTX_A CTX_B NS MARIADB_AQSH_URL TEST_POD TOKEN
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

teardown_file() {
  load 'setup_suite'
  delete_namespace_and_wait "kind-cluster-a" "mariadb-3"
}

kexec() {
  kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"
}

http_post() {
  local url="$1" body="$2"
  local response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\\n%{http_code}' \
    -X POST '${url}' -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Content-Type: application/json' -d '${body}'")
  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

http_get() {
  local url="$1"
  local response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\\n%{http_code}' \
    -X GET '${url}' -H 'Authorization: Bearer ${TOKEN}'")
  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-540}"
  local elapsed=0 status
  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE
    status=$(echo "$TASK_RESPONSE" | jq -r '.status' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && { echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2; return 1; }
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

_get_db_env_payload() {
  local envs="${1:?envs required}"
  jq -nc --arg envs "$envs" '{
    namespace: "mariadb-3",
    mdb: "mariadb",
    envs: $envs
  }'
}

_task_result_vars() {
  echo "$TASK_RESPONSE" | jq -r '
    (.result.data as $data |
      (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))
    ) | .vars'
}

@test "get-db-env returns MARIADB_ROOT_PASSWORD from the pod" {
  local payload
  payload="$(_get_db_env_payload "MARIADB_ROOT_PASSWORD")"

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fget-db-env" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  if [[ -z "$task_id" ]]; then
    echo "expected task id in response: $HTTP_BODY" >&2
    return 1
  fi
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local result_status vars password
  result_status=$(echo "$TASK_RESPONSE" | jq -r '
    (.result.data as $data |
      (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))
    ) | .status')
  vars="$(_task_result_vars)"
  password=$(echo "$vars" | jq -r '.MARIADB_ROOT_PASSWORD // empty')

  assert_equal "$result_status" "OK"
  assert [ -n "$password" ]
}

@test "get-db-env returns null for an unset env var" {
  local payload
  payload="$(_get_db_env_payload "MARIADB_ROOT_PASSWORD,THIS_VAR_DOES_NOT_EXIST")"

  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fget-db-env" "$payload"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  local vars missing
  vars="$(_task_result_vars)"
  missing=$(echo "$vars" | jq -r '.THIS_VAR_DOES_NOT_EXIST')

  assert_equal "$missing" "null"
}
