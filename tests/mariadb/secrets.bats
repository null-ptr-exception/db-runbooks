#!/usr/bin/env bats
# =============================================================================
# E2E for the secrets/* gateway family on aqsh-mariadb (docs/mariadb/secrets.md).
#
# The scripts are shared with the MongoDB gateway verbatim; this file proves
# the family works against mariadb-1 and that the MariaDB deployment's
# protected list (SECRETS_PROTECTED_NAMES_DEFAULT=mariadb,minio — no live
# auto-detect for operator-managed root credentials) refuses root/infra
# secrets. Full failure-path coverage lives in tests/mongodb/secrets.bats.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="db-ops"
  AQSH_URL="http://aqsh-mariadb.kind-a.test:30080"
  DB_NS="mariadb-1"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  export CTX_A CTX_B NS AQSH_URL DB_NS TEST_POD TOKEN

  SECRETS_GNUPG=""
  SECRETS_FPR=""
  if command -v gpg >/dev/null 2>&1; then
    run_secrets_task "pubkey" '{}' || return 1
    [[ "$TASK_STATUS" == "completed" ]] || { echo "secrets/pubkey failed: ${RESULT_DATA}" >&2; return 1; }
    SECRETS_GNUPG=$(mktemp -d)
    chmod 700 "$SECRETS_GNUPG"
    echo "$RESULT_DATA" | jq -r '.public_key' \
      | GNUPGHOME="$SECRETS_GNUPG" gpg --batch --import 2>/dev/null
    SECRETS_FPR=$(echo "$RESULT_DATA" | jq -r '.fingerprint')
  fi
  export SECRETS_GNUPG SECRETS_FPR
}

teardown_file() {
  [[ -n "${SECRETS_GNUPG:-}" ]] && rm -rf "$SECRETS_GNUPG"
  kubectl --context "$CTX_A" -n "$DB_NS" delete secret \
    e2e-secrets-app e2e-secrets-stale --ignore-not-found
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  if [[ -z "${SECRETS_GNUPG:-}" ]]; then
    skip "gpg is required for secrets/* e2e"
  fi
}

# --- Helpers (same pattern as create_account.bats + reconfig.bats) ---

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

wait_for_task_any() {
  local base_url="$1" task_id="$2" max_wait="${3:-180}"
  local elapsed=0 status
  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE
    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    if [[ "$status" == "completed" || "$status" == "failed" ]]; then
      TASK_STATUS="$status"
      export TASK_STATUS
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "Task ${task_id} still not terminal after ${max_wait}s (status: ${status})" >&2
  return 1
}

_task_result_data() {
  echo "$TASK_RESPONSE" | jq -c '
    .result.data as $data |
    (($data | try fromjson catch null) // (if ($data | type) == "object" then $data else .result end))
  '
}

run_secrets_task() {
  local endpoint="$1" body="$2" max_wait="${3:-180}"
  http_post "${AQSH_URL}/tasks/secrets%2F${endpoint}" "$body"
  [[ "$HTTP_CODE" == "202" ]] || { echo "submit secrets/${endpoint} got HTTP ${HTTP_CODE}: ${HTTP_BODY}" >&2; return 1; }
  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task_any "$AQSH_URL" "$task_id" "$max_wait" || return 1
  RESULT_DATA=$(_task_result_data)
  export RESULT_DATA
  echo "secrets/${endpoint} -> ${TASK_STATUS}: ${RESULT_DATA:0:1000}"
}

_encrypt_payload() {
  printf '%s' "$1" | GNUPGHOME="$SECRETS_GNUPG" gpg --batch --yes --trust-model always \
    --armor --recipient "$SECRETS_FPR" --encrypt 2>/dev/null | base64 | tr -d '\n'
}

_secret_value() {
  local name="$1" key="$2"
  kubectl --context "$CTX_A" -n "$DB_NS" get secret "$name" \
    -o "jsonpath={.data.${key}}" | base64 -d
}

_plan_payload() {
  local secret_name="$1" ciphertext="$2"
  jq -nc --arg ns "$DB_NS" --arg name "$secret_name" --arg payload "$ciphertext" \
    '{namespace: $ns, secret_name: $name, payload: $payload, log_level: "DEBUG"}'
}

_apply_payload() {
  local secret_name="$1" ciphertext="$2" plan_hash="$3"
  jq -nc --arg ns "$DB_NS" --arg name "$secret_name" --arg payload "$ciphertext" \
    --arg plan_hash "$plan_hash" \
    '{namespace: $ns, secret_name: $name, payload: $payload, plan_hash: $plan_hash,
      requested_by: "bats", request_id: "secrets-e2e", log_level: "DEBUG"}'
}

