#!/usr/bin/env bash
# =============================================================================
# lib/secrets.sh
# Shared helpers for the secrets/* gateway task family (K8s Secret safe-write).
#
# DB-agnostic: the same scripts/secrets/*.sh serve both the aqsh-mongodb and
# aqsh-mariadb gateways. The caller encrypts a JSON payload
#   {"keys": {"KEY": "value", ...}}
# against the DEPLOYMENT-held PGP public key (secrets/pubkey returns it);
# plan/apply decrypt it in-pod, so plaintext values never appear in task
# inputs, gateway logs, argv, or task results — only key names, actions and
# sha256 digests do.
#
# Provides:
#   secrets_export_pubkey       — armored public key + fingerprint (from the
#                                 mounted private key; no separate pubkey file)
#   secrets_decrypt_payload     — armored-or-base64 ciphertext -> plaintext
#   secrets_validate_payload    — schema/key-name checks -> canonical JSON
#   secrets_get_existing        — live Secret JSON ("" when absent)
#   secrets_diff                — per-key create/update/unchanged report
#   secrets_plan_hash           — stateless CAS token (reconfig plan_hash model;
#                                 mode is hash material)
#   secrets_enforce_mode        — add_only: refuse overwriting existing values
#   secrets_effective_diff      — skip_existing: existing keys become "skipped"
#   secrets_filter_canonical    — skip_existing: write only the "create" keys
#   secrets_load_payload_or_fail — shared plan/apply front half (gate/decrypt/
#                                 validate/read + reason-code mapping)
#   secrets_write               — create via stdin manifest / merge-patch via
#                                 --patch-file /dev/stdin (values never in argv)
#   secrets_describe            — read-side report: key names + value sha256
#                                 fingerprints (secrets/get; values never leave)
#   secrets_delete              — kubectl delete (secrets/delete, confirm-gated)
#   secrets_resolve_protected_names — root-credential Secrets writes must refuse
#   secrets_fail / secrets_write_result — account-style task result helpers
#
# Depends on: logging.sh, k8s.sh (sourced by callers; k8s.sh itself needs
# response.sh). mongodb-recovery.sh is sourced lazily inside
# secrets_resolve_protected_names (read-only reuse of its credential
# detection; in a non-MongoDB namespace detection fails soft and only the
# internal-config list applies, and SECRETS_AUTODETECT_DEFAULT=false skips
# it entirely).
# =============================================================================

[[ -n "${_SECRETS_LIB_LOADED:-}" ]] && return 0
_SECRETS_LIB_LOADED=1

# Internal config (deploy-time conventions — see CLAUDE.md "Configuration
# Layers"). Sourced at module load so *_DEFAULT values are visible before the
# calling script's own config lines run. Only one of the two files exists in
# a given deployment (mongodb.env on the MongoDB gateway, mariadb.env on the
# MariaDB one); all keys are *_DEFAULT-suffixed so sourcing can never clobber
# an explicit caller value.
# shellcheck disable=SC1091
[[ -f /etc/aqsh/config/mongodb.env ]] && source /etc/aqsh/config/mongodb.env
# shellcheck disable=SC1091
[[ -f /etc/aqsh/config/mariadb.env ]] && source /etc/aqsh/config/mariadb.env

_SECRETS_PGP_KEY_PATH="${SECRETS_PGP_KEY_PATH_DEFAULT:-/etc/aqsh/pgp/private.asc}"
_SECRETS_PROTECTED_EXPLICIT="${SECRETS_PROTECTED_NAMES_DEFAULT:-}"
_SECRETS_AUTODETECT="${SECRETS_AUTODETECT_DEFAULT:-true}"

# K8s Secret data key charset (DNS-subdomain-ish, same rule the API server
# enforces) — validated up front so a bad key fails as INVALID_INPUT instead
# of a confusing kubectl error.
_SECRETS_KEY_NAME_RE='^[-._a-zA-Z0-9]+$'

# ---------------------------------------------------------------------------
# Task result helpers — same JSON shape as the account family
# ({status, reason_code, summary, details}) so callers/tests assert failures
# uniformly across gateways. Local copies of mongodb-account.sh's
# write_task_result/fail_task/bool_enabled: sourcing a mongo-named lib from
# a DB-agnostic family would misstate the dependency, and no shared
# task-common lib exists yet (extracting one touches the account family —
# tracked as future work, needs its own discussion).
# ---------------------------------------------------------------------------
secrets_bool_enabled() {
  case "${1:-false}" in
    1 | true | TRUE | yes | YES | on | ON) return 0 ;;
    *) return 1 ;;
  esac
}

