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

@test "legacy physical backup and hand-rolled restore round-trip real rows" {
  sql mariadb "DROP DATABASE IF EXISTS phase23_e2e; CREATE DATABASE phase23_e2e; \
    CREATE TABLE phase23_e2e.marker (id INT PRIMARY KEY, value VARCHAR(64)); \
    INSERT INTO phase23_e2e.marker VALUES (1, 'before-backup');"

  submit physical-backup '{"namespace":"mariadb-1","dry_run":"true","compression":"none"}'
  result=$(task_result)
  assert_equal "$(echo "$result" | jq -r '.data.created')" false
  assert_equal "$(echo "$result" | jq -r '.data.backup.mode')" hand-rolled
  run kubectl --context "$CTX_A" -n "$DB_NS" get physicalbackup
  assert_failure

  submit physical-backup '{"namespace":"mariadb-1","dry_run":"false","confirm":"true","compression":"none","wait_timeout":"10m"}'
  result=$(task_result)
  assert_equal "$(echo "$result" | jq -r '.data.created')" true
  object=$(echo "$result" | jq -r '.data.backup.object')
  [[ "$object" == mariadb/mariadb-1/*.xb ]]
  assert_equal "$(echo "$result" | jq -r '.data.backup.compression')" none
  run kubectl --context "$CTX_B" -n minio run phase23-mc-stat \
    --image=minio/mc:RELEASE.2024-11-21T17-21-54Z --restart=Never --rm -i \
    --env=MC_HOST_local=http://minioadmin:minioadmin-changeme-prod@minio:9000 \
    --command -- /usr/bin/mc stat "local/db-backups/${object}"
  assert_success
  assert_output --partial "Size"

  # The backup completed before this mutation, so a successful restore must not
  # contain the later row.
  sql mariadb "INSERT INTO phase23_e2e.marker VALUES (2, 'after-backup');"

  submit restore '{"namespace":"mariadb-1","dry_run":"true"}'
  result=$(task_result)
  assert_equal "$(echo "$result" | jq -r '.data.restored')" false
  target=$(echo "$result" | jq -r '.data.target')
  run kubectl --context "$CTX_A" -n "$DB_NS" get mariadb "$target"
  assert_failure

  submit restore '{"namespace":"mariadb-1","dry_run":"false","confirm":"true","wait_timeout":"10m"}'
  result=$(task_result)
  target=$(echo "$result" | jq -r '.data.target')
  RESTORE_TARGET="$target"
  export RESTORE_TARGET
  assert_equal "$(echo "$result" | jq -r '.data.restored')" true
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
  message=$(echo "$result" | jq -r .message)
  [[ "$message" == *"requires the k8s.mariadb.com generation"* ]]
  [[ "$message" == *"no ExternalMariaDB CRD"* ]]
  [[ "$message" == *"upgrade the operator"* ]]
  [[ "$message" != *"no matches for kind"* ]]
  assert_equal "$(echo "$result" | jq -r '.data.operatorGroup')" mariadb.mmontes.io
  echo "$result" | jq -e '.data.required | index("multiCluster") and index("externalmariadbs CRD") and index("physical bootstrapFrom")' >/dev/null
  after=$(kubectl --context "$CTX_A" -n "$DB_NS" get mariadb,backup,restore,job,pvc,statefulset,secret -o name 2>/dev/null | sort)
  assert_equal "$after" "$before"
  run kubectl --context "$CTX_A" -n "$DB_NS" get mariadb "${RESTORE_TARGET:-legacy-restore}" mariadb-green
  assert_failure
}
