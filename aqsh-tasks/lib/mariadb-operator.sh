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

mariadb_operator_pod_ready() {
  local pod="${1:?pod is required}"
  local container="${2:?container is required}"
  local ready

  ready=$(mariadb_pod_jsonpath "$pod" \
    "{.status.containerStatuses[?(@.name==\"${container}\")].ready}" 2>/dev/null || true)
  [[ "$ready" == "true" ]]
}

# Build the per-pod evidence array for the result JSON. Each entry records the
# pod's UID before the restart and, once the operator has rolled it, whether it
# was recreated and became Ready again. No role/SQL inspection — the operator
# owns the rollout, the task only reports whether it happened.
mariadb_operator_build_pods_json() {
  local pods=("$@")
  local pods_json="[]" pod uid restarted ready_after

  for pod in "${pods[@]}"; do
    uid="${POD_UID_BEFORE[$pod]:-}"
    restarted="${POD_RESTARTED[$pod]:-false}"
    ready_after="${POD_READY_AFTER[$pod]:-null}"

    pods_json=$(jq -c \
      --arg name "$pod" \
      --arg uid "$uid" \
      --argjson restarted "$restarted" \
      --argjson ready_after "$ready_after" \
      '. + [{
        name: $name,
        uid_before: ($uid | if . == "" then null else . end),
        restarted: $restarted,
        ready_after: $ready_after
      }]' \
      <<<"$pods_json")
  done

  printf '%s' "$pods_json"
}

mariadb_operator_load_restart_state() {
  local resource="${1:?resource is required}"
  local name="${2:?name is required}"
  local pod

  # shellcheck disable=SC2034  # Globals are consumed by restart result helpers.
  declare -gA POD_UID_BEFORE=()
  # shellcheck disable=SC2034
  declare -gA POD_RESTARTED=()
  # shellcheck disable=SC2034
  declare -gA POD_READY_AFTER=()

  UPDATE_STRATEGY=$(mariadb_jsonpath "$resource" "$name" '{.spec.updateStrategy.type}' 2>/dev/null || true)
  [[ -z "$UPDATE_STRATEGY" ]] && UPDATE_STRATEGY="ReplicasFirstPrimaryLast"

  REPLICAS=$(mariadb_cr_replicas 2>/dev/null || true)
  mapfile -t PODS < <(mariadb_list_pods "$REPLICAS")

  for pod in "${PODS[@]}"; do
    POD_UID_BEFORE["$pod"]=$(mariadb_pod_jsonpath "$pod" '{.metadata.uid}' 2>/dev/null || true)
    POD_RESTARTED["$pod"]=false
    POD_READY_AFTER["$pod"]=null
  done

  # shellcheck disable=SC2034  # Restart entrypoint uses this global in result payloads.
  PODS_JSON=$(mariadb_operator_build_pods_json "${PODS[@]}")
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