secrets_write_result() {
  local json_payload="${1:?json payload is required}"
  if [[ -n "${AQSH_RESULT_FILE:-}" ]]; then
    printf '%s\n' "$json_payload" > "$AQSH_RESULT_FILE"
  else
    printf '%s\n' "$json_payload"
  fi
}

secrets_fail() {
  local reason="${1:-ERROR}"
  local summary="${2:-operation failed}"
  local details_raw="${3-}"
  local details

  [[ -n "$details_raw" ]] || details_raw='{}'
  details=$(jq -nc --arg raw "$details_raw" 'try ($raw | fromjson) catch {raw_detail:$raw}')

  log_error "secrets" "${reason}: ${summary}"
  secrets_write_result "$(jq -n \
    --arg status "ERROR" \
    --arg reason_code "$reason" \
    --arg summary "$summary" \
    --argjson details "$details" \
    '{status: $status, reason_code: $reason_code, summary: $summary, details: $details}')"
  exit 1
}

# ---------------------------------------------------------------------------
# _secrets_gnupg_import
# Create an ephemeral GNUPGHOME and import the deployment private key into
# it, leaving GNUPGHOME exported for the caller's follow-up gpg call. Sets
# no trap itself — a RETURN trap here would wipe the keyring the moment this
# helper returns. Instead each PUBLIC entry point that calls it (the same
# function that also runs the gpg operation, mirroring why
# encrypt_password_payload's in-function trap is safe) sets its own cleanup
# trap on RETURN — which also fires inside $(...) subshells, where an EXIT
# trap would not.
# Returns 1 when the key file is missing or does not import (the caller maps
# that to PGP_KEY_UNAVAILABLE).
# ---------------------------------------------------------------------------
_secrets_gnupg_import() {
  local gnupg_home

  if [[ ! -r "$_SECRETS_PGP_KEY_PATH" ]]; then
    log_debug "secrets" "deployment PGP key not readable at ${_SECRETS_PGP_KEY_PATH}"
    return 1
  fi

  gnupg_home=$(mktemp -d)
  chmod 700 "$gnupg_home"
  export GNUPGHOME="$gnupg_home"

  if ! gpg --batch --import "$_SECRETS_PGP_KEY_PATH" >/dev/null 2>&1; then
    log_debug "secrets" "gpg import of deployment key failed"
    return 1
  fi
  log_debug "secrets" "deployment PGP key imported into ephemeral GNUPGHOME"
  return 0
}

_secrets_key_fingerprint() {
  gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}'
}

# ---------------------------------------------------------------------------
# secrets_export_pubkey
# Print {"public_key": "<armored>", "fingerprint": "<hex>"} derived from the
# mounted private key. Returns 1 when the key is unavailable.
# ---------------------------------------------------------------------------
secrets_export_pubkey() {
  local fingerprint armored
  trap '[[ -n "${GNUPGHOME:-}" ]] && rm -rf "$GNUPGHOME" && unset GNUPGHOME' RETURN

  _secrets_gnupg_import || return 1
  fingerprint=$(_secrets_key_fingerprint)
  [[ -z "$fingerprint" ]] && return 1
  armored=$(gpg --batch --armor --export "$fingerprint" 2>/dev/null) || return 1
  [[ -z "$armored" ]] && return 1
  log_debug "secrets" "exported public key fingerprint=${fingerprint}"
  jq -nc --arg public_key "$armored" --arg fingerprint "$fingerprint" \
    '{public_key: $public_key, fingerprint: $fingerprint, content_type: "application/pgp-keys"}'
}

