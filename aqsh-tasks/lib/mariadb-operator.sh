#!/usr/bin/env bash
# =============================================================================
# lib/mariadb-operator.sh
# MariaDB operator helpers for CR annotation-driven operations.
# =============================================================================

[[ -n "${_MARIADB_OPERATOR_LIB_LOADED:-}" ]] && return 0
_MARIADB_OPERATOR_LIB_LOADED=1

mariadb_operator_metadata_field_supported() {
  local resource="${1:?resource is required}"
  local field="${2:?field is required}"

  _kubectl_global explain "${resource}.spec.${field}" >/dev/null 2>&1
}

mariadb_operator_select_restart_metadata_field() {
  local resource="${1:?resource is required}"
  local requested_field="${2:?metadata field is required}"

  case "$requested_field" in
    auto)
      if mariadb_operator_metadata_field_supported "$resource" "podMetadata"; then
        printf 'podMetadata'
        return 0
      fi
      if mariadb_operator_metadata_field_supported "$resource" "inheritMetadata"; then
        printf 'inheritMetadata'
        return 0
      fi
      return 1
      ;;
    podMetadata | inheritMetadata)
      mariadb_operator_metadata_field_supported "$resource" "$requested_field" || return 1
      printf '%s' "$requested_field"
      ;;
    *)
      return 2
      ;;
  esac
}

mariadb_operator_patch_restart_annotation() {
  local resource="${1:?resource is required}"
  local name="${2:?name is required}"
  local metadata_field="${3:?metadata field is required}"
  local annotation_key="${4:?annotation key is required}"
  local annotation_value="${5:?annotation value is required}"
  local patch_json

  patch_json=$(jq -nc \
    --arg field "$metadata_field" \
    --arg key "$annotation_key" \
    --arg value "$annotation_value" \
    '{spec: {($field): {annotations: {($key): $value}}}}')

  _kubectl patch "$resource" "$name" --type merge -p "$patch_json" 2>&1
}

mariadb_operator_resolve_primary() {
  local resource="${1:?resource is required}"
  local name="${2:?name is required}"
  local root_password="${3:-}"
  shift 3 || true
  local pods=("$@")
  local primary index pod read_only

  primary=$(mariadb_jsonpath "$resource" "$name" '{.status.currentPrimary}' 2>/dev/null || true)
  if [[ -z "$primary" ]]; then
    index=$(mariadb_jsonpath "$resource" "$name" '{.status.currentPrimaryPodIndex}' 2>/dev/null || true)
    [[ -n "$index" ]] && primary=$(mariadb_pod_name "$index")
  fi
  if [[ -z "$primary" && -n "$root_password" ]]; then
    for pod in "${pods[@]}"; do
      read_only=$(mariadb_sql "$pod" "$root_password" 'SELECT @@read_only' 2>/dev/null || true)
      if [[ "$read_only" == "0" ]]; then
        primary="$pod"
        break
      fi
    done
  fi
  printf '%s' "$primary"
}

mariadb_operator_pod_ready() {
  local pod="${1:?pod is required}"
  local container="${2:?container is required}"
  local ready

  ready=$(mariadb_pod_jsonpath "$pod" \
    "{.status.containerStatuses[?(@.name==\"${container}\")].ready}" 2>/dev/null || true)
  [[ "$ready" == "true" ]]
}

