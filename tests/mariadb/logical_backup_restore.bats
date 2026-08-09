#!/usr/bin/env bats
#
# e2e: operator-managed logical Backup -> bootstrapFrom.backupRef restore.
#
# The unit tests mock kubectl and lock down each script's manifest contract.
# This suite exercises the real, current-generation mariadb-operator installed
# by setup_suite.bash and proves the operator can complete the whole workflow:
# dry runs are render-only, a Backup CR reaches Complete, a restored MariaDB
# reaches Ready, and data captured by the logical backup is queryable there.
# The separate legacy-operator test matrix remains tracked by #63.

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="db-ops"
  DB_NS="mariadb-1"
  AQSH_URL="http://aqsh-mariadb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  kubectl --context "$CTX_B" -n minio rollout status deployment/minio --timeout=120s

  # A failed prior run may have left auto-named resources behind. Start from a
  # deterministic namespace so "latest Backup" and source auto-detection cannot
  # accidentally select stale e2e objects.
  _cleanup_logical_restore_targets
  _cleanup_logical_backups

  export CTX_A CTX_B NS DB_NS AQSH_URL TEST_POD TOKEN
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

teardown_file() {
  _cleanup_logical_restore_targets
  _cleanup_logical_backups
  _sql mariadb "DROP DATABASE IF EXISTS logical_e2e_db" >/dev/null 2>&1 || true
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
  local base_url="$1" task_id="$2" max_wait="${3:-960}"
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE

    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && {
      echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2
      return 1
    }

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

_submit() {
  local task="$1" payload="$2" task_id
  http_post "${AQSH_URL}/tasks/${task}" "$payload"
  assert_equal "$HTTP_CODE" "202"

  task_id=$(echo "$HTTP_BODY" | jq -r '.id // empty')
  [[ -n "$task_id" ]] || { echo "missing task id: $HTTP_BODY" >&2; return 1; }
  wait_for_task "$AQSH_URL" "$task_id"
}

_task_result_data() {
  echo "$TASK_RESPONSE" | jq -c '
    .result.data as $data |
    (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))
  '
}

assert_backup_result_contract() {
  local result="$1"
  echo "$result" | jq -e '
    (.data | keys) ==
    ["backupName", "contentType", "created", "dryRun", "namespace", "state"]
  ' >/dev/null
}

assert_backup_result_hides_internals() {
  local result="$1"
  echo "$result" | jq -e '
    [paths(scalars) as $p | ($p[-1] | tostring)]
    | all(.[];
          . != "manifest" and . != "plan" and . != "storage" and
          . != "credentialsRef" and . != "sourcePod" and . != "operatorGroup" and
          . != "apiVersion" and . != "conditions")
  ' >/dev/null
  [[ "$result" != *"Secret"* ]]
  [[ "$result" != *"k8s.mariadb.com"* ]]
  [[ "$result" != *"mariadb.mmontes.io"* ]]
}

assert_restore_result_contract() {
  local result="$1"
  echo "$result" | jq -e '
    (.data | keys) ==
    ["contentType", "dryRun", "namespace", "provisioned", "restored", "state"]
  ' >/dev/null
}

assert_restore_result_hides_internals() {
  local result="$1"
  assert_backup_result_hides_internals "$result"
  [[ "$result" != *"backupName"* ]]
  [[ "$result" != *"backupRef"* ]]
  [[ "$result" != *"connection"* ]]
  [[ "$result" != *"target"* ]]
}

_matching_resource_names() {
  local resource="$1" pattern="$2"
  kubectl --context "$CTX_A" -n "$DB_NS" get "$resource" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | sed -n "/${pattern}/p"
}

_mariadb_names() {
  kubectl --context "$CTX_A" -n "$DB_NS" get mariadb \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | sed '/^$/d' \
    | sort
}

_delete_mariadb_and_wait() {
  local target="$1"
  [[ -n "$target" ]] || return 0
  kubectl --context "$CTX_A" -n "$DB_NS" delete mariadb "$target" \
    --ignore-not-found --wait=false >/dev/null
  kubectl --context "$CTX_A" -n "$DB_NS" wait --for=delete "mariadb/${target}" \
    --timeout=180s >/dev/null 2>&1 || true
}

