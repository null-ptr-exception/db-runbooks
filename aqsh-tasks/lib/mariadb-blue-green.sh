#!/usr/bin/env bash

[[ -n "${_MARIADB_BLUE_GREEN_LIB_LOADED:-}" ]] && return 0
_MARIADB_BLUE_GREEN_LIB_LOADED=1

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$SCRIPT_DIR"
fi

# shellcheck source=aqsh-tasks/lib/mariadb-task-common.sh
source "${LIB_DIR}/mariadb-task-common.sh"  # pulls in logging, response, k8s + generic helpers
# shellcheck source=aqsh-tasks/lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"

BG_CONTEXT="${K8S_CONTEXT:-}"
BG_NAMESPACE="${DB_NAMESPACE:?DB_NAMESPACE is required}"
BG_RESOURCE="${MARIADB_RESOURCE:-mariadb}"
BG_MDB="${MARIADB_NAME:-${MARIADB_STS_NAME:-mariadb}}"
BG_CONTAINER="${MARIADB_CONTAINER:-mariadb}"
BG_CONFIRM="${CONFIRM:-false}"
# Orchestrators sometimes invoke helpers in command substitutions, whose shell
# state cannot propagate back to the parent. Safe defaults keep those failure
# paths deterministic without retaining a child response or transport detail.
# shellcheck disable=SC2034
BG_LOCAL_ERR='{"stage":"local-operation"}'
# shellcheck disable=SC2034
BG_PEER_ERR='{"stage":"peer-operation"}'

# bg_require_bluegreen_capable [op]
# Blue/green is built on the current-generation operator's ExternalMariaDB +
# multiCluster + physical bootstrapFrom, NONE of which exist on the legacy
# mmontes-era operator. Gate on the capabilities and on a confident operator
# profile so API discovery errors cannot be misreported as a legacy upgrade.
bg_require_bluegreen_capable() {
  local op="${1:-blue-green}"
  local confident_rc=0 ext_rc=0 physical_rc=0
  mdb_operator_group_is_confident || confident_rc=$?
  if [[ "$confident_rc" -eq 2 ]]; then
    bg_fail "$op" "blue-green capability could not be verified" \
      '{"stage":"capability-check","available":false}' 2 INTERNAL_ERROR
  fi
  if [[ "$confident_rc" -ne 0 ]]; then
    bg_fail "$op" "blue-green is unavailable for this database" \
      '{"stage":"capability-check","available":false}' 2 OPERATION_UNAVAILABLE
  fi

  mdb_crd_status externalmariadbs || ext_rc=$?
  mdb_crd_status physicalbackups || physical_rc=$?
  if [[ "$ext_rc" -eq 2 || "$physical_rc" -eq 2 ]]; then
    bg_fail "$op" "blue-green capability could not be verified" \
      '{"stage":"capability-check","available":false}' 2 INTERNAL_ERROR
  fi
  if [[ "$(mdb_operator_group)" == "k8s.mariadb.com" && "$ext_rc" -eq 0 && "$physical_rc" -eq 0 ]]; then
    return 0
  fi
  bg_fail "$op" "blue-green is unavailable for this database" \
    '{"stage":"capability-check","available":false}' 2 OPERATION_UNAVAILABLE
}

bg_init_target() {
  K8S_CONTEXT="$BG_CONTEXT"
  # shellcheck disable=SC2034
  K8S_NAMESPACE="$BG_NAMESPACE"
  mariadb_set_target "$BG_CONTEXT" "$BG_NAMESPACE" "$BG_RESOURCE" "$BG_MDB" "$BG_CONTAINER"
  # Every blue/green entry point routes through here, so this single gate covers
  # them all (create, bootstrap-green, switchover, status, …).
  bg_require_bluegreen_capable "blue-green"
}

