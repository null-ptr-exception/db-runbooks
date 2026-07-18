#!/usr/bin/env bats
# =============================================================================
# E2E for the secrets/* gateway family on aqsh-mongodb (docs/mongodb/secrets.md).
#
# Flow under test: caller fetches the deployment public key (secrets/pubkey),
# encrypts {"keys":{...}} locally, then plan -> apply upserts the Secret in
# mongo-1. Values must never appear in task results — only key names,
# actions and sha256 fingerprints. Failure paths cover decrypt/schema/CAS/
# protected-secret refusals; a 0-replica Bitnami-style StatefulSet fixture
# proves the protected-secret auto-detect reads the MONGODB_ROOT_* env
# convention too (official MONGO_INITDB_ROOT_* is covered by mongo-1 itself).
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"
  DB_NS="mongo-1"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  export CTX_A CTX_B NS AQSH_URL DB_NS TEST_POD TOKEN

  # Import the deployment public key once for the whole file. Local gpg is
  # required for every encrypting test (same guard as account_lifecycle's
  # encrypted-payload tests).
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
    e2e-secrets-app e2e-secrets-merge e2e-secrets-stale e2e-secrets-del \
    --ignore-not-found
  kubectl --context "$CTX_A" delete ns secrets-bitnami --ignore-not-found --wait=false
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  if [[ -z "${SECRETS_GNUPG:-}" ]]; then
    skip "gpg is required for secrets/* e2e"
  fi
}

# ---------------------------------------------------------------------------
# Helpers (same pattern as reconfig.bats / pbm_helpers.bash)
# ---------------------------------------------------------------------------

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

_sha256_of() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

_secret_value() {
  local name="$1" key="$2"
  kubectl --context "$CTX_A" -n "$DB_NS" get secret "$name" \
    -o "jsonpath={.data.${key}}" | base64 -d
}

_delete_secret() {
  kubectl --context "$CTX_A" -n "$DB_NS" delete secret "$1" --ignore-not-found
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

# plan + assert completed + return plan_hash on stdout
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
  local fpr
  fpr=$(echo "$RESULT_DATA" | jq -r '.fingerprint')
  [[ "$fpr" =~ ^[0-9A-F]{40}$ ]]
  # The key imported in setup_file came from this endpoint; fingerprints match.
  assert_equal "$fpr" "$SECRETS_FPR"
  GNUPGHOME="$SECRETS_GNUPG" gpg --batch --with-colons --list-keys | grep -q "^fpr:::::::::${fpr}:"
}

@test "secrets/plan for a new secret reports all-create and a plan_hash" {
  _delete_secret e2e-secrets-app
  local ct
  ct=$(_encrypt_payload '{"keys":{"username":"monitor","password":"user-chosen-pass-1"}}')

  run_secrets_task "plan" "$(_plan_payload e2e-secrets-app "$ct")"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.secret_exists')" "false"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.summary.create')" "2"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '[.changes[].action] | unique | join(",")')" "create"
  # No value may leak into the result. ([[ ]] instead of `! grep`: bash
  # exempts !-prefixed pipelines from set -e/ERR, so `! grep` can never
  # fail a bats test.)
  [[ "$RESULT_DATA" != *"user-chosen-pass-1"* ]]
  [[ "$(echo "$RESULT_DATA" | jq -r '.plan_hash')" =~ ^sec[0-9a-f]{24}$ ]]
}

@test "secrets/apply creates the secret and values round-trip via kubectl" {
  _delete_secret e2e-secrets-app
  local ct hash
  ct=$(_encrypt_payload '{"keys":{"username":"monitor","password":"user-chosen-pass-1"}}')
  hash=$(_plan_hash_for e2e-secrets-app "$ct")

  run_secrets_task "apply" "$(_apply_payload e2e-secrets-app "$ct" "$hash")"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.action')" "created"
  [[ "$RESULT_DATA" != *"user-chosen-pass-1"* ]]

  assert_equal "$(_secret_value e2e-secrets-app username)" "monitor"
  assert_equal "$(_secret_value e2e-secrets-app password)" "user-chosen-pass-1"
  assert_equal "$(kubectl --context "$CTX_A" -n "$DB_NS" get secret e2e-secrets-app -o jsonpath='{.type}')" "Opaque"
}

