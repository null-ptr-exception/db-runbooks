#!/usr/bin/env bash
# =============================================================================
# mongodb-pbm.sh — Percona Backup for MongoDB (PBM) helpers for the pbm/*
# aqsh tasks (see docs/mongodb/pbm.md).
#
# Execution model: every PBM command runs INSIDE the pbm-agent sidecar
# container of a mongo pod (kubectl exec -c <agent>) — the pbm CLI inherits
# PBM_MONGODB_URI from that container's env, so these tasks never load
# MongoDB credentials into aqsh at all. The only secret aqsh reads is the
# S3 credentials secret (for `pbm config` payloads and bucket creation).
#
# Dependencies (sourced by the calling script, not here):
#   logging.sh           — log_debug/log_info/log_warn/log_error
#   k8s.sh               — _kubectl
#   mongodb-recovery.sh  — _recovery_list_pods, recovery_resolve_sts_name
#   mongodb-account.sh   — fail_task/write_task_result/bool_enabled
#   minio-client.sh      — setup_minio_client, ensure_bucket
#
# All `pbm ... -o json` round trips are validated with a jq parse before
# being trusted: kubectl merges its own error text into the exec output, so
# a kubectl-layer failure would otherwise be indistinguishable from real
# JSON (same defensive idiom as the sentinel prefixes in mongodb-fcv.sh).
# =============================================================================

[[ -n "${_MONGODB_PBM_LIB_LOADED:-}" ]] && return 0
_MONGODB_PBM_LIB_LOADED=1

# Internal config (*_DEFAULT knobs). mongodb-recovery.sh sources this too;
# re-sourcing is harmless — the file only sets *_DEFAULT-suffixed names, so
# it can never clobber an explicit caller value (see CLAUDE.md).
[[ -f /etc/aqsh/config/mongodb.env ]] && source /etc/aqsh/config/mongodb.env

# Poll cadence for backup/restore wait loops (seconds).
_PBM_POLL_INTERVAL="${_PBM_POLL_INTERVAL:-10}"