# --- Generic task helpers ---------------------------------------------------
# Input validators, the JSON/result writers, and the bool helper now live in
# mariadb-task-common.sh (sourced above) so non-blue/green tasks (restore, …)
# can reuse them. Thin bg_* aliases keep the blue/green task scripts unchanged.
bg_write_result() { mdbt_write_result "$@"; }
bg_fail() { mdbt_fail "$@"; }
bg_bool_json() { mdbt_bool_json "$@"; }
bg_json_string() { mdbt_json_string "$@"; }
bg_required() { mdbt_required "$@"; }
bg_validate_dns_label() { mdbt_validate_dns_label "$@"; }
bg_validate_secret_key() { mdbt_validate_secret_key "$@"; }
bg_validate_s3_bucket() { mdbt_validate_s3_bucket "$@"; }
bg_validate_s3_prefix() { mdbt_validate_s3_prefix "$@"; }
bg_validate_endpoint() { mdbt_validate_endpoint "$@"; }
bg_validate_region() { mdbt_validate_region "$@"; }
bg_validate_image() { mdbt_validate_image "$@"; }
bg_validate_storage_size() { mdbt_validate_storage_size "$@"; }
bg_validate_uint() { mdbt_validate_uint "$@"; }
bg_validate_enum() { mdbt_validate_enum "$@"; }
bg_wait_mariadb_ready() { mdbt_wait_mariadb_ready "$@"; }

# Thin alias over the shared confirm gate, binding the blue/green confirm value
# so it can't drift from mdbt_require_confirm.
bg_require_confirm() { mdbt_require_confirm "$1" "$BG_CONFIRM"; }

# Blue/green-specific helpers (kept local).

bg_sql_string() {
  local escaped
  escaped="$(printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/''/g")"
  printf "'%s'" "$escaped"
}

bg_get_mariadb_json() {
  _kubectl get "$BG_RESOURCE" "$BG_MDB" -o json
}

bg_status_data() {
  local cr_json="$1"
  jq '{
    namespace: .metadata.namespace,
    name: .metadata.name,
    image: .spec.image,
    desiredMultiClusterPrimary: .spec.multiCluster.primary,
    currentMultiClusterPrimary: .status.currentMultiClusterPrimary,
    ready: any(.status.conditions[]?; .type == "Ready" and .status == "True")
  }' <<<"$cr_json"
}

bg_current_primary_pod() {
  local cr_json="$1" primary op="${2:-blue-green}"
  primary="$(jq -r '.status.currentPrimary // empty' <<<"$cr_json")"
  if [[ -z "$primary" || "$primary" == "null" ]]; then
    bg_fail "$op" "database primary is not available" \
      '{"stage":"primary-discovery","ready":false}' 1 DATABASE_NOT_READY
  fi
  printf '%s\n' "$primary"
}

bg_read_root_password() {
  local primary="$1"
  mapfile -t pods < <(mariadb_list_pods "$(mariadb_cr_replicas || true)")
  mariadb_read_root_password "$primary" "${pods[@]}"
}

# bg_target_sql <sql>
# Run a SQL statement on the local target's current primary pod. Echoes the
# query result. Returns 1 (does NOT exit) when the primary pod or the root
# password cannot be resolved, so orchestrators can roll back.
bg_target_sql() {
  local sql="$1" cr_json primary password
  cr_json="$(bg_get_mariadb_json)" || return 1
  primary="$(jq -r '.status.currentPrimary // empty' <<<"$cr_json")"
  [[ -n "$primary" && "$primary" != "null" ]] || return 1
  password="$(bg_read_root_password "$primary")" || return 1
  mariadb_sql "$primary" "$password" "$sql"
}

# bg_long_running_count <threshold_seconds>
# Count statements on the local target's primary that have been running for at
# least <threshold_seconds> — long writes/DDL inflate replica lag and stretch
# the switchover write-outage window (AWS runs the same guardrail on blue).
# Echoes the count; returns non-zero if the query itself fails.
bg_long_running_count() {
  local threshold="$1"
  bg_target_sql "SELECT COUNT(*) FROM information_schema.processlist WHERE COMMAND NOT IN ('Sleep','Binlog Dump','Slave_IO','Slave_SQL','Daemon') AND USER NOT IN ('system user','event_scheduler') AND ID <> CONNECTION_ID() AND TIME >= ${threshold}"
}