@test "secrets/get reports key fingerprints without values" {
  run_secrets_task "get" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns, secret_name: "e2e-secrets-app"}')"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.keys | length')" "2"
  assert_equal \
    "$(echo "$RESULT_DATA" | jq -r '.keys[] | select(.key=="password") | .value_sha256')" \
    "$(_sha256_of "user-chosen-pass-1")"
  [[ "$RESULT_DATA" != *"user-chosen-pass-1"* ]]
}

@test "secrets/get for a missing secret fails NOT_FOUND" {
  run_secrets_task "get" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns, secret_name: "e2e-secrets-nope"}')"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "NOT_FOUND"
}

@test "re-plan is all-unchanged and apply is an idempotent no-op" {
  local ct hash
  ct=$(_encrypt_payload '{"keys":{"username":"monitor","password":"user-chosen-pass-1"}}')

  run_secrets_task "plan" "$(_plan_payload e2e-secrets-app "$ct")"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.summary.unchanged')" "2"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.summary.create + .summary.update')" "0"
  hash=$(echo "$RESULT_DATA" | jq -r '.plan_hash')

  run_secrets_task "apply" "$(_apply_payload e2e-secrets-app "$ct" "$hash")"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.action')" "unchanged"
}

@test "changing one value plans update for only that key" {
  local ct hash
  ct=$(_encrypt_payload '{"keys":{"username":"monitor","password":"user-chosen-pass-2"}}')

  run_secrets_task "plan" "$(_plan_payload e2e-secrets-app "$ct")"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.changes[] | select(.key=="password") | .action')" "update"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.changes[] | select(.key=="username") | .action')" "unchanged"
  hash=$(echo "$RESULT_DATA" | jq -r '.plan_hash')

  run_secrets_task "apply" "$(_apply_payload e2e-secrets-app "$ct" "$hash")"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.action')" "patched"
  assert_equal "$(_secret_value e2e-secrets-app password)" "user-chosen-pass-2"
}

@test "merge preserves keys the payload does not mention" {
  _delete_secret e2e-secrets-merge
  kubectl --context "$CTX_A" -n "$DB_NS" create secret generic e2e-secrets-merge \
    --from-literal=pre-existing=keepme

  local ct hash
  ct=$(_encrypt_payload '{"keys":{"added":"new-value"}}')
  hash=$(_plan_hash_for e2e-secrets-merge "$ct")

  run_secrets_task "apply" "$(_apply_payload e2e-secrets-merge "$ct" "$hash")"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.retained_keys | join(",")')" "pre-existing"
  assert_equal "$(_secret_value e2e-secrets-merge pre-existing)" "keepme"
  assert_equal "$(_secret_value e2e-secrets-merge added)" "new-value"
}

@test "external edit between plan and apply fails PLAN_STALE" {
  _delete_secret e2e-secrets-stale
  kubectl --context "$CTX_A" -n "$DB_NS" create secret generic e2e-secrets-stale \
    --from-literal=k=v1

  local ct hash
  ct=$(_encrypt_payload '{"keys":{"k":"v2"}}')
  hash=$(_plan_hash_for e2e-secrets-stale "$ct")

  # External actor bumps resourceVersion after plan
  kubectl --context "$CTX_A" -n "$DB_NS" patch secret e2e-secrets-stale \
    --type merge -p "{\"data\":{\"k\":\"$(printf 'external' | base64)\"}}"

  run_secrets_task "apply" "$(_apply_payload e2e-secrets-stale "$ct" "$hash")"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "PLAN_STALE"
  # The external edit was not clobbered
  assert_equal "$(_secret_value e2e-secrets-stale k)" "external"
}

