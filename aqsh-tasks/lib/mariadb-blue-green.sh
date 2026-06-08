#!/usr/bin/env bash

[[ -n "${_MARIADB_BLUE_GREEN_LIB_LOADED:-}" ]] && return 0
_MARIADB_BLUE_GREEN_LIB_LOADED=1

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$SCRIPT_DIR"
fi

# shellcheck source=aqsh-tasks/lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=aqsh-tasks/lib/response.sh
source "${LIB_DIR}/response.sh"
# shellcheck source=aqsh-tasks/lib/k8s.sh
source "${LIB_DIR}/k8s.sh"
# shellcheck source=aqsh-tasks/lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"

BG_CONTEXT="${K8S_CONTEXT:-}"
BG_NAMESPACE="${DB_NAMESPACE:?DB_NAMESPACE is required}"
BG_RESOURCE="${MARIADB_RESOURCE:-mariadb}"
BG_MDB="${MARIADB_NAME:-${MARIADB_STS_NAME:-mariadb}}"
BG_CONTAINER="${MARIADB_CONTAINER:-mariadb}"
BG_CONFIRM="${CONFIRM:-false}"
BG_RESULT_FILE="${AQSH_RESULT_FILE:-}"

bg_init_target() {
  K8S_CONTEXT="$BG_CONTEXT"
  # shellcheck disable=SC2034
  K8S_NAMESPACE="$BG_NAMESPACE"
  mariadb_set_target "$BG_CONTEXT" "$BG_NAMESPACE" "$BG_RESOURCE" "$BG_MDB" "$BG_CONTAINER"
}

bg_write_result() {
  local payload="$1"
  if [[ -n "$BG_RESULT_FILE" ]]; then
    printf '%s\n' "$payload" > "$BG_RESULT_FILE"
  else
    printf '%s\n' "$payload"
  fi
}

bg_fail() {
  local op="$1" message="$2" data="${3:-{}}" code="${4:-1}"
  bg_write_result "$(response_err "$op" "$message" "$data" "$code")"
  exit "$code"
}

bg_require_confirm() {
  local op="$1"
  case "$BG_CONFIRM" in
    true | TRUE | yes | YES | 1) ;;
    *) bg_fail "$op" "confirm=true is required for this mutating blue/green task" "{\"confirm\":\"$BG_CONFIRM\"}" 2 ;;
  esac
}

bg_bool_json() {
  case "$1" in
    true | TRUE | yes | YES | 1) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

bg_json_string() {
  jq -Rn --arg value "$1" '$value'
}

bg_sql_string() {
  local escaped
  escaped="$(printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/''/g")"
  printf "'%s'" "$escaped"
}

bg_required() {
  local name="$1" value="$2" op="$3"
  if [[ -z "$value" ]]; then
    bg_fail "$op" "${name} is required" "{}" 2
  fi
}

bg_validate_dns_label() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    bg_fail "$op" "${name} must be a DNS label" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

bg_validate_secret_key() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
    bg_fail "$op" "${name} must match ^[A-Za-z0-9._-]+$" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

bg_validate_s3_bucket() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    bg_fail "$op" "${name} must be an S3 bucket-style token" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

bg_validate_s3_prefix() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    bg_fail "$op" "${name} must match ^[A-Za-z0-9._/-]+$" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

bg_validate_endpoint() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    bg_fail "$op" "${name} must match ^[A-Za-z0-9._:-]+$" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

bg_validate_region() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[A-Za-z0-9-]+$ ]]; then
    bg_fail "$op" "${name} must match ^[A-Za-z0-9-]+$" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

bg_validate_image() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[A-Za-z0-9._:/@-]+$ ]]; then
    bg_fail "$op" "${name} must be a container image reference token" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

bg_validate_storage_size() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[0-9]+(Mi|Gi|Ti)$ ]]; then
    bg_fail "$op" "${name} must match ^[0-9]+(Mi|Gi|Ti)$" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

bg_validate_uint() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    bg_fail "$op" "${name} must be an unsigned integer" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}

bg_validate_enum() {
  local name="$1" value="$2" op="$3"
  shift 3
  local allowed
  for allowed in "$@"; do
    if [[ "$value" == "$allowed" ]]; then
      return 0
    fi
  done
  bg_fail "$op" "${name} is not an allowed value" "$(jq -n --arg field "$name" --arg value "$value" --arg allowed "$*" '{field: $field, value: $value, allowed: $allowed}')" 2
}

bg_get_mariadb_json() {
  _kubectl get "$BG_RESOURCE" "$BG_MDB" -o json
}

bg_wait_mariadb_ready() {
  local name="$1" timeout="${2:-10m}"
  _kubectl wait --for=condition=Ready "mariadb/${name}" --timeout="$timeout"
}