mariadb_operator_build_pods_json() {
  local container="${1:?container is required}"
  local primary_before="${2:-}"
  local root_password="${3:-}"
  shift 3 || true
  local pods=("$@")
  local pods_json="[]" pod ready role read_only uid restarted ready_after

  for pod in "${pods[@]}"; do
    ready=false
    mariadb_operator_pod_ready "$pod" "$container" && ready=true

    role="unknown"
    if [[ -n "$pod" && "$pod" == "$primary_before" ]]; then
      role="primary"
    elif [[ -n "$root_password" ]]; then
      read_only=$(mariadb_sql "$pod" "$root_password" 'SELECT @@read_only' 2>/dev/null || true)
      case "$read_only" in
        0) role="primary" ;;
        1) role="replica" ;;
      esac
    fi

    uid=$(mariadb_pod_jsonpath "$pod" '{.metadata.uid}' 2>/dev/null || true)
    restarted=false
    ready_after=null
    if [[ -n "${POD_RESTARTED[$pod]:-}" ]]; then
      restarted="${POD_RESTARTED[$pod]}"
      ready_after="${POD_READY_AFTER[$pod]:-false}"
    fi

    pods_json=$(jq -c \
      --arg name "$pod" \
      --arg role "$role" \
      --arg uid "$uid" \
      --argjson ready "$(task_json_bool "$ready")" \
      --argjson restarted "$(task_json_bool "$restarted")" \
      --argjson ready_after "$ready_after" \
      '. + [{
        name: $name,
        role: $role,
        uid_before: ($uid | if . == "" then null else . end),
        ready_before: $ready,
        restarted: $restarted,
        ready_after: $ready_after
      }]' \
      <<<"$pods_json")
  done

  printf '%s' "$pods_json"
}

# shellcheck disable=SC2034  # Populates restart task globals consumed by the entrypoint and result helper.
mariadb_operator_load_restart_state() {
  local resource="${1:?resource is required}"
  local name="${2:?name is required}"
  local container="${3:?container is required}"
  local pod

  UPDATE_STRATEGY=$(mariadb_jsonpath "$resource" "$name" '{.spec.updateStrategy.type}' 2>/dev/null || true)
  [[ -z "$UPDATE_STRATEGY" ]] && UPDATE_STRATEGY="ReplicasFirstPrimaryLast"

  REPLICAS=$(mariadb_cr_replicas 2>/dev/null || true)
  mapfile -t PODS < <(mariadb_list_pods "$REPLICAS")

  ROOT_PASSWORD=""
  if [[ "${#PODS[@]}" -gt 0 ]]; then
    ROOT_PASSWORD=$(mariadb_read_root_password "" "${PODS[@]}" 2>/dev/null || true)
  fi

  PRIMARY_BEFORE=$(mariadb_operator_resolve_primary "$resource" "$name" "$ROOT_PASSWORD" "${PODS[@]}")

  for pod in "${PODS[@]}"; do
    POD_UID_BEFORE["$pod"]=$(mariadb_pod_jsonpath "$pod" '{.metadata.uid}' 2>/dev/null || true)
    POD_RESTARTED["$pod"]=false
    POD_READY_AFTER["$pod"]=null
  done

  PODS_JSON=$(mariadb_operator_build_pods_json "$container" "$PRIMARY_BEFORE" "$ROOT_PASSWORD" "${PODS[@]}")
}

mariadb_operator_wait_for_restart() {
  local container="${1:?container is required}"
  local timeout="${2:?timeout is required}"
  shift 2 || true
  local pods=("$@")
  local start now pod old_uid new_uid all_restarted

  start=$(date +%s)
  while true; do
    all_restarted=true
    for pod in "${pods[@]}"; do
      old_uid="${POD_UID_BEFORE[$pod]:-}"
      new_uid=$(mariadb_pod_jsonpath "$pod" '{.metadata.uid}' 2>/dev/null || true)
      if [[ -n "$new_uid" && -n "$old_uid" && "$new_uid" != "$old_uid" ]] \
        && mariadb_operator_pod_ready "$pod" "$container"; then
        POD_RESTARTED["$pod"]=true
        POD_READY_AFTER["$pod"]=true
      else
        all_restarted=false
        if [[ -n "$new_uid" && -n "$old_uid" && "$new_uid" != "$old_uid" ]]; then
          POD_RESTARTED["$pod"]=true
        fi
        if mariadb_operator_pod_ready "$pod" "$container"; then
          POD_READY_AFTER["$pod"]=true
        else
          POD_READY_AFTER["$pod"]=false
        fi
      fi
    done

    [[ "$all_restarted" == "true" ]] && return 0

    now=$(date +%s)
    if (( now - start >= timeout )); then
      return 1
    fi
    sleep 5
  done
}