@test "garbage and wrong-key payloads fail DECRYPT_FAILED" {
  run_secrets_task "plan" "$(_plan_payload e2e-secrets-app "bm90LXBncC1hdC1hbGw=")"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "DECRYPT_FAILED"

  # Encrypt against a key the deployment does not hold
  local other_home other_ct
  other_home=$(mktemp -d)
  chmod 700 "$other_home"
  GNUPGHOME="$other_home" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "wrong-key@example.com" rsa3072 encr 1d >/dev/null 2>&1
  other_ct=$(printf '%s' '{"keys":{"a":"b"}}' | GNUPGHOME="$other_home" gpg --batch --yes \
    --trust-model always --armor --recipient "wrong-key@example.com" --encrypt | base64 | tr -d '\n')
  rm -rf "$other_home"

  run_secrets_task "plan" "$(_plan_payload e2e-secrets-app "$other_ct")"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "DECRYPT_FAILED"
}

@test "wrong shape fails PAYLOAD_INVALID; bad key name fails INVALID_INPUT" {
  local ct
  ct=$(_encrypt_payload '{"not_keys":{"a":"b"}}')
  run_secrets_task "plan" "$(_plan_payload e2e-secrets-app "$ct")"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "PAYLOAD_INVALID"

  ct=$(_encrypt_payload '{"keys":{"bad key!":"b"}}')
  run_secrets_task "plan" "$(_plan_payload e2e-secrets-app "$ct")"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "INVALID_INPUT"
}

@test "apply without or with malformed plan_hash is rejected at submission" {
  local ct
  ct=$(_encrypt_payload '{"keys":{"a":"b"}}')

  http_post "${AQSH_URL}/tasks/secrets%2Fapply" \
    "$(jq -nc --arg ns "$DB_NS" --arg payload "$ct" \
      '{namespace: $ns, secret_name: "e2e-secrets-app", payload: $payload}')"
  [[ "$HTTP_CODE" != "202" ]]

  http_post "${AQSH_URL}/tasks/secrets%2Fapply" \
    "$(jq -nc --arg ns "$DB_NS" --arg payload "$ct" \
      '{namespace: $ns, secret_name: "e2e-secrets-app", payload: $payload, plan_hash: "not-a-hash"}')"
  [[ "$HTTP_CODE" != "202" ]]
}

@test "plan/apply/delete against protected secrets fail PROTECTED_SECRET" {
  local ct
  ct=$(_encrypt_payload '{"keys":{"MONGO_ROOT_PASS":"evil"}}')

  # mongodb-credentials: auto-detected from the official-image env wiring
  # (MONGO_INITDB_ROOT_* secretKeyRef on the mongo-1 StatefulSet)
  run_secrets_task "plan" "$(_plan_payload mongodb-credentials "$ct")"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "PROTECTED_SECRET"

  run_secrets_task "apply" "$(_apply_payload mongodb-credentials "$ct" "sec000000000000000000000000")"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "PROTECTED_SECRET"

  # minio (PBM S3 credentials): protected via SECRETS_PROTECTED_NAMES_DEFAULT
  run_secrets_task "delete" "$(jq -nc --arg ns "$DB_NS" \
    '{namespace: $ns, secret_name: "minio", confirm: "true"}')"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "PROTECTED_SECRET"
}