# bg_validate_gtid <name> <value> <op>
# A MariaDB GTID list: domain-server-seq, comma-separated.
bg_validate_gtid() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[0-9]+-[0-9]+-[0-9]+(,[0-9]+-[0-9]+-[0-9]+)*$ ]]; then
    bg_fail "$op" "${name} must be a MariaDB GTID list" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

bg_replication_check() {
  local cr_json="$1" lag_threshold="$2"
  # Absent replica status is a FAILURE, not a pass: a just-bootstrapped Green
  # (or an operator that has not reconciled yet) provides no evidence of
  # replication health, and treating that as ok would let create/switchover
  # proceed unchecked. Callers that genuinely tolerate a replication-less
  # target must opt out via check_replication=false.
  jq --argjson threshold "$lag_threshold" '
    (.status.replication.replicas // {}) as $replicas
    | ($replicas | length) as $count
    | {
        checked: ($count > 0),
        ok: (
          if $count == 0 then false
          else all($replicas[]; .slaveIORunning == true and .slaveSQLRunning == true and (.secondsBehindMaster != null) and (.secondsBehindMaster <= $threshold))
          end
        ),
        reason: (if $count == 0 then "REPLICATION_STATUS_UNAVAILABLE" else null end)
      }
  ' <<<"$cr_json"
}

# ---------------------------------------------------------------------------
# Cross-cluster orchestration helpers
#
# The blue/green orchestrator tasks (create/switchover) run on one cluster's
# AQSH and drive the peer cluster by calling its AQSH over HTTP. The kube
# single-cluster boundary is preserved: each AQSH only ever runs kubectl
# against its own cluster. The orchestrator never holds the peer's kubeconfig,
# only the peer AQSH URL and a bearer token the caller already holds (both
# clusters validate against the same TokenReview backend).
# ---------------------------------------------------------------------------

# bg_local_step <script_path> [KEY=VALUE ...]
# Run a sibling granular task script in a child process against the LOCAL
# cluster, capturing its JSON result from stdout. On success echoes the inner
# .data object (compact) and returns 0. On failure sets BG_LOCAL_ERR to a stable,
# public-safe marker and returns 1 (does NOT exit, so callers can roll back).
# BG_LOCAL_ERR is read by the orchestrator scripts that source this lib.
# shellcheck disable=SC2034
bg_local_step() {
  local script="$1"
  shift
  local out rc
  BG_LOCAL_ERR=""
  # Capture inside an `if` so a non-zero child does not trip the caller's set -e
  # before we can inspect the result.
  if out="$(env "$@" AQSH_RESULT_FILE= LIB_DIR="$LIB_DIR" bash "$script" 2>/dev/null)"; then
    rc=0
  else
    rc=$?
  fi
  if (( rc != 0 )); then
    BG_LOCAL_ERR='{"stage":"local-operation"}'
    return 1
  fi
  # The granular script may emit non-JSON lines (e.g. `kubectl wait` output)
  # around its single-line JSON result; take the last line that looks like a
  # JSON object. No parseable result is a FAILURE — a silent `{}` would let
  # the orchestrator carry on without evidence the step really succeeded.
  local result_line
  result_line="$(printf '%s\n' "$out" | grep '^{' | tail -n1)"
  if [[ -z "$result_line" ]] || ! jq -c '.data // {}' <<<"$result_line" 2>/dev/null; then
    BG_LOCAL_ERR='{"stage":"local-operation"}'
    return 1
  fi
  return 0
}

# bg_peer_call_task <op> <peer_url> <peer_token> <task_path> <payload> [timeout_seconds]
# Submit a task to the peer AQSH, poll to completion, and echo its inner
# result data (compact JSON) on success returning 0. On any failure sets
# BG_PEER_ERR to a stable, public-safe marker and returns 1 (does NOT exit).
# BG_PEER_ERR is read by the orchestrator scripts that source this lib.
# shellcheck disable=SC2034
bg_peer_call_task() {
  local peer_url="$2" peer_token="$3" task_path="$4" payload="$5" timeout="${6:-540}"
  local encoded submit code body task_id resp status elapsed=0 curl_rc

  BG_PEER_ERR=""
  encoded="${task_path//\//%2F}"

  # peer_aqsh_url / peer_token are required inputs on the public task contract.
  # Internal steps never use them, but every peer (internal-step) call must
  # still satisfy the schema — inject the orchestrator's own values.
  payload="$(jq -c --arg purl "$peer_url" --arg ptok "$peer_token" \
    '. + {peer_aqsh_url: $purl, peer_token: $ptok}' <<<"$payload")"

  if submit="$(curl -sS --connect-timeout 5 -m 60 -w $'\n%{http_code}' \
    -X POST "${peer_url}/tasks/${encoded}" \
    -H "Authorization: Bearer ${peer_token}" \
    -H 'Content-Type: application/json' \
    -d "$payload" 2>/dev/null)"; then
    curl_rc=0
  else
    curl_rc=$?
  fi
  if (( curl_rc != 0 )); then
    BG_PEER_ERR='{"stage":"peer-operation"}'
    return 1
  fi

  code="$(printf '%s' "$submit" | tail -n1)"
  body="$(printf '%s' "$submit" | sed '$d')"
  if [[ "$code" != "202" ]]; then
    BG_PEER_ERR='{"stage":"peer-operation"}'
    return 1
  fi
  task_id="$(jq -r '.id // empty' <<<"$body" 2>/dev/null || true)"
  if [[ -z "$task_id" ]]; then
    BG_PEER_ERR='{"stage":"peer-operation"}'
    return 1
  fi

  while (( elapsed < timeout )); do
    if resp="$(curl -sS --connect-timeout 5 -m 15 \
      -H "Authorization: Bearer ${peer_token}" \
      "${peer_url}/executions/${task_id}" 2>/dev/null)"; then
      curl_rc=0
    else
      curl_rc=$?
    fi
    if (( curl_rc != 0 )); then
      BG_PEER_ERR='{"stage":"peer-operation"}'
      return 1
    fi
    status="$(jq -r '.status // empty' <<<"$resp" 2>/dev/null || true)"
    case "$status" in
      completed)
        jq -c '
          .result.data as $d
          | (($d | try fromjson catch null) // (if ($d | type) == "object" then $d else {} end))
          | (.data // {})
        ' <<<"$resp" 2>/dev/null || printf '{}'
        return 0
        ;;
      failed)
        BG_PEER_ERR='{"stage":"peer-operation"}'
        return 1
        ;;
    esac
    sleep 5
    elapsed=$(( elapsed + 5 ))
  done

  BG_PEER_ERR='{"stage":"peer-operation"}'
  return 1
}

bg_validate_url() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^https?://[A-Za-z0-9._:/-]+$ ]]; then
    bg_fail "$op" "${name} must be an http(s) URL" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

# bg_set_maintenance <true|false>
# Toggle maintenance/read-only mode on the local-target MariaDB ($BG_MDB).
# Reads CORDON / DRAIN_CONNECTIONS / READ_ONLY / DRAIN_GRACE_PERIOD_SECONDS for
# the enable case (sensible defaults if unset). Echoes status data on success
# and returns 0; returns 1 if the patch fails (does NOT exit, so the switchover
# orchestrator can roll back).
bg_set_maintenance() {
  local enabled="$1"
  if [[ "$enabled" == "true" ]]; then
    local cordon drain read_only grace
    cordon="$(bg_bool_json "${CORDON:-true}")"
    drain="$(bg_bool_json "${DRAIN_CONNECTIONS:-true}")"
    read_only="$(bg_bool_json "${READ_ONLY:-true}")"
    grace="${DRAIN_GRACE_PERIOD_SECONDS:-30}"
    [[ "$grace" =~ ^[0-9]+$ ]] || return 1
    _kubectl patch "$BG_RESOURCE" "$BG_MDB" --type merge -p "{
      \"spec\": {
        \"maintenance\": {
          \"enabled\": true,
          \"cordon\": ${cordon},
          \"drainConnections\": ${drain},
          \"drainGracePeriodSeconds\": ${grace},
          \"readOnly\": ${read_only}
        }
      }
    }" >/dev/null || return 1
  else
    _kubectl patch "$BG_RESOURCE" "$BG_MDB" --type merge \
      -p '{"spec":{"maintenance":{"enabled":false}}}' >/dev/null || return 1
  fi
  bg_status_data "$(bg_get_mariadb_json)"
}