# ---------------------------------------------------------------------------
# _pbm_detect_agent_container <sts_name>
# Auto-detect tier: read the StatefulSet's own pod template and return the
# name of the container that carries PBM_MONGODB_URI in its env (value or
# valueFrom — authoritative signal), falling back to an image-name match on
# "percona-backup-mongodb". Fails soft (rc 1, empty stdout) — never guesses.
# ---------------------------------------------------------------------------
_pbm_detect_agent_container() {
  local sts_name="${1:?sts_name is required}"
  local sts_json name
  sts_json=$(_kubectl get statefulset "$sts_name" -o json 2>/dev/null) || return 1
  [[ -z "$sts_json" ]] && return 1
  name=$(printf '%s' "$sts_json" | jq -r '
    [.spec.template.spec.containers[]?
      | select(any(.env[]?; .name == "PBM_MONGODB_URI"))][0].name // empty' 2>/dev/null)
  if [[ -z "$name" ]]; then
    name=$(printf '%s' "$sts_json" | jq -r '
      [.spec.template.spec.containers[]?
        | select(.image | test("percona-backup-mongodb"))][0].name // empty' 2>/dev/null)
  fi
  [[ -z "$name" ]] && return 1
  printf '%s' "$name"
}

# ---------------------------------------------------------------------------
# pbm_resolve_agent_container <explicit> <sts_name>
# 3-tier chain: internal config (passed as <explicit>) -> live auto-detect ->
# hardcoded literal "pbm-agent" (accepted only when a container of that name
# actually exists on the StatefulSet — unlike a naming convention, a missing
# sidecar means the feature is not deployed at all, so we fail rather than
# hand back a name kubectl exec would reject with a less actionable error).
# ---------------------------------------------------------------------------
pbm_resolve_agent_container() {
  local explicit="${1:-}" sts_name="${2:?sts_name is required}"
  if [[ -n "$explicit" ]]; then
    log_debug "mongo-pbm" "agent container from internal config: ${explicit}"
    printf '%s' "$explicit"
    return 0
  fi
  local detected
  detected=$(_pbm_detect_agent_container "$sts_name") || detected=""
  if [[ -n "$detected" ]]; then
    log_debug "mongo-pbm" "agent container auto-detected on STS ${sts_name}: ${detected}"
    printf '%s' "$detected"
    return 0
  fi
  local names n
  names=$(_kubectl get statefulset "$sts_name" \
    -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null) || names=""
  for n in $names; do
    if [[ "$n" == "pbm-agent" ]]; then
      log_debug "mongo-pbm" "agent container from literal fallback: pbm-agent"
      printf 'pbm-agent'
      return 0
    fi
  done
  log_debug "mongo-pbm" "no pbm-agent signal on STS ${sts_name} (containers: ${names:-<none>})"
  return 1
}

# ---------------------------------------------------------------------------
# _pbm_probe_pod <sts_name>
# Echo the name of a Ready pod of the StatefulSet (fallback: any Running
# pod) to exec pbm from. Same Ready-first loop as _fcv_probe_pod — each lib
# carries its own copy by convention rather than reaching into another lib's
# private helpers.
# ---------------------------------------------------------------------------
_pbm_probe_pod() {
  local sts_name="${1:?sts_name is required}"
  local pods_raw probe="" pod
  pods_raw=$(_recovery_list_pods "$sts_name") || return 1
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    local pod_ready
    pod_ready=$(_kubectl get pod "$pod" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || continue
    [[ "$pod_ready" == "True" ]] && {
      probe="$pod"
      break
    }
  done <<< "$pods_raw"
  if [[ -z "$probe" ]]; then
    while IFS= read -r pod; do
      [[ -z "$pod" ]] && continue
      local phase
      phase=$(_kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null) || continue
      [[ "$phase" == "Running" ]] && {
        probe="$pod"
        break
      }
    done <<< "$pods_raw"
  fi
  [[ -z "$probe" ]] && return 1
  printf '%s\n' "$probe"
}

# ---------------------------------------------------------------------------
# pbm_task_init <op>
# Shared preamble for every pbm/* task script: resolve the StatefulSet, the
# agent sidecar container, and a probe pod, exporting PBM_STS /
# PBM_AGENT_CONTAINER / PBM_POD. Calls fail_task (which exits) on the two
# genuinely terminal conditions so scripts don't repeat the boilerplate.
# ---------------------------------------------------------------------------
pbm_task_init() {
  local op="${1:?op is required}"
  PBM_STS=$(recovery_resolve_sts_name "${MONGO_STS_NAME_DEFAULT:-}" "")
  log_debug "$op" "resolved StatefulSet: ${PBM_STS}"
  if ! PBM_AGENT_CONTAINER=$(pbm_resolve_agent_container "${PBM_AGENT_CONTAINER_DEFAULT:-}" "$PBM_STS"); then
    local containers
    containers=$(_kubectl get statefulset "$PBM_STS" \
      -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null) || containers=""
    fail_task "NO_PBM_AGENT" \
      "no pbm-agent sidecar found on StatefulSet ${PBM_STS} in ${DB_NAMESPACE}" \
      "$(jq -nc --arg sts "$PBM_STS" --arg containers "${containers:-<statefulset not found>}" \
        '{sts:$sts, containers:$containers,
          hint:"pbm/* tasks need a pbm-agent sidecar (image percona/percona-backup-mongodb with PBM_MONGODB_URI env) alongside every mongod, and mongod must run as a replica set; see docs/mongodb/pbm.md#deployment-requirements"}')"
  fi
  PBM_POD=$(_pbm_probe_pod "$PBM_STS") \
    || fail_task "NO_READY_POD" "no Ready/Running pod for StatefulSet ${PBM_STS} in ${DB_NAMESPACE}"
  log_info "$op" "STS=${PBM_STS} agent_container=${PBM_AGENT_CONTAINER} probe_pod=${PBM_POD}"
}

# ---------------------------------------------------------------------------
# _pbm_exec <pod> <container> <pbm args...>
# Run the pbm CLI inside the agent sidecar. stdout+stderr are merged (the
# caller decides how to interpret them); rc is passed through. Every
# invocation and its (truncated) output is DEBUG-logged — pbm args never
# carry credentials (config payloads go through _pbm_exec_stdin).
# ---------------------------------------------------------------------------
_pbm_exec() {
  local pod="${1:?pod is required}" container="${2:?container is required}"
  shift 2
  log_debug "mongo-pbm" "exec pod=${pod} container=${container}: pbm $*"
  local out rc=0
  out=$(_kubectl exec "$pod" -c "$container" -- pbm "$@" 2>&1) || rc=$?
  log_debug "mongo-pbm" "pbm ${1:-} rc=${rc} output(truncated): ${out:0:2000}"
  printf '%s' "$out"
  return "$rc"
}

# ---------------------------------------------------------------------------
# _pbm_exec_stdin <pod> <container> <stdin_payload> <pbm args...>
# Same as _pbm_exec but feeds <stdin_payload> to the command's stdin
# (kubectl exec -i). Used for `pbm config --file /dev/stdin` so S3
# credentials never appear on a command line or in DEBUG logs.
# ---------------------------------------------------------------------------
_pbm_exec_stdin() {
  local pod="${1:?pod is required}" container="${2:?container is required}"
  local payload="${3:?stdin payload is required}"
  shift 3
  log_debug "mongo-pbm" "exec (stdin) pod=${pod} container=${container}: pbm $*"
  local out rc=0
  out=$(_kubectl exec -i "$pod" -c "$container" -- pbm "$@" <<< "$payload" 2>&1) || rc=$?
  log_debug "mongo-pbm" "pbm ${1:-} rc=${rc} output(truncated): ${out:0:2000}"
  printf '%s' "$out"
  return "$rc"
}

# ---------------------------------------------------------------------------
# _pbm_exec_json <pod> <container> <pbm args...>
# _pbm_exec with `-o json` appended; the output is trusted only if it parses
# as JSON (compacted). On parse failure or nonzero rc the raw output is
# printed and rc 1 propagated so callers can surface the real error text.
# ---------------------------------------------------------------------------
_pbm_exec_json() {
  local pod="${1:?pod is required}" container="${2:?container is required}"
  shift 2
  local out rc=0 json
  out=$(_pbm_exec "$pod" "$container" "$@" -o json) || rc=$?
  json=$(printf '%s' "$out" | jq -c . 2>/dev/null) || {
    printf '%s' "$out"
    return 1
  }
  if (( rc != 0 )); then
    printf '%s' "$out"
    return "$rc"
  fi
  printf '%s' "$json"
}

# ---------------------------------------------------------------------------
# pbm_resolve_backup_location <namespace>
# Export PBM_BUCKET / PBM_PREFIX / PBM_ENDPOINT / PBM_REGION following the
# house convention (mirror of mdbt_resolve_backup_location): bucket
# "db-backups", per-namespace prefix "mongodb/<ns>", endpoint from the
# deployment's MINIO_ENDPOINT. All overridable via internal config only —
# storage location is infra, never a task input.
# ---------------------------------------------------------------------------
pbm_resolve_backup_location() {
  local namespace="${1:?namespace is required}"
  PBM_BUCKET="${PBM_S3_BUCKET_DEFAULT:-db-backups}"
  PBM_PREFIX="${PBM_S3_PREFIX_DEFAULT:-mongodb/${namespace}}"
  PBM_ENDPOINT="${PBM_S3_ENDPOINT_DEFAULT:-${MINIO_ENDPOINT:-http://minio.minio.svc.cluster.local:9000}}"
  PBM_REGION="${PBM_S3_REGION_DEFAULT:-us-east-1}"
  export PBM_BUCKET PBM_PREFIX PBM_ENDPOINT PBM_REGION
  log_debug "mongo-pbm" "resolved backup location: endpoint=${PBM_ENDPOINT} bucket=${PBM_BUCKET} prefix=${PBM_PREFIX} region=${PBM_REGION}"
}

# ---------------------------------------------------------------------------
# pbm_read_s3_credentials <namespace>
# Prints "access_key<US>secret_key" (US = \x1f, same convention as
# recovery_resolve_credentials). Source order: the `minio` secret in the DB
# namespace (name overridable via PBM_S3_CREDENTIALS_SECRET_DEFAULT, keys
# access-key-id / secret-access-key — same shape the MariaDB operator flow
# uses) -> MINIO_ROOT_USER / MINIO_ROOT_PASSWORD internal-config/env ->
# the minio-client.sh literals.
# ---------------------------------------------------------------------------
pbm_read_s3_credentials() {
  local namespace="${1:?namespace is required}"
  local secret_name="${PBM_S3_CREDENTIALS_SECRET_DEFAULT:-minio}"
  local access="" secret=""
  local enc_access enc_secret
  # _kubectl_global + explicit -n: _kubectl would inject --namespace from
  # K8S_NAMESPACE as well, and two namespace flags on one kubectl call is
  # asking for last-one-wins surprises.
  enc_access=$(_kubectl_global -n "$namespace" get secret "$secret_name" \
    -o 'jsonpath={.data.access-key-id}' 2>/dev/null) || enc_access=""
  enc_secret=$(_kubectl_global -n "$namespace" get secret "$secret_name" \
    -o 'jsonpath={.data.secret-access-key}' 2>/dev/null) || enc_secret=""
  if [[ -n "$enc_access" && -n "$enc_secret" ]]; then
    access=$(printf '%s' "$enc_access" | base64 -d)
    secret=$(printf '%s' "$enc_secret" | base64 -d)
    log_debug "mongo-pbm" "S3 credentials from secret ${namespace}/${secret_name}: access=${access:0:2}*** secret=***"
  else
    access="${MINIO_ROOT_USER:-minioadmin}"
    secret="${MINIO_ROOT_PASSWORD:-minioadmin-changeme-prod}"
    log_debug "mongo-pbm" "S3 credentials fallback (no ${namespace}/${secret_name} secret): access=${access:0:2}*** secret=***"
  fi
  printf '%s\x1f%s' "$access" "$secret"
}

# ---------------------------------------------------------------------------
# pbm_render_storage_config <access_key> <secret_key>
# Emit the PBM storage config YAML for the resolved location
# (pbm_resolve_backup_location must have run). forcePathStyle is required
# for MinIO. Never log the output of this function.
# ---------------------------------------------------------------------------
pbm_render_storage_config() {
  local access="${1:?access key is required}" secret="${2:?secret key is required}"
  cat <<EOF
storage:
  type: s3
  s3:
    endpointUrl: ${PBM_ENDPOINT}
    region: ${PBM_REGION}
    bucket: ${PBM_BUCKET}
    prefix: ${PBM_PREFIX}
    forcePathStyle: true
    credentials:
      access-key-id: ${access}
      secret-access-key: ${secret}
EOF
}

# ---------------------------------------------------------------------------
# pbm_get_config_json <pod> <container>
# Prints the current PBM config as compact JSON. rc 1 = not configured yet
# (or unreadable) — callers treat that as "storage unset".
# ---------------------------------------------------------------------------
pbm_get_config_json() {
  local pod="${1:?}" container="${2:?}"
  _pbm_exec_json "$pod" "$container" config
}

# ---------------------------------------------------------------------------
# pbm_redact_config <config_json>
# Strip S3 credentials from a PBM config JSON before it can reach a task
# result or an INFO-level log line.
# ---------------------------------------------------------------------------
pbm_redact_config() {
  local json="${1:?config json is required}"
  printf '%s' "$json" | jq -c '
    if .storage?.s3?.credentials? then
      .storage.s3.credentials = {"access-key-id":"***","secret-access-key":"***"}
    else . end' 2>/dev/null || printf '{}'
}

# ---------------------------------------------------------------------------
# pbm_storage_matches <config_json>
# rc 0 when the configured s3 endpoint/bucket/prefix equal the resolved
# PBM_ENDPOINT/PBM_BUCKET/PBM_PREFIX values, rc 1 otherwise.
# ---------------------------------------------------------------------------
pbm_storage_matches() {
  local json="${1:?config json is required}"
  printf '%s' "$json" | jq -e \
    --arg endpoint "$PBM_ENDPOINT" --arg bucket "$PBM_BUCKET" --arg prefix "$PBM_PREFIX" '
    (.storage.s3.endpointUrl // "") == $endpoint
    and (.storage.s3.bucket // "") == $bucket
    and (.storage.s3.prefix // "") == $prefix' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# pbm_apply_storage_config <namespace> <pod> <container>
# Render + apply the resolved storage config. Pre-creates the bucket with mc
# (PBM does not create buckets), reusing the same credentials the config
# hands to the agents, then applies via stdin and forces a resync so agents
# pick up existing backups under the prefix. rc 1 on any failure with the
# raw pbm output on stdout.
# ---------------------------------------------------------------------------
pbm_apply_storage_config() {
  local namespace="${1:?}" pod="${2:?}" container="${3:?}"
  local cred_row access secret
  cred_row=$(pbm_read_s3_credentials "$namespace")
  IFS=$'\x1f' read -r access secret <<< "$cred_row"

  # Bucket creation runs from the aqsh pod itself — mc is in this image and
  # MINIO_ENDPOINT is reachable from here (the agents only need it at
  # backup/restore time). Subshell so the exported MINIO_* overrides never
  # leak into the caller. Requires minio-client.sh sourced by the script.
  local bucket_out
  if bucket_out=$( (
      export MINIO_ENDPOINT="$PBM_ENDPOINT" \
        MINIO_ROOT_USER="$access" MINIO_ROOT_PASSWORD="$secret"
      setup_minio_client >/dev/null 2>&1 && ensure_bucket "$PBM_BUCKET"
    ) 2>&1); then
    log_debug "mongo-pbm" "bucket ensure ok: ${PBM_BUCKET}"
  else
    # Not fatal on its own — the bucket may already exist and only the mc
    # round trip failed; pbm resync below is the authoritative check.
    log_warn "mongo-pbm" "could not ensure bucket ${PBM_BUCKET} via mc (continuing, pbm will verify): ${bucket_out:0:300}"
  fi

  local yaml out
  yaml=$(pbm_render_storage_config "$access" "$secret")
  if ! out=$(_pbm_exec_stdin "$pod" "$container" "$yaml" config --file /dev/stdin); then
    printf '%s' "$out"
    return 1
  fi
  if ! out=$(_pbm_exec "$pod" "$container" config --force-resync); then
    printf '%s' "$out"
    return 1
  fi
  log_info "mongo-pbm" "applied PBM storage config: endpoint=${PBM_ENDPOINT} bucket=${PBM_BUCKET} prefix=${PBM_PREFIX} (resync triggered)"
  return 0
}

# ---------------------------------------------------------------------------
# pbm_ensure_storage_config <namespace> <pod> <container>
# Idempotent storage guard called by backup/pitr/restore before acting
# (G1-self-heal spirit — a fresh deployment needs no separate setup step):
#   rc 0 — storage already matches the resolved location, or was just applied
#   rc 2 — storage is configured but points ELSEWHERE; never overwritten
#          silently (an existing config may protect real backups). The
#          current REDACTED config is printed on stdout (callers run this in
#          a command substitution, where an exported variable would die with
#          the subshell).
#   rc 1 — apply attempted and failed (raw output on stdout)
# ---------------------------------------------------------------------------
pbm_ensure_storage_config() {
  local namespace="${1:?}" pod="${2:?}" container="${3:?}"
  pbm_resolve_backup_location "$namespace"
  local config_json
  if config_json=$(pbm_get_config_json "$pod" "$container") \
      && printf '%s' "$config_json" | jq -e '.storage.s3.bucket // empty' >/dev/null 2>&1; then
    if pbm_storage_matches "$config_json"; then
      log_debug "mongo-pbm" "storage config already in sync (bucket=${PBM_BUCKET} prefix=${PBM_PREFIX})"
      return 0
    fi
    local redacted
    redacted=$(pbm_redact_config "$config_json")
    log_warn "mongo-pbm" "storage config mismatch: configured $(printf '%s' "$redacted" | jq -c '.storage.s3 | {endpointUrl,bucket,prefix}' 2>/dev/null) vs resolved {endpoint:${PBM_ENDPOINT}, bucket:${PBM_BUCKET}, prefix:${PBM_PREFIX}}"
    printf '%s' "$redacted"
    return 2
  fi
  log_info "mongo-pbm" "PBM storage not configured yet — auto-applying resolved location"
  pbm_apply_storage_config "$namespace" "$pod" "$container"
}

# ---------------------------------------------------------------------------
# pbm_require_storage <op>
# Task-facing wrapper around pbm_ensure_storage_config: returns 0 when the
# storage is usable (in sync or freshly applied) and fail_task-exits on
# mismatch/apply failure with actionable guidance. Requires pbm_task_init to
# have run (PBM_POD/PBM_AGENT_CONTAINER) and DB_NAMESPACE set.
# ---------------------------------------------------------------------------
pbm_require_storage() {
  local op="${1:?op is required}"
  # Resolve in THIS shell first: pbm_ensure_storage_config runs inside a
  # command substitution below, so the PBM_* location vars it resolves there
  # die with the subshell — callers (result JSON, the failure messages here)
  # need them in the parent.
  pbm_resolve_backup_location "$DB_NAMESPACE"
  local out rc=0
  out=$(pbm_ensure_storage_config "$DB_NAMESPACE" "$PBM_POD" "$PBM_AGENT_CONTAINER") || rc=$?
  case "$rc" in
    0)
      log_debug "$op" "storage config OK (bucket=${PBM_BUCKET} prefix=${PBM_PREFIX})"
      return 0
      ;;
    2)
      local current
      current=$(printf '%s' "$out" | jq -c . 2>/dev/null) || current="null"
      [[ -z "$current" ]] && current="null"
      fail_task "STORAGE_CONFIG_MISMATCH" \
        "PBM storage points at a different location than this deployment resolves" \
        "$(jq -nc \
          --argjson current "$current" \
          --arg endpoint "$PBM_ENDPOINT" --arg bucket "$PBM_BUCKET" --arg prefix "$PBM_PREFIX" \
          '{current: $current,
            resolved: {endpointUrl: $endpoint, bucket: $bucket, prefix: $prefix},
            hint: "existing storage config is never overwritten implicitly — review with pbm/config (dry_run), then apply the resolved location with pbm/config confirm=true"}')"
      ;;
    *)
      fail_task "STORAGE_CONFIG_FAILED" "could not apply PBM storage config" \
        "$(jq -nc --arg raw "${out:0:1000}" '{raw_output:$raw}')"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# pbm_status_json <pod> <container>
# ---------------------------------------------------------------------------
pbm_status_json() {
  local pod="${1:?}" container="${2:?}"
  _pbm_exec_json "$pod" "$container" status
}

# ---------------------------------------------------------------------------
# pbm_list_json <pod> <container>
# ---------------------------------------------------------------------------
pbm_list_json() {
  local pod="${1:?}" container="${2:?}"
  _pbm_exec_json "$pod" "$container" list
}

# ---------------------------------------------------------------------------
# pbm_wait_agents_ready <pod> <container> <timeout_seconds>
# Soft gate before starting a backup right after a config change: poll until
# every node in `pbm status` reports ok. On timeout it WARNs and returns 0 —
# pbm itself is the authoritative failure point.
# ---------------------------------------------------------------------------
pbm_wait_agents_ready() {
  local pod="${1:?}" container="${2:?}" timeout="${3:-60}"
  local start now status_json
  start=$(date +%s)
  while true; do
    if status_json=$(pbm_status_json "$pod" "$container") \
        && printf '%s' "$status_json" | jq -e '
          [.cluster[]?.nodes[]?] | length > 0 and all(.ok == true)' >/dev/null 2>&1; then
      log_debug "mongo-pbm" "all pbm agents report ok"
      return 0
    fi
    now=$(date +%s)
    if (( now - start >= timeout )); then
      log_warn "mongo-pbm" "pbm agents not all ok after ${timeout}s — proceeding, pbm will surface the real error"
      return 0
    fi
    log_debug "mongo-pbm" "waiting for pbm agents to report ok ($(( now - start ))s elapsed)"
    sleep 5
  done
}

# ---------------------------------------------------------------------------
# pbm_start_backup <pod> <container> <type> [ns_filter] [with_base]
# Start a backup of the given type (logical|physical|incremental); prints
# the backup name (a UTC timestamp). with_base="true" adds --base — the
# anchor an incremental chain grows from. rc 1 with raw output on failure.
# ---------------------------------------------------------------------------
pbm_start_backup() {
  local pod="${1:?}" container="${2:?}" type="${3:?type is required}"
  local ns_filter="${4:-}" with_base="${5:-false}"
  local args=(backup -t "$type")
  [[ "$with_base" == "true" ]] && args+=(--base)
  [[ -n "$ns_filter" ]] && args+=(--ns "$ns_filter")
  local out name
  if ! out=$(_pbm_exec_json "$pod" "$container" "${args[@]}"); then
    printf '%s' "$out"
    return 1
  fi
  name=$(printf '%s' "$out" | jq -r '.name // empty' 2>/dev/null)
  if [[ -z "$name" ]]; then
    printf '%s' "$out"
    return 1
  fi
  log_info "mongo-pbm" "backup started: ${name} (type=${type}${with_base:+, base=${with_base}}${ns_filter:+, ns=${ns_filter}})"
  printf '%s' "$name"
}

# ---------------------------------------------------------------------------
# pbm_describe_backup_json <pod> <container> <backup_name>
# ---------------------------------------------------------------------------
pbm_describe_backup_json() {
  local pod="${1:?}" container="${2:?}" name="${3:?backup name is required}"
  _pbm_exec_json "$pod" "$container" describe-backup "$name"
}

# ---------------------------------------------------------------------------
# pbm_wait_backup <pod> <container> <backup_name> <timeout_seconds>
# Start-then-poll (never `pbm backup --wait`: a dropped exec session would
# abort the wait, not the backup, and fail the task spuriously). Prints the
# final describe-backup JSON. rc: 0 done, 1 error/cancelled, 124 timeout.
# ---------------------------------------------------------------------------
pbm_wait_backup() {
  local pod="${1:?}" container="${2:?}" name="${3:?}" timeout="${4:-1200}"
  local start now desc status last_status=""
  start=$(date +%s)
  while true; do
    if desc=$(pbm_describe_backup_json "$pod" "$container" "$name"); then
      status=$(printf '%s' "$desc" | jq -r '.status // empty' 2>/dev/null)
      if [[ "$status" != "$last_status" ]]; then
        log_debug "mongo-pbm" "backup ${name} status: ${last_status:-<none>} -> ${status:-<unknown>}"
        last_status="$status"
      fi
      case "$status" in
        done)
          log_info "mongo-pbm" "backup ${name} completed"
          printf '%s' "$desc"
          return 0
          ;;
        error | cancelled)
          log_error "mongo-pbm" "backup ${name} ended with status=${status}: $(printf '%s' "$desc" | jq -r '.error // "unknown error"' 2>/dev/null)"
          printf '%s' "$desc"
          return 1
          ;;
      esac
    else
      log_debug "mongo-pbm" "describe-backup ${name} not readable yet (control collections may lag)"
    fi
    now=$(date +%s)
    if (( now - start >= timeout )); then
      log_error "mongo-pbm" "backup ${name} still not finished after ${timeout}s"
      printf '%s' "${desc:-}"
      return 124
    fi
    sleep "$_PBM_POLL_INTERVAL"
  done
}

# ---------------------------------------------------------------------------
# pbm_start_restore <pod> <container> <backup_name_or_empty> <time_or_empty> [ns_filter]
# Start a restore from a snapshot (backup name) or to a point in time.
# Prints the restore op name. rc 1 with raw output on failure.
# ---------------------------------------------------------------------------
pbm_start_restore() {
  local pod="${1:?}" container="${2:?}" backup_name="${3:-}" time="${4:-}" ns_filter="${5:-}"
  local args=(restore)
  if [[ -n "$backup_name" ]]; then
    args+=("$backup_name")
  else
    args+=(--time "$time")
  fi
  [[ -n "$ns_filter" ]] && args+=(--ns "$ns_filter")
  local out name
  if ! out=$(_pbm_exec_json "$pod" "$container" "${args[@]}"); then
    printf '%s' "$out"
    return 1
  fi
  name=$(printf '%s' "$out" | jq -r '.name // empty' 2>/dev/null)
  if [[ -z "$name" ]]; then
    printf '%s' "$out"
    return 1
  fi
  log_info "mongo-pbm" "restore started: ${name} (${backup_name:+snapshot=${backup_name}}${time:+time=${time}}${ns_filter:+ ns=${ns_filter}})"
  printf '%s' "$name"
}

# ---------------------------------------------------------------------------
# pbm_wait_restore <pod> <container> <restore_name> <timeout_seconds>
# Poll describe-restore until done/error. Prints the final JSON.
# rc: 0 done, 1 error, 124 timeout.
# ---------------------------------------------------------------------------
pbm_wait_restore() {
  local pod="${1:?}" container="${2:?}" name="${3:?}" timeout="${4:-1500}"
  local start now desc status last_status=""
  start=$(date +%s)
  while true; do
    if desc=$(_pbm_exec_json "$pod" "$container" describe-restore "$name"); then
      status=$(printf '%s' "$desc" | jq -r '.status // empty' 2>/dev/null)
      if [[ "$status" != "$last_status" ]]; then
        log_debug "mongo-pbm" "restore ${name} status: ${last_status:-<none>} -> ${status:-<unknown>}"
        last_status="$status"
      fi
      case "$status" in
        done)
          log_info "mongo-pbm" "restore ${name} completed"
          printf '%s' "$desc"
          return 0
          ;;
        error | failed)
          log_error "mongo-pbm" "restore ${name} ended with status=${status}: $(printf '%s' "$desc" | jq -r '.error // "unknown error"' 2>/dev/null)"
          printf '%s' "$desc"
          return 1
          ;;
      esac
    else
      log_debug "mongo-pbm" "describe-restore ${name} not readable yet"
    fi
    now=$(date +%s)
    if (( now - start >= timeout )); then
      log_error "mongo-pbm" "restore ${name} still not finished after ${timeout}s"
      printf '%s' "${desc:-}"
      return 124
    fi
    sleep "$_PBM_POLL_INTERVAL"
  done
}