@test "delete previews without confirm, deletes with confirm, then NOT_FOUND" {
  _delete_secret e2e-secrets-del
  local ct hash
  ct=$(_encrypt_payload '{"keys":{"tmp":"short-lived"}}')
  hash=$(_plan_hash_for e2e-secrets-del "$ct")
  run_secrets_task "apply" "$(_apply_payload e2e-secrets-del "$ct" "$hash")"
  assert_equal "$TASK_STATUS" "completed"

  # Preview (default confirm=false): reports, does not delete
  run_secrets_task "delete" "$(jq -nc --arg ns "$DB_NS" \
    '{namespace: $ns, secret_name: "e2e-secrets-del"}')"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.deleted')" "false"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.confirm_required')" "true"
  kubectl --context "$CTX_A" -n "$DB_NS" get secret e2e-secrets-del >/dev/null

  run_secrets_task "delete" "$(jq -nc --arg ns "$DB_NS" \
    '{namespace: $ns, secret_name: "e2e-secrets-del", confirm: "true"}')"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.deleted')" "true"
  run kubectl --context "$CTX_A" -n "$DB_NS" get secret e2e-secrets-del
  assert_failure

  run_secrets_task "delete" "$(jq -nc --arg ns "$DB_NS" \
    '{namespace: $ns, secret_name: "e2e-secrets-del", confirm: "true"}')"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "NOT_FOUND"
}

@test "bitnami-style credential wiring is auto-detected as protected" {
  local sns="secrets-bitnami"
  kubectl --context "$CTX_A" create ns "$sns" --dry-run=client -o yaml \
    | kubectl --context "$CTX_A" apply -f -

  # Namespace-scoped RoleBinding to the existing ClusterRole (pbm fixture
  # precedent) so the tasks may operate here at all.
  kubectl --context "$CTX_A" -n "$sns" apply -f - <<'RB_EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: aqsh-mongo-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aqsh-mongo-manager
subjects:
  - kind: ServiceAccount
    name: kube-auth-proxy
    namespace: mongo-core
RB_EOF

  # 0-replica StatefulSet with Bitnami-chart env wiring: detection reads the
  # SPEC (env secretKeyRef), so no pod ever needs to run.
  kubectl --context "$CTX_A" -n "$sns" create secret generic bitnami-root \
    --from-literal=mongodb-root-password=owned --dry-run=client -o yaml \
    | kubectl --context "$CTX_A" -n "$sns" apply -f -
  kubectl --context "$CTX_A" -n "$sns" apply -f - <<'STS_EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
spec:
  replicas: 0
  serviceName: mongodb
  selector:
    matchLabels:
      app: mongodb
  template:
    metadata:
      labels:
        app: mongodb
    spec:
      containers:
        - name: mongodb
          image: mongo:7.0.21
          env:
            - name: MONGODB_ROOT_USER
              value: root
            - name: MONGODB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: bitnami-root
                  key: mongodb-root-password
STS_EOF

  local ct hash
  ct=$(_encrypt_payload '{"keys":{"mongodb-root-password":"evil"}}')
  run_secrets_task "plan" "$(jq -nc --arg ns "$sns" --arg payload "$ct" \
    '{namespace: $ns, secret_name: "bitnami-root", payload: $payload, log_level: "DEBUG"}')"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "PROTECTED_SECRET"

  # A non-protected name in the same namespace works — proving the refusal
  # above is the detector, not RBAC or wiring.
  ct=$(_encrypt_payload '{"keys":{"app":"ok"}}')
  run_secrets_task "plan" "$(jq -nc --arg ns "$sns" --arg payload "$ct" \
    '{namespace: $ns, secret_name: "bitnami-app", payload: $payload}')"
  assert_equal "$TASK_STATUS" "completed"
  hash=$(echo "$RESULT_DATA" | jq -r '.plan_hash')
  run_secrets_task "apply" "$(jq -nc --arg ns "$sns" --arg payload "$ct" --arg plan_hash "$hash" \
    '{namespace: $ns, secret_name: "bitnami-app", payload: $payload, plan_hash: $plan_hash}')"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(kubectl --context "$CTX_A" -n "$sns" get secret bitnami-app \
    -o jsonpath='{.data.app}' | base64 -d)" "ok"

  kubectl --context "$CTX_A" delete ns "$sns" --wait=false
}