# ---------------------------------------------------------------------------
# secrets_decrypt_payload <ciphertext-input>
# Accepts an ASCII-armored PGP message or its base64 encoding (same
# dual-format tolerance as recipient_pgp_pubkey in the account family).
# Prints the decrypted plaintext on stdout. NEVER logs plaintext — only the
# detected input format and decrypted byte count.
# Return codes: 1 = key unavailable, 2 = decrypt failed.
# ---------------------------------------------------------------------------
secrets_decrypt_payload() {
  local ciphertext_input="${1:?ciphertext is required}"
  local armored decoded plaintext
  trap '[[ -n "${GNUPGHOME:-}" ]] && rm -rf "$GNUPGHOME" && unset GNUPGHOME' RETURN

  if printf '%s' "$ciphertext_input" | grep -q 'BEGIN PGP MESSAGE'; then
    armored="$ciphertext_input"
    log_debug "secrets" "payload format: ascii-armored"
  else
    decoded=$(printf '%s' "$ciphertext_input" | base64 -d 2>/dev/null || true)
    if [[ -n "$decoded" ]] && printf '%s' "$decoded" | grep -q 'BEGIN PGP MESSAGE'; then
      armored="$decoded"
      log_debug "secrets" "payload format: base64(ascii-armored)"
    else
      log_debug "secrets" "payload is neither armored PGP nor base64(armored PGP)"
      return 2
    fi
  fi

  _secrets_gnupg_import || return 1

  if ! plaintext=$(printf '%s' "$armored" | gpg --batch --quiet --decrypt 2>/dev/null); then
    log_debug "secrets" "gpg --decrypt failed (wrong recipient key or corrupt message)"
    return 2
  fi
  log_debug "secrets" "payload decrypted (${#plaintext} bytes)"
  printf '%s' "$plaintext"
}

# ---------------------------------------------------------------------------
# secrets_validate_payload <plaintext>
# Enforce the payload contract: a JSON object {"keys": {<name>: <string>}}
# with at least one entry, names matching the K8s data-key charset, values
# strings. Prints the canonical (sorted, compact) form — the stable input for
# payload_digest. Return codes: 1 = not the expected JSON shape,
# 2 = bad key name (caller maps to PAYLOAD_INVALID / INVALID_INPUT).
# ---------------------------------------------------------------------------
secrets_validate_payload() {
  local plaintext="${1:?payload plaintext is required}"
  local canonical key_names name

  canonical=$(printf '%s' "$plaintext" | jq -cS '
    if (type == "object") and ((.keys | type) == "object") and ((.keys | length) > 0)
       and ([.keys[] | type == "string"] | all)
    then {keys: .keys} else error("shape") end' 2>/dev/null) || {
    log_debug "secrets" "payload failed schema check (want {\"keys\":{name:string,...}})"
    return 1
  }

  key_names=$(printf '%s' "$canonical" | jq -r '.keys | keys[]')
  while IFS= read -r name; do
    name="${name%$'\r'}"   # jq emits CRLF on Windows hosts (local dev runs)
    if [[ ! "$name" =~ $_SECRETS_KEY_NAME_RE ]]; then
      log_debug "secrets" "invalid data key name: ${name}"
      return 2
    fi
  done <<< "$key_names"

  log_debug "secrets" "payload valid: $(printf '%s' "$canonical" | jq -r '.keys | length') key(s): $(printf '%s' "$key_names" | tr '\n' ' ')"
  printf '%s' "$canonical"
}

