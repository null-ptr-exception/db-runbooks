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

bg_required() {
  local name="$1" value="$2" op="$3"
  if [[ -z "$value" ]]; then
    bg_fail "$op" "${name} is required" "{}" 2
  fi
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