bg_status_data() {
  local cr_json="$1"
  jq '{
    namespace: .metadata.namespace,
    name: .metadata.name,
    image: .spec.image,
    desiredMultiClusterPrimary: .spec.multiCluster.primary,
    currentPrimary: .status.currentPrimary,
    currentMultiClusterPrimary: .status.currentMultiClusterPrimary,
    conditions: (.status.conditions // []),
    replication: (.status.replication // null)
  }' <<<"$cr_json"
}

bg_current_primary_pod() {
  local cr_json="$1" primary op="${2:-blue-green}"
  primary="$(jq -r '.status.currentPrimary // empty' <<<"$cr_json")"
  if [[ -z "$primary" || "$primary" == "null" ]]; then
    bg_fail "$op" "current primary pod is not available" "$(bg_status_data "$cr_json")"
  fi
  printf '%s\n' "$primary"
}

bg_read_root_password() {
  local primary="$1"
  mapfile -t pods < <(mariadb_list_pods "$(mariadb_cr_replicas || true)")
  mariadb_read_root_password "$primary" "${pods[@]}"
}

bg_replication_check() {
  local cr_json="$1" lag_threshold="$2"
  jq --argjson threshold "$lag_threshold" '
    (.status.replication.replicas // {}) as $replicas
    | ($replicas | length) as $count
    | {
        checked: ($count > 0),
        ok: (
          if $count == 0 then true
          else all($replicas[]; .slaveIORunning == true and .slaveSQLRunning == true and ((.secondsBehindMaster // 0) <= $threshold))
          end
        ),
        replicas: $replicas,
        roles: (.status.replication.roles // {})
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
# .data object (compact) and returns 0. On failure sets BG_LOCAL_ERR to the
# child's response JSON and returns 1 (does NOT exit, so callers can roll back).
# BG_LOCAL_ERR is read by the orchestrator scripts that source this lib.
# shellcheck disable=SC2034
bg_local_step() {
  local script="$1"
  shift
  local out rc
  BG_LOCAL_ERR=""
  # Capture inside an `if` so a non-zero child does not trip the caller's set -e
  # before we can inspect the result.
  if out="$(env "$@" AQSH_RESULT_FILE= LIB_DIR="$LIB_DIR" bash "$script")"; then
    rc=0
  else
    rc=$?
  fi
  if (( rc != 0 )); then
    BG_LOCAL_ERR="$out"
    return 1
  fi
  # The granular script may emit non-JSON lines (e.g. `kubectl wait` output)
  # before its single-line JSON result, so parse the last line.
  jq -c '.data // {}' <<<"$(printf '%s\n' "$out" | tail -n1)" 2>/dev/null || printf '{}'
  return 0
}

# bg_peer_call_task <op> <peer_url> <peer_token> <task_path> <payload> [timeout_seconds]
# Submit a task to the peer AQSH, poll to completion, and echo its inner
# result data (compact JSON) on success returning 0. On any failure sets
# BG_PEER_ERR to a diagnostic JSON object and returns 1 (does NOT exit).
# BG_PEER_ERR is read by the orchestrator scripts that source this lib.
# shellcheck disable=SC2034
bg_peer_call_task() {
  local op="$1" peer_url="$2" peer_token="$3" task_path="$4" payload="$5" timeout="${6:-540}"
  local encoded submit code body task_id resp status elapsed=0

  BG_PEER_ERR=""
  encoded="${task_path//\//%2F}"

  submit="$(curl -sS --connect-timeout 5 -m 60 -w $'\n%{http_code}' \
    -X POST "${peer_url}/tasks/${encoded}" \
    -H "Authorization: Bearer ${peer_token}" \
    -H 'Content-Type: application/json' \
    -d "$payload" 2>/dev/null || true)"
  code="$(printf '%s' "$submit" | tail -n1)"
  body="$(printf '%s' "$submit" | sed '$d')"
  if [[ "$code" != "202" ]]; then
    BG_PEER_ERR="$(jq -n --arg task "$task_path" --arg code "$code" --arg body "$body" \
      '{peerTask: $task, httpCode: $code, body: $body}')"
    return 1
  fi
  task_id="$(jq -r '.id // empty' <<<"$body" 2>/dev/null || true)"
  if [[ -z "$task_id" ]]; then
    BG_PEER_ERR="$(jq -n --arg task "$task_path" --arg body "$body" '{peerTask: $task, body: $body}')"
    return 1
  fi

  while (( elapsed < timeout )); do
    resp="$(curl -sS --connect-timeout 5 -m 15 \
      -H "Authorization: Bearer ${peer_token}" \
      "${peer_url}/tasks/${task_id}" 2>/dev/null || true)"
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
        BG_PEER_ERR="$(jq -n --arg task "$task_path" \
          --argjson resp "$(jq -c '.' <<<"$resp" 2>/dev/null || printf '{}')" \
          '{peerTask: $task, peerResponse: $resp}')"
        return 1
        ;;
    esac
    sleep 5
    elapsed=$(( elapsed + 5 ))
  done

  BG_PEER_ERR="$(jq -n --arg task "$task_path" --arg id "$task_id" --argjson timeout "$timeout" \
    '{peerTask: $task, taskId: $id, timeoutSeconds: $timeout}')"
  return 1
}

# bg_require <name> <value> <op>  (alias of bg_required for orchestrator readability)
bg_validate_url() {
  local name="$1" value="$2" op="$3"
  if [[ ! "$value" =~ ^https?://[A-Za-z0-9._:/-]+$ ]]; then
    bg_fail "$op" "${name} must be an http(s) URL" "$(jq -n --arg field "$name" --arg value "$value" '{field: $field, value: $value}')" 2
  fi
}
