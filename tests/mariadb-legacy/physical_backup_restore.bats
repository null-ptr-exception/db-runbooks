#!/usr/bin/env bats

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  CTX_A=kind-cluster-a
  CTX_B=kind-cluster-b
  DB_NS=mariadb-1
  CONTROL_NS=db-ops
  AQSH_URL=http://aqsh-mariadb.kind-a.test:30080
  LEGACY_RESOURCES="${BATS_FILE_TMPDIR}/legacy.resources"
  TEST_POD="$(kubectl --context "$CTX_B" -n "$CONTROL_NS" get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')"
  TOKEN="$(kubectl --context "$CTX_B" -n "$CONTROL_NS" create token test-client --duration=2h)"
  kubectl --context "$CTX_A" api-resources --api-group=mariadb.mmontes.io -o name >"$LEGACY_RESOURCES"
  export CTX_A CTX_B DB_NS CONTROL_NS AQSH_URL TEST_POD TOKEN LEGACY_RESOURCES
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

teardown_file() {
  kubectl --context "$CTX_A" -n "$DB_NS" delete mariadb "${RESTORE_TARGET:-legacy-restore}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl --context "$CTX_A" -n "$DB_NS" delete job,secret,pvc "${RESTORE_TARGET:-legacy-restore}-prepare" "${RESTORE_TARGET:-legacy-restore}-prepare-s3" "storage-${RESTORE_TARGET:-legacy-restore}-0" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

kexec() { kubectl --context "$CTX_B" -n "$CONTROL_NS" exec "$TEST_POD" -- sh -c "$1"; }

http_post() {
  local url="$1" body="$2" response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\n%{http_code}' -X POST '${url}' \
    -H 'Authorization: Bearer ${TOKEN}' -H 'Content-Type: application/json' -d '${body}'")
  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

wait_for_task() {
  local base="$1" id="$2" accept_failed="${3:-false}" elapsed=0 status
  while (( elapsed < 900 )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 -H 'Authorization: Bearer ${TOKEN}' '${base}/executions/${id}'")
    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty')
    [[ "$status" == completed ]] && return 0
    if [[ "$status" == failed ]]; then
      [[ "$accept_failed" == true ]] && return 0
      echo "$TASK_RESPONSE" >&2
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "timed out: $TASK_RESPONSE" >&2
  return 1
}

task_result() {
  echo "$TASK_RESPONSE" | jq -c '.result.data as $d | (($d | try fromjson catch null) // (if ($d|type)=="object" then $d else .result end))'
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
          . != "credentialsRef" and . != "sourcePod" and . != "mode" and
          . != "operatorGroup" and . != "apiVersion" and . != "conditions")
  ' >/dev/null
  [[ "$result" != *"Secret"* ]]
  [[ "$result" != *"mariadb.mmontes.io"* ]]
  [[ "$result" != *"k8s.mariadb.com"* ]]
}

assert_restore_result_contract() {
  local result="$1"
  echo "$result" | jq -e '
    (.data | keys) ==
    ["contentType", "dryRun", "namespace", "pointInTimeRecovery",
     "provisioned", "restored", "state"]
  ' >/dev/null
}

assert_restore_result_hides_internals() {
  local result="$1"
  assert_restore_result_contract "$result"
  [[ "$result" != *"Secret"* ]]
  [[ "$result" != *"PersistentVolumeClaim"* ]]
  [[ "$result" != *"Job"* ]]
  [[ "$result" != *"mariadb.mmontes.io"* ]]
  [[ "$result" != *"k8s.mariadb.com"* ]]
  [[ "$result" != *"s3://"* ]]
}

submit() {
  local task="$1" payload="$2" id
  http_post "${AQSH_URL}/tasks/${task}" "$payload"
  if [[ "$HTTP_CODE" != 202 ]]; then
    echo "POST ${task} failed (${HTTP_CODE}): ${HTTP_BODY}" >&2
    kubectl --context "$CTX_A" -n "$CONTROL_NS" logs deployment/aqsh -c aqsh --tail=100 >&2 || true
    kubectl --context "$CTX_A" -n "$CONTROL_NS" logs deployment/aqsh -c kube-auth-proxy --tail=100 >&2 || true
  fi
  assert_equal "$HTTP_CODE" 202
  id=$(echo "$HTTP_BODY" | jq -r .id)
  wait_for_task "$AQSH_URL" "$id" "${3:-false}"
}

primary_pod() { kubectl --context "$CTX_A" -n "$DB_NS" get mariadb "$1" -o jsonpath='{.status.currentPrimary}'; }
root_password() { kubectl --context "$CTX_A" -n "$DB_NS" get secret mariadb -o jsonpath='{.data.password}' | base64 -d; }
mariadb_names() {
  kubectl --context "$CTX_A" -n "$DB_NS" get mariadb \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}
sql() {
  local cr="$1" query="$2" pod password
  pod="$(primary_pod "$cr")"; password="$(root_password)"
  kubectl --context "$CTX_A" -n "$DB_NS" exec "$pod" -c mariadb -- mariadb -u root -p"$password" -N -B -e "$query"
}

@test "legacy discovery exposes only the mmontes operator capabilities" {
  [ -f "$LEGACY_RESOURCES" ]
  run grep -Fx mariadbs.mariadb.mmontes.io "$LEGACY_RESOURCES"
  assert_success
  run grep -E 'physicalbackups|externalmariadbs' "$LEGACY_RESOURCES"
  assert_failure
  run kubectl --context "$CTX_A" api-resources --api-group=mariadb.mmontes.io -o name
  assert_output --partial mariadbs.mariadb.mmontes.io
  assert_output --partial backups.mariadb.mmontes.io
}

@test "legacy logical Backup omits unsupported prefix and is accepted" {
  submit logical-backup '{"namespace":"mariadb-1","dry_run":"true"}'
  result=$(task_result)
  backup=$(echo "$result" | jq -r '.data.backupName')
  assert_backup_result_contract "$result"
  assert_backup_result_hides_internals "$result"
  assert_equal "$(echo "$result" | jq -r '.data.created')" false
  assert_equal "$(echo "$result" | jq -r '.data.contentType')" Logical
  assert_equal "$(echo "$result" | jq -r '.data.state')" PLANNED
  run kubectl --context "$CTX_A" -n "$DB_NS" get backup "$backup"
  assert_failure

  submit logical-backup '{"namespace":"mariadb-1","dry_run":"false","confirm":"true","wait_timeout":"0"}'
  result=$(task_result)
  backup=$(echo "$result" | jq -r '.data.backupName')
  assert_backup_result_contract "$result"
  assert_backup_result_hides_internals "$result"
  assert_equal "$(echo "$result" | jq -r '.data.created')" true
  assert_equal "$(echo "$result" | jq -r '.data.contentType')" Logical
  assert_equal "$(echo "$result" | jq -r '.data.state')" REQUESTED
  assert_equal "$(kubectl --context "$CTX_A" -n "$DB_NS" get backup "$backup" -o jsonpath='{.apiVersion}')" mariadb.mmontes.io/v1alpha1
  assert_equal "$(kubectl --context "$CTX_A" -n "$DB_NS" get backup "$backup" -o jsonpath='{.spec.storage.s3.prefix}')" ""
  kubectl --context "$CTX_A" -n "$DB_NS" delete backup "$backup" --wait=false >/dev/null
  kubectl --context "$CTX_A" -n "$DB_NS" delete job "$backup" --ignore-not-found --wait=false >/dev/null
}

@test "legacy physical backup and hand-rolled restore round-trip real rows" {
  sql mariadb "DROP DATABASE IF EXISTS phase23_e2e; CREATE DATABASE phase23_e2e; \
    CREATE TABLE phase23_e2e.marker (id INT PRIMARY KEY, value VARCHAR(64)); \
    INSERT INTO phase23_e2e.marker VALUES (1, 'before-backup');"

  submit physical-backup '{"namespace":"mariadb-1","dry_run":"true"}'
  result=$(task_result)
  assert_backup_result_contract "$result"
  assert_backup_result_hides_internals "$result"
  assert_equal "$(echo "$result" | jq -r '.data.created')" false
  assert_equal "$(echo "$result" | jq -r '.data.contentType')" Physical
  assert_equal "$(echo "$result" | jq -r '.data.state')" PLANNED
  run kubectl --context "$CTX_A" -n "$DB_NS" get physicalbackup
  assert_failure

  submit physical-backup '{"namespace":"mariadb-1","dry_run":"false","confirm":"true","wait_timeout":"10m"}'
  result=$(task_result)
  assert_backup_result_contract "$result"
  assert_backup_result_hides_internals "$result"
  assert_equal "$(echo "$result" | jq -r '.data.created')" true
  assert_equal "$(echo "$result" | jq -r '.data.contentType')" Physical
  assert_equal "$(echo "$result" | jq -r '.data.state')" COMPLETED
  backup=$(echo "$result" | jq -r '.data.backupName')
  object="tenant-a/database/${backup}.xb"
  # The legacy direct-client path must honor the workload S3_SUBFOLDER even
  # though the legacy operator-managed logical Backup CRD cannot carry prefix.
  [[ "$object" == tenant-a/database/*.xb ]]
  run kubectl --context "$CTX_B" -n minio run phase23-s5cmd-ls \
    --image=peakcom/s5cmd:v2.3.0 --restart=Never --rm -i \
    --env=AWS_ACCESS_KEY_ID=minioadmin --env=AWS_SECRET_ACCESS_KEY=minioadmin-changeme-prod \
    --command -- /s5cmd --json --endpoint-url http://minio:9000 ls "s3://db-backups/${object}"
  assert_success
  assert_output --partial '"size"'

  # The backup completed before this mutation, so a successful restore must not
  # contain the later row.
  sql mariadb "INSERT INTO phase23_e2e.marker VALUES (2, 'after-backup');"

  restore_names_before="$(mariadb_names | sort)"
  submit restore '{"namespace":"mariadb-1","dry_run":"true"}'
  result=$(task_result)
  assert_restore_result_hides_internals "$result"
  assert_equal "$(echo "$result" | jq -r '.data.contentType')" Physical
  assert_equal "$(echo "$result" | jq -r '.data.dryRun')" true
  assert_equal "$(echo "$result" | jq -r '.data.provisioned')" false
  assert_equal "$(echo "$result" | jq -r '.data.restored')" false
  assert_equal "$(echo "$result" | jq -r '.data.state')" PLANNED
  assert_equal "$(mariadb_names | sort)" "$restore_names_before"

  submit restore '{"namespace":"mariadb-1","dry_run":"false","confirm":"true","wait_timeout":"10m"}'
  result=$(task_result)
  assert_restore_result_hides_internals "$result"
  assert_equal "$(echo "$result" | jq -r '.data.contentType')" Physical
  assert_equal "$(echo "$result" | jq -r '.data.dryRun')" false
  assert_equal "$(echo "$result" | jq -r '.data.provisioned')" true
  target="$(comm -13 \
    <(printf '%s\n' "$restore_names_before") \
    <(mariadb_names | sort))"
  [[ "$target" =~ ^mariadb-1-restore-[0-9]{14}$ ]]
  RESTORE_TARGET="$target"
  export RESTORE_TARGET
  assert_equal "$(echo "$result" | jq -r '.data.restored')" true
  assert_equal "$(echo "$result" | jq -r '.data.state')" COMPLETED
  assert_equal "$(kubectl --context "$CTX_A" -n "$DB_NS" get mariadb "$target" -o jsonpath='{.apiVersion}')" mariadb.mmontes.io/v1alpha1
  assert_equal "$(kubectl --context "$CTX_A" -n "$DB_NS" get mariadb "$target" -o jsonpath='{.spec.volumeClaimTemplate.resources.requests.storage}')" 1Gi
  pvc=$(kubectl --context "$CTX_A" -n "$DB_NS" get pod "${target}-0" -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}')
  assert_equal "$pvc" "storage-${target}-0"
  assert_equal "$(sql "$target" "SELECT GROUP_CONCAT(value ORDER BY id) FROM phase23_e2e.marker")" before-backup
  assert_equal "$(sql mariadb "SELECT COUNT(*) FROM phase23_e2e.marker")" 2
}

@test "legacy blue-green create fails before any unsupported CR or mutation" {
  before=$(kubectl --context "$CTX_A" -n "$DB_NS" get mariadb,backup,restore,job,pvc,statefulset,secret -o name 2>/dev/null | sort)
  submit blue-green%2Fcreate '{"namespace":"mariadb-1","blue_name":"mariadb","green_name":"mariadb-green","green_image":"mariadb:10.6","peer_aqsh_url":"http://peer.invalid","peer_token":"dummy","confirm":"true"}' true
  result=$(task_result)
  assert_equal "$(echo "$result" | jq -r .status)" error
  assert_equal "$(echo "$result" | jq -r .code)" 2
  assert_equal "$(echo "$result" | jq -r .reason)" OPERATION_UNAVAILABLE
  message=$(echo "$result" | jq -r .message)
  assert_equal "$message" "blue-green is unavailable for this database"
  assert_equal "$(echo "$result" | jq -r '.data | keys | sort | join(",")')" "available,stage"
  assert_equal "$(echo "$result" | jq -r '.data.stage')" capability-check
  assert_equal "$(echo "$result" | jq -r '.data.available')" false
  [[ "$result" != *"mariadb.mmontes.io"* ]]
  [[ "$result" != *"ExternalMariaDB"* ]]
  [[ "$result" != *"CRD"* ]]
  [[ "$result" != *"operator"* ]]
  [[ "$result" != *"multiCluster"* ]]
  after=$(kubectl --context "$CTX_A" -n "$DB_NS" get mariadb,backup,restore,job,pvc,statefulset,secret -o name 2>/dev/null | sort)
  assert_equal "$after" "$before"
  run kubectl --context "$CTX_A" -n "$DB_NS" get mariadb "${RESTORE_TARGET:-legacy-restore}" mariadb-green
  assert_failure
}