# bg_create_physical_backup <op>
# Create a PhysicalBackup of the local-target MariaDB ($BG_MDB) and wait for it
# to complete. Reads BACKUP_* and WAIT_TIMEOUT from the caller's scope. On
# success sets BG_BACKUP_DATA to the bootstrap descriptor (object) and returns
# 0. Validation and not-Ready failures call bg_fail (exit). Folds the former
# blue-green/create-physical-backup task into the create orchestrator.
# BG_BACKUP_DATA is read by the create orchestrator that sources this lib.
# shellcheck disable=SC2034
bg_create_physical_backup() {
  local op="${1:-blue-green/create}"

  bg_validate_dns_label "namespace" "$BG_NAMESPACE" "$op"
  bg_validate_dns_label "mariadb" "$BG_MDB" "$op"
  # These values come from the deployment's storage policy. Validate them
  # without turning policy field names or values into a public task error.
  if ! (
    MDBT_RESULT_FILE=/dev/null
    bg_validate_dns_label "backup_name" "$BACKUP_NAME" "$op"
    bg_validate_s3_bucket "backup_bucket" "$BACKUP_BUCKET" "$op"
    bg_validate_s3_prefix "backup_prefix" "$BACKUP_PREFIX" "$op"
    bg_validate_endpoint "backup_endpoint" "$BACKUP_ENDPOINT" "$op"
    bg_validate_region "backup_region" "$BACKUP_REGION" "$op"
    bg_validate_dns_label "backup_access_secret" "$BACKUP_ACCESS_SECRET" "$op"
    bg_validate_secret_key "backup_access_key" "$BACKUP_ACCESS_KEY" "$op"
    bg_validate_dns_label "backup_secret_access_secret" "$BACKUP_SECRET_ACCESS_SECRET" "$op"
    bg_validate_secret_key "backup_secret_key" "$BACKUP_SECRET_KEY" "$op"
    bg_validate_enum "backup_target" "$BACKUP_TARGET" "$op" Primary Replica PreferReplica
    bg_validate_enum "backup_compression" "$BACKUP_COMPRESSION" "$op" bzip2 gzip none
  ); then
    bg_fail "$op" "backup configuration is unavailable" \
      '{"stage":"backup","completed":false}' 2 BACKUP_CONFIGURATION_UNAVAILABLE
  fi

  local source_json ready_status
  if ! source_json="$(bg_get_mariadb_json 2>/dev/null)"; then
    bg_fail "$op" "source database is unavailable" \
      '{"stage":"backup","completed":false}' 1 DATABASE_NOT_FOUND
  fi
  ready_status="$(jq -r '.status.conditions[]? | select(.type == "Ready") | .status' <<<"$source_json" | tail -1)"
  if [[ "$ready_status" != "True" ]]; then
    bg_fail "$op" "source database must be ready before backup" \
      '{"stage":"backup","completed":false}' 1 DATABASE_NOT_READY
  fi

  # Shared PhysicalBackup builder (JSON) — same CR shape the physical-backup task
  # uses, so the two write paths can't drift. Reads the BACKUP_* env set above.
  if ! mdbt_physical_backup_manifest "$BACKUP_NAME" "$BG_NAMESPACE" "$BG_MDB" 2>/dev/null \
    | _kubectl apply -f - >/dev/null 2>&1; then
    bg_fail "$op" "backup could not be started" \
      '{"stage":"backup","completed":false}' 1 BACKUP_FAILED
  fi

  if ! _kubectl wait --for=condition=Complete "physicalbackup/${BACKUP_NAME}" \
    --timeout="$WAIT_TIMEOUT" >/dev/null 2>&1; then
    bg_fail "$op" "backup did not complete in time" \
      '{"stage":"backup","completed":false}' 1 BACKUP_TIMEOUT
  fi

  BG_BACKUP_DATA="$(jq -n \
    --arg namespace "$BG_NAMESPACE" \
    --arg backupName "$BACKUP_NAME" \
    '{
      namespace: $namespace,
      backupName: $backupName,
      backupContentType: "Physical",
      completed: true
    }')"
}