_cleanup_logical_restore_targets() {
  local targets target
  targets="$(_matching_resource_names mariadb '^mariadb-1-lrestore-[0-9]\{14\}$')"
  while IFS= read -r target; do
    _delete_mariadb_and_wait "$target"
  done <<< "$targets"
}

_cleanup_logical_backups() {
  local backups backup
  backups="$(_matching_resource_names backup '^mariadb-logical-[0-9]\{14\}$')"
  while IFS= read -r backup; do
    [[ -n "$backup" ]] || continue
    kubectl --context "$CTX_A" -n "$DB_NS" delete backup "$backup" \
      --ignore-not-found --wait=false >/dev/null
  done <<< "$backups"
}

_latest_logical_backup() {
  kubectl --context "$CTX_A" -n "$DB_NS" get backup -o json \
    | jq -r '
        .items[]
        | select(.metadata.name | test("^mariadb-logical-[0-9]{14}$"))
        | select([.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length > 0)
        | [.metadata.creationTimestamp, .metadata.name]
        | @tsv
      ' \
    | sort -r | head -1 | cut -f2
}

_seed_logical_fixture() {
  _sql mariadb "DROP DATABASE IF EXISTS logical_e2e_db; \
    CREATE DATABASE logical_e2e_db; \
    CREATE TABLE logical_e2e_db.marker (id INT PRIMARY KEY, value VARCHAR(64)); \
    INSERT INTO logical_e2e_db.marker VALUES (1, 'logical-backup-round-trip');"
}

# Make the confirmed restore test independently runnable with `bats -f` while
# reusing the Backup created by the normal full-file run.
_ensure_complete_logical_backup() {
  LOGICAL_BACKUP_NAME="$(_latest_logical_backup)"
  if [[ -n "$LOGICAL_BACKUP_NAME" ]]; then
    return 0
  fi

  _seed_logical_fixture
  _submit "logical-backup" \
    '{"namespace":"mariadb-1","dry_run":"false","confirm":"true","wait_timeout":"10m"}'
  local result
  result="$(_task_result_data)"
  LOGICAL_BACKUP_NAME=$(echo "$result" | jq -r '.data.backupName // empty')
  [[ -n "$LOGICAL_BACKUP_NAME" ]] || {
    echo "logical-backup completed without returning a backupName: $result" >&2
    return 1
  }
}

_primary_pod() {
  kubectl --context "$CTX_A" -n "$DB_NS" get mariadb "$1" \
    -o jsonpath='{.status.currentPrimary}'
}

_root_password() {
  kubectl --context "$CTX_A" -n "$DB_NS" get secret mariadb \
    -o jsonpath='{.data.password}' | base64 -d
}

# _sql <mariadb-cr> <query> -- query an operator-selected primary as root.
_sql() {
  local cr="$1" query="$2" primary password
  primary="$(_primary_pod "$cr")"
  [[ -n "$primary" ]] || { echo "MariaDB ${cr} has no currentPrimary" >&2; return 1; }
  password="$(_root_password)"
  kubectl --context "$CTX_A" -n "$DB_NS" exec "$primary" -c mariadb -- \
    mariadb -u root -p"${password}" -N -B -e "$query"
}

@test "logical-backup dry-run returns a sanitized summary without applying" {
  _submit "logical-backup" \
    '{"namespace":"mariadb-1","dry_run":"true"}'

  local result backup_name
  result="$(_task_result_data)"
  backup_name=$(echo "$result" | jq -r '.data.backupName')

  assert_backup_result_contract "$result"
  assert_backup_result_hides_internals "$result"
  assert_equal "$(echo "$result" | jq -r '.data.dryRun')" "true"
  assert_equal "$(echo "$result" | jq -r '.data.created')" "false"
  assert_equal "$(echo "$result" | jq -r '.data.contentType')" "Logical"
  assert_equal "$(echo "$result" | jq -r '.data.state')" "PLANNED"
  [[ -n "$backup_name" ]]

  run kubectl --context "$CTX_A" -n "$DB_NS" get backup "$backup_name"
  assert_failure
}

@test "logical-backup creates a Backup CR that reaches Complete" {
  _seed_logical_fixture

  _submit "logical-backup" \
    '{"namespace":"mariadb-1","dry_run":"false","confirm":"true","wait_timeout":"10m"}'

  local result backup_name
  result="$(_task_result_data)"
  backup_name=$(echo "$result" | jq -r '.data.backupName // empty')

  assert_backup_result_contract "$result"
  assert_backup_result_hides_internals "$result"
  assert_equal "$(echo "$result" | jq -r '.data.created')" "true"
  assert_equal "$(echo "$result" | jq -r '.data.contentType')" "Logical"
  assert_equal "$(echo "$result" | jq -r '.data.state')" "COMPLETED"
  [[ -n "$backup_name" ]]

  kubectl --context "$CTX_A" -n "$DB_NS" get backup "$backup_name"
  assert_equal "$(kubectl --context "$CTX_A" -n "$DB_NS" get backup "$backup_name" \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')" "True"
}

@test "logical-restore dry-run returns a sanitized plan without applying it" {
  local backup_name payload result before_targets after_targets
  # A dry run must accept the requested public input without requiring the
  # Backup to exist, while keeping the rendered operator manifest private.
  backup_name="logical-e2e-dry-run-source"
  payload=$(jq -nc --arg backup "$backup_name" \
    '{namespace:"mariadb-1", backup:$backup, dry_run:"true"}')

  before_targets="$(_mariadb_names)"
  _submit "logical-restore" "$payload"
  result="$(_task_result_data)"
  after_targets="$(_mariadb_names)"

  assert_restore_result_contract "$result"
  assert_restore_result_hides_internals "$result"
  assert_equal "$(echo "$result" | jq -r '.data.namespace')" "$DB_NS"
  assert_equal "$(echo "$result" | jq -r '.data.contentType')" "Logical"
  assert_equal "$(echo "$result" | jq -r '.data.state')" "PLANNED"
  assert_equal "$(echo "$result" | jq -r '.data.dryRun')" "true"
  assert_equal "$(echo "$result" | jq -r '.data.provisioned')" "false"
  assert_equal "$(echo "$result" | jq -r '.data.restored')" "false"
  assert_equal "$after_targets" "$before_targets"
}

@test "logical-restore reaches Ready and the restored data is queryable" {
  local backup_name payload result target before_targets after_targets
  _ensure_complete_logical_backup
  backup_name="$LOGICAL_BACKUP_NAME"
  payload=$(jq -nc --arg backup "$backup_name" \
    '{namespace:"mariadb-1", backup:$backup, dry_run:"false", confirm:"true", wait_timeout:"10m"}')

  before_targets="$(_mariadb_names)"
  _submit "logical-restore" "$payload"
  result="$(_task_result_data)"
  after_targets="$(_mariadb_names)"
  target=$(comm -13 \
    <(printf '%s\n' "$before_targets") \
    <(printf '%s\n' "$after_targets"))

  assert_restore_result_contract "$result"
  assert_restore_result_hides_internals "$result"
  assert_equal "$(echo "$result" | jq -r '.data.namespace')" "$DB_NS"
  assert_equal "$(echo "$result" | jq -r '.data.contentType')" "Logical"
  assert_equal "$(echo "$result" | jq -r '.data.state')" "COMPLETED"
  assert_equal "$(echo "$result" | jq -r '.data.dryRun')" "false"
  assert_equal "$(echo "$result" | jq -r '.data.provisioned')" "true"
  assert_equal "$(echo "$result" | jq -r '.data.restored')" "true"
  [[ -n "$target" ]]
  [[ "$target" != *$'\n'* ]]

  kubectl --context "$CTX_A" -n "$DB_NS" wait \
    --for=condition=Ready "mariadb/${target}" --timeout=300s
  assert_equal "$(kubectl --context "$CTX_A" -n "$DB_NS" get mariadb "$target" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" "True"

  run _sql "$target" "SELECT value FROM logical_e2e_db.marker WHERE id = 1"
  assert_success
  assert_output "logical-backup-round-trip"
}