# ---------------------------------------------------------------------------
# pbm_pitr_enabled <status_json>
# rc 0 when PITR slicing is enabled in the config.
# ---------------------------------------------------------------------------
pbm_pitr_enabled() {
  local status_json="${1:?status json is required}"
  printf '%s' "$status_json" | jq -e '.pitr.conf == true' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# pbm_pitr_set <pod> <container> <true|false> [oplog_span_min]
# Flip pitr.enabled (and optionally pitr.oplogSpanMin) via pbm config --set.
# ---------------------------------------------------------------------------
pbm_pitr_set() {
  local pod="${1:?}" container="${2:?}" enabled="${3:?true|false is required}"
  local span="${4:-}"
  local args=(config --set "pitr.enabled=${enabled}")
  [[ -n "$span" ]] && args+=(--set "pitr.oplogSpanMin=${span}")
  local out
  if ! out=$(_pbm_exec "$pod" "$container" "${args[@]}"); then
    printf '%s' "$out"
    return 1
  fi
  log_info "mongo-pbm" "PITR set: enabled=${enabled}${span:+ oplogSpanMin=${span}}"
  return 0
}

# ---------------------------------------------------------------------------
# pbm_has_done_base_backup <list_json>
# rc 0 when at least one snapshot has status "done" (PITR slicing and
# point-in-time restores both need a base snapshot).
# ---------------------------------------------------------------------------
pbm_has_done_base_backup() {
  local list_json="${1:?list json is required}"
  printf '%s' "$list_json" | jq -e '
    [.snapshots[]? | select(.status == "done")] | length > 0' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# pbm_pitr_covers <status_json> <epoch_seconds>
# rc 0 when some PITR chunk range covers the given epoch.
# ---------------------------------------------------------------------------
pbm_pitr_covers() {
  local status_json="${1:?}" epoch="${2:?epoch is required}"
  printf '%s' "$status_json" | jq -e --argjson t "$epoch" '
    [.backups.pitrChunks.pitrChunks[]?
      | select(.range.start <= $t and .range.end >= $t)] | length > 0' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# _pbm_epoch <spec>
# Convert "Nd" (N days ago) or an ISO timestamp to epoch seconds. GNU date
# (Debian base image). rc 1 on unparseable input.
# ---------------------------------------------------------------------------
_pbm_epoch() {
  local spec="${1:?spec is required}"
  if [[ "$spec" =~ ^([0-9]+)d$ ]]; then
    date -u -d "-${BASH_REMATCH[1]} days" +%s
  else
    date -u -d "$spec" +%s 2>/dev/null || return 1
  fi
}

# ---------------------------------------------------------------------------
# pbm_snapshots_older_than <list_json> <epoch>
# JSON array of snapshots completed before <epoch> (delete preview — pbm
# cleanup's own retention math is authoritative at execution time).
# ---------------------------------------------------------------------------
pbm_snapshots_older_than() {
  local list_json="${1:?}" epoch="${2:?}"
  printf '%s' "$list_json" | jq -c --argjson t "$epoch" '
    [.snapshots[]? | select((.completeTS // 0) < $t and (.completeTS // 0) > 0)
      | {name, status, completeTS, type}]' 2>/dev/null || printf '[]'
}

# ---------------------------------------------------------------------------
# pbm_delete_backup <pod> <container> <backup_name>
# Non-interactive delete. Verified by re-listing (delete output is text,
# not reliably JSON). rc 1 with raw output on failure.
# ---------------------------------------------------------------------------
pbm_delete_backup() {
  local pod="${1:?}" container="${2:?}" name="${3:?}"
  local out
  if ! out=$(_pbm_exec "$pod" "$container" delete-backup "$name" --yes); then
    printf '%s' "$out"
    return 1
  fi
  local list_json
  if list_json=$(pbm_list_json "$pod" "$container") \
      && printf '%s' "$list_json" | jq -e --arg n "$name" \
        '[.snapshots[]? | select(.name == $n)] | length == 0' >/dev/null 2>&1; then
    log_info "mongo-pbm" "backup ${name} deleted (verified by re-list)"
    return 0
  fi
  printf 'backup %s still present after delete-backup' "$name"
  return 1
}

# ---------------------------------------------------------------------------
# pbm_cleanup <pod> <container> <older_than>
# Non-interactive retention cleanup (snapshots + PITR chunks older than the
# given timestamp/duration). rc 1 with raw output on failure.
# ---------------------------------------------------------------------------
pbm_cleanup() {
  local pod="${1:?}" container="${2:?}" older_than="${3:?}"
  local out
  if ! out=$(_pbm_exec "$pod" "$container" cleanup --older-than "$older_than" --yes); then
    printf '%s' "$out"
    return 1
  fi
  log_info "mongo-pbm" "cleanup executed for artifacts older than ${older_than}"
  printf '%s' "$out"
  return 0
}

# ---------------------------------------------------------------------------
# pbm_logs_json <pod> <container> <tail> [severity] [event]
# ---------------------------------------------------------------------------
pbm_logs_json() {
  local pod="${1:?}" container="${2:?}" tail="${3:-50}"
  local severity="${4:-}" event="${5:-}"
  local args=(logs -t "$tail")
  [[ -n "$severity" ]] && args+=(-s "$severity")
  [[ -n "$event" ]] && args+=(-e "$event")
  _pbm_exec_json "$pod" "$container" "${args[@]}"
}

# ---------------------------------------------------------------------------
# pbm_current_op <status_json>
# Compact JSON of the currently running PBM operation, or "null".
# ---------------------------------------------------------------------------
pbm_current_op() {
  local status_json="${1:?status json is required}"
  printf '%s' "$status_json" | jq -c '
    if (.running // {}) == {} then null else .running end' 2>/dev/null || printf 'null'
}

# ---------------------------------------------------------------------------
# pbm_cancel_backup <pod> <container>
# ---------------------------------------------------------------------------
pbm_cancel_backup() {
  local pod="${1:?}" container="${2:?}"
  local out
  if ! out=$(_pbm_exec "$pod" "$container" cancel-backup); then
    printf '%s' "$out"
    return 1
  fi
  log_info "mongo-pbm" "cancel-backup issued"
  printf '%s' "$out"
  return 0
}
