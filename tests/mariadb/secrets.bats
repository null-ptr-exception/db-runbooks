#!/usr/bin/env bats
# =============================================================================
# E2E for the secrets/* gateway family on aqsh-mariadb (docs/mariadb/secrets.md).
#
# The scripts are shared with the MongoDB gateway verbatim; this file proves
# the family works against mariadb-1 and that the MariaDB deployment's
# protected list (SECRETS_PROTECTED_NAMES_DEFAULT=mariadb,minio — no live
# auto-detect for operator-managed root credentials, and
# SECRETS_AUTODETECT_DEFAULT=false) refuses root/infra secrets. Full
# failure-path coverage lives in tests/mongodb/secrets.bats. Shared
# plumbing: tests/test_helper/secrets_helpers.bash.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load '../test_helper/secrets_helpers'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="db-ops"
  AQSH_URL="http://aqsh-mariadb.kind-a.test:30080"
  DB_NS="mariadb-1"
  export CTX_A CTX_B NS AQSH_URL DB_NS

  secrets_suite_setup_file
}

teardown_file() {
  [[ -n "${SECRETS_GNUPG:-}" ]] && rm -rf "$SECRETS_GNUPG"
  kubectl --context "$CTX_A" -n "$DB_NS" delete secret \
    e2e-secrets-app e2e-secrets-stale --ignore-not-found
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load '../test_helper/secrets_helpers'
  if [[ -z "${SECRETS_GNUPG:-}" ]]; then
    skip "gpg is required for secrets/* e2e"
  fi
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

@test "add_only refuses overwriting an existing value (KEY_CONFLICT)" {
  local ct
  ct=$(_encrypt_payload '{"keys":{"monitor-pass":"clobber-attempt"}}')
  run_secrets_task "plan" "$(_plan_payload e2e-secrets-app "$ct" add_only)"
  assert_equal "$TASK_STATUS" "failed"
  assert_equal "$(echo "$RESULT_DATA" | jq -r '.reason_code')" "KEY_CONFLICT"
  assert_equal "$(_secret_value e2e-secrets-app monitor-pass)" "user-chosen-pass"
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

  # Even read-only fingerprints are refused for protected secrets
  run_secrets_task "get" "$(jq -nc --arg ns "$DB_NS" '{namespace: $ns, secret_name: "mariadb"}')"
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
