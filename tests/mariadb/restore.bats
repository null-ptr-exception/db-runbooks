#!/usr/bin/env bats
#
# e2e: MariaDB physical backup -> restore round-trip (#48).
#
# Unit tests (tests/unit/mariadb/restore.bats) mock kubectl and only check the
# manifest shape. This exercises the REAL operator path end to end on the
# 2-cluster + MinIO lab: `physical-backup` writes a mariabackup to
# s3://db-backups/mariadb/<ns>, `restore` provisions a NEW instance from it via
# spec.bootstrapFrom, and we assert the restored MariaDB reaches Ready AND that
# the seeded rows actually came back (the strongest proof the bootstrapFrom / S3
# credential wiring / Ready reconciliation all work — a wrong secret key or
# prefix would fail here instead of passing silently).
#
# PITR (target_time) is a documented follow-up: it needs continuous binlog
# archiving configured on the source, which this lab does not set up.

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="db-ops"
  AQSH_URL="http://aqsh-mariadb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  kubectl --context "$CTX_B" -n minio rollout status deployment/minio --timeout=120s

  _cleanup_restore_targets

  export CTX_A CTX_B NS AQSH_URL TEST_POD TOKEN
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

kexec() { kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"; }

_delete_mariadb_and_wait() {
  local target="$1"
  [[ -n "$target" ]] || return 0
  kubectl --context "$CTX_A" -n mariadb-1 delete mariadb "$target" --ignore-not-found
  kubectl --context "$CTX_A" -n mariadb-1 wait --for=delete "mariadb/${target}" --timeout=180s >/dev/null 2>&1 || true
}

_cleanup_restore_targets() {
  local targets target
  targets=$(kubectl --context "$CTX_A" -n mariadb-1 get mariadb \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | sed -n '/^mariadb-1-restore-[0-9]\{14\}$/p')

  while IFS= read -r target; do
    _delete_mariadb_and_wait "$target"
  done <<< "$targets"
}

# Remove any restored instances this suite created so later suites still see a
# single MariaDB CR in the namespace.
teardown() {
  _delete_mariadb_and_wait "${RESTORE_TARGET:-}"
  _cleanup_restore_targets
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
  local base_url="$1" task_id="$2" max_wait="${3:-960}"
  local elapsed=0 status
  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE
    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && { echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2; return 1; }
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

_task_result_data() {
  echo "$TASK_RESPONSE" | jq -c '
    .result.data as $data |
    (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))
  '
}

_primary_pod() {
  kubectl --context "$CTX_A" -n mariadb-1 get mariadb "${1:-mariadb}" \
    -o jsonpath='{.status.currentPrimary}' 2>/dev/null
}

_root_password() {
  kubectl --context "$CTX_A" -n mariadb-1 get secret mariadb \
    -o jsonpath='{.data.password}' | base64 -d
}

# _sql <mariadb-cr> <sql> — run SQL as root on that instance's primary pod.
_sql() {
  local cr="$1" query="$2" primary password
  primary="$(_primary_pod "$cr")"
  password="$(_root_password)"
  kubectl --context "$CTX_A" -n mariadb-1 exec "$primary" -c mariadb -- \
    mariadb -u root -p"${password}" -N -B -e "$query"
}

_submit() {
  local task="$1" payload="$2" task_id
  http_post "${AQSH_URL}/tasks/${task}" "$payload"
  assert_equal "$HTTP_CODE" "202"
  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]] || { echo "no task id: $HTTP_BODY" >&2; return 1; }
  wait_for_task "$AQSH_URL" "$task_id"
}

# --- Tests ---

@test "restore and physical-backup tasks are registered" {
  local body
  body=$(kexec "curl -s --connect-timeout 5 -m 10 \
    -H 'Authorization: Bearer ${TOKEN}' '${AQSH_URL}/tasks'")
  run echo "$body"
  assert_output --partial "restore"
  assert_output --partial "physical-backup"
}

@test "physical backup -> restore reaches Ready and brings the data back" {
  # 1. Seed a known dataset on the source instance.
  _sql mariadb "DROP DATABASE IF EXISTS e2e_db; CREATE DATABASE e2e_db; \
    CREATE TABLE e2e_db.t (id INT PRIMARY KEY); \
    INSERT INTO e2e_db.t VALUES (1),(2),(3);"
  run _sql mariadb "SELECT COUNT(*) FROM e2e_db.t"
  assert_output "3"

  # 2. Take a physical backup (writes to s3://db-backups/mariadb/mariadb-1).
  _submit "physical-backup" '{"namespace":"mariadb-1","dry_run":"false","confirm":"true","wait_timeout":"10m"}'
  local backup; backup="$(_task_result_data)"
  assert_equal "$(echo "$backup" | jq -r '.data.created')" "true"
  assert_equal "$(echo "$backup" | jq -r '.data.backup.contentType')" "Physical"

  # 3. Restore into a NEW instance from that backup.
  _submit "restore" '{"namespace":"mariadb-1","dry_run":"false","confirm":"true","wait_timeout":"10m"}'
  local restore; restore="$(_task_result_data)"
  assert_equal "$(echo "$restore" | jq -r '.data.restored')" "true"
  RESTORE_TARGET="$(echo "$restore" | jq -r '.data.target')"
  export RESTORE_TARGET
  [[ -n "$RESTORE_TARGET" && "$RESTORE_TARGET" != "null" ]]

  # 4. The restored CR must actually be Ready per the operator.
  kubectl --context "$CTX_A" -n mariadb-1 wait \
    --for=condition=Ready "mariadb/${RESTORE_TARGET}" --timeout=300s
  echo "restored conditions:"
  kubectl --context "$CTX_A" -n mariadb-1 get mariadb "$RESTORE_TARGET" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'; echo

  # 5. The seeded rows must be present in the restored instance — proves the
  #    bootstrapFrom / S3 restore actually moved data, not just provisioned.
  run _sql "$RESTORE_TARGET" "SELECT COUNT(*) FROM e2e_db.t"
  assert_output "3"
}