secrets_payload_digest() {
  local canonical="${1:?canonical payload is required}"
  printf '%s' "$canonical" | sha256sum | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# secrets_get_existing <secret_name>
# Print the live Secret as JSON, or nothing when it does not exist.
# Returns 1 on any error other than NotFound (RBAC denial, API outage) — and
# prints kubectl's stderr text in that case (instead of only log_debug'ing
# it) so the caller can surface the real API error in OPERATION_FAILED's
# details, not just a generic "API error or RBAC denial" guess. Task logs
# (where log_debug lands) aren't captured by CI/most callers, so this was
# previously a silent failure mode with no way to diagnose it after the
# fact.
# ---------------------------------------------------------------------------
secrets_get_existing() {
  local secret_name="${1:?secret name is required}"
  local out err rc

  err=$(mktemp)
  out=$(_kubectl get secret "$secret_name" -o json 2>"$err") && rc=0 || rc=$?
  if (( rc != 0 )); then
    local err_out
    err_out=$(cat "$err")
    rm -f "$err"
    if printf '%s' "$err_out" | grep -qi 'NotFound'; then
      log_debug "secrets" "secret ${secret_name} does not exist"
      return 0
    fi
    log_debug "secrets" "kubectl get secret ${secret_name} failed: ${err_out}"
    printf '%s' "$err_out"
    return 1
  fi
  rm -f "$err"
  log_debug "secrets" "secret ${secret_name} exists resourceVersion=$(printf '%s' "$out" | jq -r '.metadata.resourceVersion')"
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# secrets_plan_hash <namespace> <secret_name> <payload_digest> <resource_version> <mode>
# Stateless CAS token, same model as _reconfig_plan_hash: apply recomputes it
# from live state and refuses on mismatch (PLAN_STALE). resource_version is
# the live Secret's metadata.resourceVersion, or "absent" when it does not
# exist — so both an external edit AND a create-in-between invalidate a plan.
# mode is part of the hash material so a plan made under add_only cannot be
# applied as an upsert (or vice versa). No storage, no TTL.
# ---------------------------------------------------------------------------
secrets_plan_hash() {
  local namespace="${1:?}" secret_name="${2:?}" payload_digest="${3:?}" resource_version="${4:?}" mode="${5:?}"
  local h
  h=$(printf '%s|%s|%s|%s|%s' "$namespace" "$secret_name" "$payload_digest" "$resource_version" "$mode" \
    | sha256sum | cut -c1-24)
  log_debug "secrets" "plan_hash inputs: ns=${namespace} secret=${secret_name} payload_digest=${payload_digest} rv=${resource_version} mode=${mode}"
  printf 'sec%s' "$h"
}

# ---------------------------------------------------------------------------
# secrets_validate_mode <mode>
# Fail INVALID_INPUT unless mode is exactly upsert/add_only/skip_existing —
# called by both plan and apply so a typo'd mode (e.g. "addonly") can never
# silently behave like upsert and defeat add_only's overwrite protection.
# ---------------------------------------------------------------------------
secrets_validate_mode() {
  local mode="${1:?}"

  case "$mode" in
    upsert|add_only|skip_existing) return 0 ;;
  esac
  secrets_fail "INVALID_INPUT" \
    "mode must be one of upsert, add_only, skip_existing (got: ${mode})" \
    "$(jq -nc --arg mode "$mode" '{mode: $mode}')"
}

# ---------------------------------------------------------------------------
# secrets_enforce_mode <mode> <diff_json>
# add_only: refuse (KEY_CONFLICT) when the payload would change an EXISTING
# key's value. New keys (create) and byte-identical re-pushes (unchanged)
# pass — add_only is "existing values may never be clobbered", not
# "the secret may never be touched". skip_existing never fails here — its
# would-be overwrites are silently dropped instead
# (secrets_effective_diff/secrets_filter_canonical).
# ---------------------------------------------------------------------------
secrets_enforce_mode() {
  local mode="${1:?}" diff="${2:?}"
  local conflicts

  [[ "$mode" == "add_only" ]] || return 0
  conflicts=$(printf '%s' "$diff" | jq -c '[.changes[] | select(.action=="update") | .key]')
  if [[ "$conflicts" != "[]" ]]; then
    secrets_fail "KEY_CONFLICT" \
      "add_only mode: payload would overwrite existing values for the keys in details; re-plan without those keys or use mode=upsert deliberately" \
      "$(jq -nc --argjson keys "$conflicts" '{conflicting_keys: $keys}')"
  fi
  log_debug "secrets" "add_only check passed (no existing value would change)"
}

# ---------------------------------------------------------------------------
# secrets_effective_diff <mode> <diff_json>
# skip_existing (SQL INSERT IGNORE semantics): every key that already exists
# — same value or not — becomes action "skipped" and will not be written;
# only "create" keys remain actionable. Other modes pass the diff through.
# ---------------------------------------------------------------------------
secrets_effective_diff() {
  local mode="${1:?}" diff="${2:?}"

  if [[ "$mode" != "skip_existing" ]]; then
    printf '%s' "$diff"
    return 0
  fi
  printf '%s' "$diff" | jq -c '
    (.changes | map(if .action == "create" then . else {key: .key, action: "skipped"} end)) as $changes
    | .changes = $changes
    | .summary = {create:    ($changes | map(select(.action=="create"))  | length),
                  update:    0,
                  unchanged: 0,
                  skipped:   ($changes | map(select(.action=="skipped")) | length)}'
}

# ---------------------------------------------------------------------------
# secrets_filter_canonical <mode> <canonical_payload> <effective_diff>
# The payload that actually gets written: under skip_existing only the keys
# the effective diff marks "create" survive; other modes write the payload
# as-is.
# ---------------------------------------------------------------------------
secrets_filter_canonical() {
  local mode="${1:?}" canonical="${2:?}" diff="${3:?}"

  if [[ "$mode" != "skip_existing" ]]; then
    printf '%s' "$canonical"
    return 0
  fi
  jq -nc --argjson payload "$canonical" --argjson diff "$diff" '
    ($diff.changes | map(select(.action=="create") | .key)) as $keep
    | {keys: ($payload.keys | with_entries(select(.key as $k | $keep | index($k))))}'
}

secrets_resource_version_of() {
  local existing_json="${1-}"
  if [[ -z "$existing_json" ]]; then
    printf 'absent'
  else
    printf '%s' "$existing_json" | jq -r '.metadata.resourceVersion'
  fi
}

# ---------------------------------------------------------------------------
# secrets_diff <existing_json-or-empty> <canonical_payload>
# Per-key report without ever emitting a value: payload values are compared
# against live .data as base64 (both sides standard no-wrap encoding, so
# equal bytes mean equal strings). Prints
#   {"changes":[{"key":k,"action":"create|update|unchanged"}],
#    "retained_keys":[...], "summary":{"create":n,"update":n,"unchanged":n}}
# retained_keys = live keys the payload does not mention; merge semantics
# leave them untouched.
# ---------------------------------------------------------------------------
secrets_diff() {
  local existing_json="${1-}"
  local canonical="${2:?canonical payload is required}"
  local existing_data diff

  if [[ -z "$existing_json" ]]; then
    existing_data='{}'
  else
    existing_data=$(printf '%s' "$existing_json" | jq -c '.data // {}')
  fi

  diff=$(jq -nc --argjson existing "$existing_data" --argjson payload "$canonical" '
    ($payload.keys | to_entries | map(
      .key as $k | (.value | @base64) as $b64
      | {key: $k,
         action: (if ($existing | has($k)) | not then "create"
                  elif $existing[$k] == $b64 then "unchanged"
                  else "update" end)}
    )) as $changes
    | {changes: $changes,
       retained_keys: ($existing | keys - ($payload.keys | keys)),
       summary: {create:    ($changes | map(select(.action=="create"))    | length),
                 update:    ($changes | map(select(.action=="update"))    | length),
                 unchanged: ($changes | map(select(.action=="unchanged")) | length),
                 skipped:   0}}')
  log_debug "secrets" "diff: $(printf '%s' "$diff" | jq -c '{summary, retained: (.retained_keys | length)}')"
  printf '%s' "$diff"
}

# ---------------------------------------------------------------------------
# secrets_write <namespace> <secret_name> <canonical_payload> <exists:true|false> <resource_version>
# Values never touch argv or logs: create ships a full manifest on stdin
# (kubectl create -f -), update ships a strategic-merge data patch via
# --patch-file /dev/stdin (kubectl patch -p would land the base64 values in
# /proc/<pid>/cmdline). Merge-only: keys absent from the payload are left as
# they are. Prints "created" or "patched".
#
# The patch body carries metadata.resourceVersion (the value the caller's
# plan_hash was computed against) so the API server enforces the same
# freshness precondition atomically as part of the write itself — closing
# the gap between apply.sh's own live_hash recompute and this call, where an
# external edit could otherwise land unnoticed. A server-side rejection of
# that precondition (409 Conflict, "the object has been modified") is
# reported as return code 2, distinct from other failures (1), so the caller
# can map it to PLAN_STALE instead of a generic write failure.
# ---------------------------------------------------------------------------
secrets_write() {
  local namespace="${1:?}" secret_name="${2:?}" canonical="${3:?}" exists="${4:?}" resource_version="${5:?}"
  local data_b64 out rc

  data_b64=$(printf '%s' "$canonical" | jq -c '.keys | map_values(@base64)')

  if [[ "$exists" == "true" ]]; then
    log_debug "secrets" "patching secret ${secret_name} (merge, $(printf '%s' "$data_b64" | jq 'length') key(s), resourceVersion=${resource_version})"
    out=$(jq -nc --argjson data "$data_b64" --arg rv "$resource_version" \
        '{metadata: {resourceVersion: $rv}, data: $data}' \
      | _kubectl patch secret "$secret_name" --type merge --patch-file /dev/stdin 2>&1) && rc=0 || rc=$?
    if (( rc != 0 )); then
      if printf '%s' "$out" | grep -qi 'conflict\|has been modified'; then
        log_error "secrets" "kubectl patch secret ${secret_name} rejected stale resourceVersion=${resource_version}: ${out}"
        return 2
      fi
      log_error "secrets" "kubectl patch secret ${secret_name} failed: ${out}"
      return 1
    fi
    printf 'patched'
  else
    log_debug "secrets" "creating secret ${secret_name} ($(printf '%s' "$data_b64" | jq 'length') key(s))"
    out=$(jq -nc --arg name "$secret_name" --arg ns "$namespace" --argjson data "$data_b64" \
        '{apiVersion: "v1", kind: "Secret",
          metadata: {name: $name, namespace: $ns},
          type: "Opaque", data: $data}' \
      | _kubectl create -f - 2>&1) && rc=0 || rc=$?
    if (( rc != 0 )); then
      log_error "secrets" "kubectl create secret ${secret_name} failed: ${out}"
      return 1
    fi
    printf 'created'
  fi
}

# ---------------------------------------------------------------------------
# secrets_describe <existing_json>
# Read-side report for secrets/get and the delete preview: metadata plus, per
# data key, the sha256 of the DECODED value — enough for a caller to check
# drift ("is the deployed password still the one I pushed?") without the
# value itself ever entering a task result.
# ---------------------------------------------------------------------------
secrets_describe() {
  local existing_json="${1:?secret json is required}"
  local key b64 sha rows="" keys_json

  # One jq pass emits key<TAB>base64; the loop only hashes (2 subprocesses
  # per key) and accumulates plain lines; one final jq assembles the array —
  # instead of re-parsing the Secret and the growing array per key.
  while IFS=$'\t' read -r key b64 || [[ -n "$key" ]]; do
    key="${key%$'\r'}"; b64="${b64%$'\r'}"   # jq emits CRLF on Windows hosts (local dev runs)
    [[ -z "$key" ]] && continue
    sha=$(printf '%s' "$b64" | base64 -d | sha256sum)
    rows+="${key}"$'\t'"${sha%% *}"$'\n'
  done < <(printf '%s' "$existing_json" | jq -r '.data // {} | to_entries[] | "\(.key)\t\(.value)"')

  keys_json=$(printf '%s' "$rows" | jq -Rn \
    '[inputs | select(length > 0) | split("\t") | {key: .[0], value_sha256: .[1]}]')
  printf '%s' "$existing_json" | jq -c --argjson keys "$keys_json" \
    '{secret_name: .metadata.name,
      namespace: .metadata.namespace,
      type: .type,
      resource_version: .metadata.resourceVersion,
      created_at: .metadata.creationTimestamp,
      keys: $keys}'
}

# ---------------------------------------------------------------------------
# secrets_delete <secret_name>
# Plain kubectl delete; the confirm gate and protected check live in the
# calling script (secrets/delete).
# ---------------------------------------------------------------------------
secrets_delete() {
  local secret_name="${1:?}"
  local out rc

  out=$(_kubectl delete secret "$secret_name" 2>&1) && rc=0 || rc=$?
  if (( rc != 0 )); then
    log_error "secrets" "kubectl delete secret ${secret_name} failed: ${out}"
    return 1
  fi
  log_debug "secrets" "deleted secret ${secret_name}"
  return 0
}

# ---------------------------------------------------------------------------
# secrets_resolve_protected_names
# Newline-separated Secret names this family refuses to write
# (PROTECTED_SECRET), resolved without any caller input:
#   1. Internal config — SECRETS_PROTECTED_NAMES_DEFAULT (comma/space list;
#      the only option for conventions with no live signal, e.g. an
#      operator-managed MariaDB root secret)
#   2. Auto-detect — the root-credential Secret wired into the namespace's
#      StatefulSet env, via mongodb-recovery.sh's _recovery_detect_sts_name /
#      _recovery_detect_credentials (read-only reuse; covers both the
#      official MONGO_INITDB_ROOT_* and Bitnami MONGODB_ROOT_* / *_FILE
#      conventions). Fails soft in namespaces where no such wiring exists.
# There is deliberately NO per-call override — same posture as the
# recovery/* auto-detect tier.
# ---------------------------------------------------------------------------
secrets_resolve_protected_names() {
  local detected_sts cred_row detected_secret

  if [[ -n "$_SECRETS_PROTECTED_EXPLICIT" ]]; then
    printf '%s\n' "$_SECRETS_PROTECTED_EXPLICIT" | tr ', ' '\n' | awk 'NF'
    log_debug "secrets" "protected (internal config): ${_SECRETS_PROTECTED_EXPLICIT}"
  fi

  # Deployments that know detection cannot succeed (e.g. MariaDB gateways —
  # operator root credentials carry no env signal this detector reads) set
  # SECRETS_AUTODETECT_DEFAULT=false and save two kubectl round trips per
  # plan/apply/delete call.
  if [[ "$_SECRETS_AUTODETECT" != "true" ]]; then
    log_debug "secrets" "root-credential auto-detect disabled by internal config"
    return 0
  fi

  # shellcheck source=aqsh-tasks/lib/mongodb-recovery.sh
  source "${LIB_DIR:-/tasks/lib}/mongodb-recovery.sh"
  detected_sts=$(_recovery_detect_sts_name "" 2>/dev/null) || detected_sts=""
  if [[ -n "$detected_sts" ]]; then
    cred_row=$(_recovery_detect_credentials "$detected_sts" 2>/dev/null) || cred_row=""
    if [[ -n "$cred_row" ]]; then
      IFS=$'\x1f' read -r detected_secret _ _ _ <<< "$cred_row"
      if [[ -n "$detected_secret" ]]; then
        log_debug "secrets" "protected (detected from sts/${detected_sts} env): ${detected_secret}"
        printf '%s\n' "$detected_secret"
      fi
    else
      log_debug "secrets" "sts/${detected_sts} has no detectable root-credential wiring (fail-soft)"
    fi
  else
    log_debug "secrets" "no unambiguous StatefulSet in namespace (fail-soft, config list only)"
  fi
}

secrets_is_protected() {
  local secret_name="${1:?}" protected
  protected=$(secrets_resolve_protected_names)
  grep -Fxq "$secret_name" <<< "$protected"
}

# ---------------------------------------------------------------------------
# secrets_load_payload_or_fail <secret_name> <payload_ciphertext>
# The shared front half of plan and apply: protected gate → decrypt →
# validate → read live state, with the reason-code mapping in ONE place so
# both tasks report identical codes for identical inputs. Exits via
# secrets_fail on any failure. On success sets globals:
#   SECRETS_CANONICAL — canonical payload JSON
#   SECRETS_EXISTING  — live Secret JSON ("" when absent)
#   SECRETS_EXISTS    — "true" | "false"
# ---------------------------------------------------------------------------
secrets_load_payload_or_fail() {
  local secret_name="${1:?}" ciphertext="${2:?}"
  local plaintext rc

  if secrets_is_protected "$secret_name"; then
    secrets_fail "PROTECTED_SECRET" \
      "refusing to touch a protected secret (root credentials); no per-call override exists" \
      "$(jq -nc --arg name "$secret_name" '{secret_name: $name}')"
  fi

  plaintext=$(secrets_decrypt_payload "$ciphertext") && rc=0 || rc=$?
  if (( rc == 1 )); then
    secrets_fail "PGP_KEY_UNAVAILABLE" "deployment PGP private key is missing or unreadable"
  elif (( rc != 0 )); then
    secrets_fail "DECRYPT_FAILED" \
      "payload does not decrypt with the deployment key (wrong recipient key, corrupt message, or not PGP at all) — fetch the current key via secrets/pubkey"
  fi

  SECRETS_CANONICAL=$(secrets_validate_payload "$plaintext") && rc=0 || rc=$?
  unset plaintext
  if (( rc == 2 )); then
    secrets_fail "INVALID_INPUT" "payload contains a data key name outside [-._a-zA-Z0-9]"
  elif (( rc != 0 )); then
    secrets_fail "PAYLOAD_INVALID" \
      'decrypted payload is not {"keys": {name: string-value, ...}} with at least one entry'
  fi

  local get_rc
  SECRETS_EXISTING=$(secrets_get_existing "$secret_name") && get_rc=0 || get_rc=$?
  if (( get_rc != 0 )); then
    secrets_fail "OPERATION_FAILED" "cannot read live secret state (API error or RBAC denial)" \
      "$(jq -nc --arg detail "$SECRETS_EXISTING" '{detail: $detail}')"
  fi
  if [[ -n "$SECRETS_EXISTING" ]]; then SECRETS_EXISTS="true"; else SECRETS_EXISTS="false"; fi
  export SECRETS_CANONICAL SECRETS_EXISTING SECRETS_EXISTS
}
