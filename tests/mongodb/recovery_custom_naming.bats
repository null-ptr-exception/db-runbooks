#!/usr/bin/env bats
# =============================================================================
# Proves that a non-default credential/path naming convention is resolved
# entirely from internal config (/etc/aqsh/config/mongodb.env), with zero
# naming-convention inputs in the API call — not by callers passing
# credential_secret/credential_user_key/credential_pass_key/data_path/
# mount_path on every call.
#
# This file temporarily reconfigures the EXISTING mongo-1 / mongo-core
# deployment in place (no second cluster release, no new ClusterRole — RBAC
# ClusterRoles are cluster-scoped and singleton by name):
#   1. Re-create the root credentials under a new secret name + key
#      convention (app-mongo-creds / DB_USER / DB_PASS) with the same values
#   2. Point internal config's *_DEFAULT keys and the RBAC ClusterRole's
#      secrets resourceNames at that new convention
#   3. Call recovery/pre-check with only namespace+target_pod and assert it
#      succeeds — if the 3-tier resolution or the RBAC templating were
#      broken, this would fail outright (RBAC denied or credentials missing),
#      not silently fall back to the old convention
#   4. Restore everything in teardown_file so later runs see the default
#      convention again
#
# Runs last alphabetically among tests/mongodb/*.bats so it does not affect
# other files' assumptions about the default naming convention.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  export CTX_A CTX_B NS AQSH_URL TEST_POD TOKEN

  local ctx="$CTX_A"

  # recovery.bats's teardown_file removes the data-recovery init container
  # and the recovery ConfigMap once its own tests finish (G1/G2 prerequisites
  # are intentionally not left behind for other suites). Re-apply them via
  # the canonical setup script before this file's gates run.
  "${BATS_TEST_DIRNAME}/../../aqsh-tasks/scripts/mongodb/recovery/setup-data-recovery.sh" \
    --context "$ctx" --namespace mongo-1 --sts mongodb --profile standard
  kubectl --context "$ctx" -n mongo-1 \
    rollout status statefulset/mongodb --timeout=120s || true

  # Re-create the existing root credentials under a different secret name +
  # key convention — same values, simulating a different corporate
  # environment's secret-naming convention.
  local cred_info mongo_user mongo_pass
  cred_info=$(kubectl --context "$ctx" -n mongo-1 get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}{"\t"}{.data.MONGO_ROOT_PASS}')
  mongo_user=$(printf '%s' "${cred_info%%$'\t'*}" | base64 -d)
  mongo_pass=$(printf '%s' "${cred_info#*$'\t'}" | base64 -d)
  [[ -n "$mongo_user" && -n "$mongo_pass" ]] || {
    echo "Could not read MONGO_ROOT_USER/MONGO_ROOT_PASS from secret mongodb-credentials in mongo-1" >&2
    return 1
  }
  kubectl --context "$ctx" -n mongo-1 create secret generic app-mongo-creds \
    --from-literal=DB_USER="$mongo_user" --from-literal=DB_PASS="$mongo_pass" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  # Capture current state so teardown_file can restore it exactly.
  kubectl --context "$ctx" -n mongo-core get configmap aqsh-config \
    -o jsonpath='{.data.mongodb\.env}' > "${BATS_FILE_TMPDIR}/orig_mongodb_env.txt"
  kubectl --context "$ctx" get clusterrole aqsh-mongo-manager -o json \
    | jq -c '(.rules[] | select(.resources == ["secrets"])).resourceNames' \
    > "${BATS_FILE_TMPDIR}/orig_secret_resourcenames.json"

  # Swap internal config to the new convention: secret name/keys AND the
  # standard mongo:N data/mount paths, so the call body below needs neither.
  local new_env
  new_env=$(printf '%s\nMONGO_CRED_SECRET_DEFAULT=app-mongo-creds\nMONGO_CRED_USER_KEY_DEFAULT=DB_USER\nMONGO_CRED_PASS_KEY_DEFAULT=DB_PASS\nRECOVERY_DATA_PATH_DEFAULT=/data/db\nRECOVERY_MOUNT_PATH_DEFAULT=/data/db\n' \
    "$(cat "${BATS_FILE_TMPDIR}/orig_mongodb_env.txt")")
  kubectl --context "$ctx" -n mongo-core patch configmap aqsh-config --type=merge \
    -p "$(jq -n --arg v "$new_env" '{"data":{"mongodb.env":$v}}')"

  # Widen RBAC to match — without this, the swap above would be denied at
  # the kubectl-get-secret step, not silently fall back to the old secret.
  kubectl --context "$ctx" get clusterrole aqsh-mongo-manager -o json \
    | jq '(.rules[] | select(.resources == ["secrets"])).resourceNames = ["app-mongo-creds"]' \
    | kubectl --context "$ctx" apply -f -

  echo "Restarting aqsh to pick up the swapped internal config..."
  kubectl --context "$ctx" -n mongo-core rollout restart deployment/aqsh
  kubectl --context "$ctx" -n mongo-core rollout status deployment/aqsh --timeout=120s
}

teardown_file() {
  local ctx="kind-cluster-a"

  if [[ -f "${BATS_FILE_TMPDIR}/orig_mongodb_env.txt" ]]; then
    kubectl --context "$ctx" -n mongo-core patch configmap aqsh-config --type=merge \
      -p "$(jq -n --rawfile v "${BATS_FILE_TMPDIR}/orig_mongodb_env.txt" '{"data":{"mongodb.env":$v}}')" \
      2>/dev/null || true
  fi

  if [[ -f "${BATS_FILE_TMPDIR}/orig_secret_resourcenames.json" ]]; then
    kubectl --context "$ctx" get clusterrole aqsh-mongo-manager -o json \
      | jq --slurpfile names "${BATS_FILE_TMPDIR}/orig_secret_resourcenames.json" \
          '(.rules[] | select(.resources == ["secrets"])).resourceNames = $names[0]' \
      | kubectl --context "$ctx" apply -f - 2>/dev/null || true
  fi

  kubectl --context "$ctx" -n mongo-1 delete secret app-mongo-creds --ignore-not-found 2>/dev/null || true

  echo "Restarting aqsh to restore the default internal config..."
  kubectl --context "$ctx" -n mongo-core rollout restart deployment/aqsh 2>/dev/null || true
  kubectl --context "$ctx" -n mongo-core rollout status deployment/aqsh --timeout=120s 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

kexec() {
  kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"
}

http_post() {
  local url="$1" body="$2"
  local response
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
  local base_url="$1" task_id="$2" max_wait="${3:-120}"
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE

    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && { echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2; return 1; }
    [[ -z "$status" && -n "$TASK_RESPONSE" ]] && { echo "Task ${task_id} invalid response: ${TASK_RESPONSE}" >&2; return 1; }

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

@test "recovery/pre-check succeeds with zero naming-convention inputs against a non-default credential/path convention" {
  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result fail_count
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  fail_count=$(echo "$result" | jq -r '.fail // "missing"')
  [ "$fail_count" = "0" ] || { echo "gates: $result" >&2; false; }
}
