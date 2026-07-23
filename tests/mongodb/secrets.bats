#!/usr/bin/env bats
# =============================================================================
# E2E for the secrets/* gateway family on aqsh-mongodb (docs/mongodb/secrets.md).
#
# Flow under test: caller fetches the deployment public key (secrets/pubkey),
# encrypts {"keys":{...}} locally, then plan -> apply upserts the Secret in
# mongo-1. Values must never appear in task results — only key names,
# actions and sha256 fingerprints. Failure paths cover decrypt/schema/CAS/
# mode/protected-secret refusals; a 0-replica Bitnami-style StatefulSet
# fixture proves the protected-secret auto-detect reads the MONGODB_ROOT_*
# env convention too (official MONGO_INITDB_ROOT_* is covered by mongo-1
# itself). Shared plumbing: tests/test_helper/secrets_helpers.bash.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load '../test_helper/secrets_helpers'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"
  DB_NS="mongo-1"
  export CTX_A CTX_B NS AQSH_URL DB_NS

  secrets_suite_setup_file
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
  load '../test_helper/secrets_helpers'
  if [[ -z "${SECRETS_GNUPG:-}" ]]; then
    skip "gpg is required for secrets/* e2e"
  fi
}

_sha256_of() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

_delete_secret() {
  kubectl --context "$CTX_A" -n "$DB_NS" delete secret "$1" --ignore-not-found
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
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.mode')" "upsert"
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

@test "add_only refuses overwriting an existing value and allows pure additions" {
  # e2e-secrets-app now holds username=monitor, password=user-chosen-pass-2
  local ct hash
  ct=$(_encrypt_payload '{"keys":{"password":"clobber-attempt"}}')
  run_secrets_task "plan" "$(_plan_payload e2e-secrets-app "$ct" add_only)"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "KEY_CONFLICT"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.details.conflicting_keys | join(",")')" "password"
  # The refusal changed nothing
  assert_equal "$(_secret_value e2e-secrets-app password)" "user-chosen-pass-2"

  # New keys and byte-identical re-pushes pass under add_only
  ct=$(_encrypt_payload '{"keys":{"username":"monitor","extra-token":"added-later"}}')
  hash=$(_plan_hash_for e2e-secrets-app "$ct" add_only)
  run_secrets_task "apply" "$(_apply_payload e2e-secrets-app "$ct" "$hash" add_only)"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.action')" "patched"
  assert_equal "$(_secret_value e2e-secrets-app extra-token)" "added-later"
  assert_equal "$(_secret_value e2e-secrets-app password)" "user-chosen-pass-2"
}

@test "skip_existing writes only new keys and silently skips existing ones" {
  # e2e-secrets-app: username=monitor, password=user-chosen-pass-2, extra-token
  local ct hash
  ct=$(_encrypt_payload '{"keys":{"password":"ignored-attempt","fresh-key":"fresh-value"}}')

  run_secrets_task "plan" "$(_plan_payload e2e-secrets-app "$ct" skip_existing)"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.changes[] | select(.key=="password") | .action')" "skipped"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.changes[] | select(.key=="fresh-key") | .action')" "create"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.summary.skipped')" "1"
  hash=$(echo "$RESULT_DATA" | jq -r '.plan_hash')

  run_secrets_task "apply" "$(_apply_payload e2e-secrets-app "$ct" "$hash" skip_existing)"
  assert_equal "$TASK_STATUS" "completed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.action')" "patched"
  # skipped key untouched, new key written
  assert_equal "$(_secret_value e2e-secrets-app password)" "user-chosen-pass-2"
  assert_equal "$(_secret_value e2e-secrets-app fresh-key)" "fresh-value"
}

@test "mode is plan_hash material: an add_only plan cannot be applied as upsert" {
  local ct hash
  ct=$(_encrypt_payload '{"keys":{"another-key":"v1"}}')
  hash=$(_plan_hash_for e2e-secrets-app "$ct" add_only)

  run_secrets_task "apply" "$(_apply_payload e2e-secrets-app "$ct" "$hash")"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "PLAN_STALE"
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

@test "apply without or with malformed plan_hash or mode is rejected at submission" {
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

  http_post "${AQSH_URL}/tasks/secrets%2Fplan" \
    "$(jq -nc --arg ns "$DB_NS" --arg payload "$ct" \
      '{namespace: $ns, secret_name: "e2e-secrets-app", payload: $payload, mode: "replace"}')"
  [[ "$HTTP_CODE" != "202" ]]
}

@test "plan/apply/get/delete against protected secrets fail PROTECTED_SECRET" {
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

  # Even read-only: fingerprints of root credentials enable offline
  # dictionary checks against a weak password
  run_secrets_task "get" "$(jq -nc --arg ns "$DB_NS" \
    '{namespace: $ns, secret_name: "mongodb-credentials"}')"
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