_plan_hash_for() {
  local secret_name="$1" ciphertext="$2"
  run_secrets_task "plan" "$(_plan_payload "$secret_name" "$ciphertext")" >&2 || return 1
  [[ "$TASK_STATUS" == "completed" ]] || return 1
  echo "$RESULT_DATA" | jq -r '.plan_hash'
}

# --- Tests ---

@test "secrets/pubkey returns an importable armored key" {
  run_secrets_task "pubkey" '{}'
  assert_equal "$TASK_STATUS" "completed"
  [[ "$(echo "$RESULT_DATA" | jq -r '.fingerprint')" =~ ^[0-9A-F]{40}$ ]]
}

@test "plan/apply upserts a secret in mariadb-1 and merge retains foreign keys" {
  kubectl --context "$CTX_A" -n "$DB_NS" delete secret e2e-secrets-app --ignore-not-found
  kubectl --context "$CTX_A" -n "$DB_NS" create secret generic e2e-secrets-app \
    --from-literal=pre-existing=keepme

  local ct hash
  ct=$(_encrypt_payload '{"keys":{"monitor-user":"monitor","monitor-pass":"user-chosen-pass"}}')
  hash=$(_plan_hash_for e2e-secrets-app "$ct")
  [[ "$hash" =~ ^sec[0-9a-f]{24}$ ]]

  run_secrets_task "apply" "$(_apply_payload e2e-secrets-app "$ct" "$hash")"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.action')" "patched"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.retained_keys | join(",")')" "pre-existing"
  # [[ ]] instead of `! grep`: bash exempts !-prefixed pipelines from
  # set -e/ERR, so `! grep` can never fail a bats test.
  [[ "$RESULT_DATA" != *"user-chosen-pass"* ]]

  assert_equal "$(_secret_value e2e-secrets-app monitor-pass)" "user-chosen-pass"
  assert_equal "$(_secret_value e2e-secrets-app pre-existing)" "keepme"
}

@test "secrets/get reports fingerprints; missing secret fails NOT_FOUND" {
  run_secrets_task "get" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns, secret_name: "e2e-secrets-app"}')"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal \
    "$(echo "$RESULT_DATA" | jq -r '.keys[] | select(.key=="monitor-pass") | .value_sha256')" \
    "$(printf '%s' "user-chosen-pass" | sha256sum | awk '{print $1}')"

  run_secrets_task "get" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns, secret_name: "e2e-secrets-nope"}')"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "NOT_FOUND"
}

@test "external edit between plan and apply fails PLAN_STALE" {
  kubectl --context "$CTX_A" -n "$DB_NS" delete secret e2e-secrets-stale --ignore-not-found
  kubectl --context "$CTX_A" -n "$DB_NS" create secret generic e2e-secrets-stale \
    --from-literal=k=v1

  local ct hash
  ct=$(_encrypt_payload '{"keys":{"k":"v2"}}')
  hash=$(_plan_hash_for e2e-secrets-stale "$ct")

  kubectl --context "$CTX_A" -n "$DB_NS" patch secret e2e-secrets-stale \
    --type merge -p "{\"data\":{\"k\":\"$(printf 'external' | base64)\"}}"

  run_secrets_task "apply" "$(_apply_payload e2e-secrets-stale "$ct" "$hash")"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "PLAN_STALE"
}

@test "root and infra secrets are protected via internal config" {
  local ct
  ct=$(_encrypt_payload '{"keys":{"password":"evil"}}')

  # "mariadb" holds the operator root password (rootPasswordSecretKeyRef)
  run_secrets_task "plan" "$(_plan_payload mariadb "$ct")"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "PROTECTED_SECRET"

  # "minio" holds the S3 credentials the backup/restore tasks read
  run_secrets_task "delete" "$(jq -nc --arg ns "$DB_NS" \
    '{namespace: $ns, secret_name: "minio", confirm: "true"}')"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "PROTECTED_SECRET"
}

@test "delete previews without confirm and deletes with confirm" {
  run_secrets_task "delete" "$(jq -nc --arg ns "$DB_NS" \
    '{namespace: $ns, secret_name: "e2e-secrets-stale"}')"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.deleted')" "false"
  kubectl --context "$CTX_A" -n "$DB_NS" get secret e2e-secrets-stale >/dev/null

  run_secrets_task "delete" "$(jq -nc --arg ns "$DB_NS" \
    '{namespace: $ns, secret_name: "e2e-secrets-stale", confirm: "true"}')"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.deleted')" "true"
  run kubectl --context "$CTX_A" -n "$DB_NS" get secret e2e-secrets-stale
  assert_failure
}

@test "garbage payload fails DECRYPT_FAILED" {
  run_secrets_task "plan" "$(_plan_payload e2e-secrets-app "bm90LXBncC1hdC1hbGw=")"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "DECRYPT_FAILED"
}
