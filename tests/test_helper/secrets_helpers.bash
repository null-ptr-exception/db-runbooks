#!/usr/bin/env bash
# =============================================================================
# Shared helpers for the secrets/* e2e files (tests/mongodb/secrets.bats and
# tests/mariadb/secrets.bats). Test-local HTTP/crypto plumbing — NOT a task
# lib. Lives in tests/test_helper/ (not a suite dir) because, unlike the
# pbm_helpers.bash precedent, these two consumers sit in DIFFERENT suite
# directories and must stay in lockstep: the mariadb file deliberately
# delegates failure-path coverage to the mongodb one.
#
# Callers set before use: CTX_A CTX_B NS AQSH_URL DB_NS (setup_file), then
# call secrets_suite_setup_file to resolve TEST_POD/TOKEN and import the
# deployment public key (SECRETS_GNUPG/SECRETS_FPR; both empty without gpg —
# tests skip on that).
# =============================================================================

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

# Submit to a secrets endpoint and wait for a terminal state; exports
# TASK_STATUS + RESULT_DATA. Echo gives failed assertions the actual result.
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

# _encrypt_payload <json> — armored PGP for the deployment key, base64'd to
# one line (survives the single-quoted curl -d in kexec).
_encrypt_payload() {
  printf '%s' "$1" | GNUPGHOME="$SECRETS_GNUPG" gpg --batch --yes --trust-model always \
    --armor --recipient "$SECRETS_FPR" --encrypt 2>/dev/null | base64 | tr -d '\n'
}

_secret_value() {
  local name="$1" key="$2"
  kubectl --context "$CTX_A" -n "$DB_NS" get secret "$name" \
    -o "jsonpath={.data.${key}}" | base64 -d
}

# _plan_payload <secret_name> <ciphertext> [mode]
_plan_payload() {
  local secret_name="$1" ciphertext="$2" mode="${3:-}"
  jq -nc --arg ns "$DB_NS" --arg name "$secret_name" --arg payload "$ciphertext" \
    --arg mode "$mode" \
    '{namespace: $ns, secret_name: $name, payload: $payload, log_level: "DEBUG"}
     + (if $mode == "" then {} else {mode: $mode} end)'
}

# _apply_payload <secret_name> <ciphertext> <plan_hash> [mode]
_apply_payload() {
  local secret_name="$1" ciphertext="$2" plan_hash="$3" mode="${4:-}"
  jq -nc --arg ns "$DB_NS" --arg name "$secret_name" --arg payload "$ciphertext" \
    --arg plan_hash "$plan_hash" --arg mode "$mode" \
    '{namespace: $ns, secret_name: $name, payload: $payload, plan_hash: $plan_hash,
      requested_by: "bats", request_id: "secrets-e2e", log_level: "DEBUG"}
     + (if $mode == "" then {} else {mode: $mode} end)'
}

# plan + assert completed + return plan_hash on stdout
_plan_hash_for() {
  local secret_name="$1" ciphertext="$2" mode="${3:-}"
  run_secrets_task "plan" "$(_plan_payload "$secret_name" "$ciphertext" "$mode")" >&2 || return 1
  [[ "$TASK_STATUS" == "completed" ]] || return 1
  echo "$RESULT_DATA" | jq -r '.plan_hash'
}

# Resolve TEST_POD + TOKEN, then fetch and import the deployment public key
# once for the whole file (SECRETS_GNUPG stays empty without local gpg — the
# per-test skip guard keys off that).
secrets_suite_setup_file() {
  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)
  export TEST_POD TOKEN

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
