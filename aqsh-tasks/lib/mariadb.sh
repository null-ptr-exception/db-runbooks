#!/usr/bin/env bash
# =============================================================================
# lib/mariadb.sh
# Shared MariaDB operator helpers for AQSH, Rundeck, and local runbook scripts.
#
# The helpers are read-only unless a caller explicitly runs a mutating SQL or
# kubectl command through the lower-level wrappers.
# =============================================================================

[[ -n "${_MARIADB_LIB_LOADED:-}" ]] && return 0
_MARIADB_LIB_LOADED=1

MARIADB_RESOURCE="${MARIADB_RESOURCE:-mariadb}"
MARIADB_NAME="${MARIADB_NAME:-${MARIADB_STS_NAME:-mariadb}}"
MARIADB_CONTAINER="${MARIADB_CONTAINER:-mariadb}"
MARIADB_ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD:-}"

mariadb_set_target() {
  K8S_CONTEXT="${1:-${K8S_CONTEXT:-}}"
  K8S_NAMESPACE="${2:-${K8S_NAMESPACE:-default}}"
  MARIADB_RESOURCE="${3:-${MARIADB_RESOURCE:-mariadb}}"
  MARIADB_NAME="${4:-${MARIADB_NAME:-mariadb}}"
  MARIADB_CONTAINER="${5:-${MARIADB_CONTAINER:-mariadb}}"
}

mariadb_jsonpath() {
  local resource="${1:?resource is required}"
  local name="${2:?name is required}"
  local path="${3:?jsonpath is required}"

  _kubectl get "$resource" "$name" -o "jsonpath=${path}" 2>/dev/null
}

mariadb_service_jsonpath() {
  local service="${1:?service is required}"
  local path="${2:?jsonpath is required}"

  _kubectl get service "$service" -o "jsonpath=${path}" 2>/dev/null
}

mariadb_pod_jsonpath() {
  local pod="${1:?pod is required}"
  local path="${2:?jsonpath is required}"

  _kubectl get pod "$pod" -o "jsonpath=${path}" 2>/dev/null
}

mariadb_pod_name() {
  local index="${1:?pod index is required}"
  printf '%s-%s' "$MARIADB_NAME" "$index"
}

mariadb_sts_replicas() {
  _kubectl get statefulset "$MARIADB_NAME" -o jsonpath='{.spec.replicas}' 2>/dev/null
}

mariadb_cr_replicas() {
  mariadb_jsonpath "$MARIADB_RESOURCE" "$MARIADB_NAME" '{.spec.replicas}'
}

mariadb_list_pods() {
  local replicas="${1:-}"

  if [[ -n "$replicas" ]] && [[ "$replicas" != "0" ]]; then
    local index
    for index in $(seq 0 $((replicas - 1))); do
      mariadb_pod_name "$index"
    done
    return 0
  fi

  local pods
  pods=$(_kubectl get pods -l "app.kubernetes.io/instance=${MARIADB_NAME}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null) || true
  if [[ -z "$pods" ]]; then
    pods=$(_kubectl get pods \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep "^${MARIADB_NAME}-" || true)
  fi
  printf '%s\n' "$pods" | sed '/^$/d' | sort
}

mariadb_exec() {
  local pod="${1:?pod is required}"
  shift

  _kubectl exec "$pod" -c "$MARIADB_CONTAINER" -- "$@"
}

mariadb_read_root_password() {
  local current_primary="${1:-}"
  shift || true
  local candidates=("$@")
  local pod password

  if [[ -n "$MARIADB_ROOT_PASSWORD" ]]; then
    printf '%s\n' "$MARIADB_ROOT_PASSWORD"
    return 0
  fi

  if [[ -n "$current_primary" ]]; then
    candidates=("$current_primary" "${candidates[@]}")
  fi

  for pod in "${candidates[@]}"; do
    [[ -z "$pod" ]] && continue
    password=$(mariadb_exec "$pod" printenv MARIADB_ROOT_PASSWORD 2>/dev/null) || true
    if [[ -n "$password" ]]; then
      printf '%s\n' "$password"
      return 0
    fi
  done

  return 1
}

mariadb_sql() {
  local pod="${1:?pod is required}"
  local password="${2:?password is required}"
  local query="${3:?query is required}"

  mariadb_exec "$pod" mariadb -u root -p"$password" -N -B -e "$query" 2>/dev/null
}

mariadb_sql_vertical() {
  local pod="${1:?pod is required}"
  local password="${2:?password is required}"
  local query="${3:?query is required}"

  mariadb_exec "$pod" mariadb -u root -p"$password" -E -e "$query" 2>/dev/null
}

mariadb_status_field() {
  local key="${1:?status key is required}"
  awk -F': *' -v key="$key" '$1 ~ "^[* ]*" key "$" { print $2; exit }'
}

mariadb_gtid_covers() {
  local required="$1"
  local actual="$2"

  awk -v required="$required" -v actual="$actual" '
    function remember(set, seen, part, n, i, q, k, fields) {
      n = split(set, part, ",")
      for (i = 1; i <= n; i++) {
        if (part[i] == "") {
          continue
        }
        fields = split(part[i], q, "-")
        if (fields != 3) {
          continue
        }
        k = q[1] "-" q[2]
        if (!(k in seen) || q[3] + 0 > seen[k]) {
          seen[k] = q[3] + 0
        }
      }
    }
    BEGIN {
      remember(actual, actual_seen)
      n = split(required, required_part, ",")
      for (i = 1; i <= n; i++) {
        if (required_part[i] == "") {
          continue
        }
        fields = split(required_part[i], q, "-")
        if (fields != 3) {
          continue
        }
        k = q[1] "-" q[2]
        if (!(k in actual_seen) || actual_seen[k] + 0 < q[3] + 0) {
          exit 1
        }
      }
      exit 0
    }'
}

mariadb_primary_service_name() {
  printf '%s-primary' "$MARIADB_NAME"
}
