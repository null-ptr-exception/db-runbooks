#!/usr/bin/env bash
# =============================================================================
# lib/pods.sh
# Shared, DB-agnostic Kubernetes Pod status/delete helpers for the pods/*
# gateway tasks (see docs/mongodb/pods.md, docs/mariadb/pods.md). Pure K8s-API
# formatting only — no DB instance/credential awareness, no other task family
# depends on these functions, so they carry zero risk of breaking any
# existing task. Callers (mongodb/pods/*.sh, mariadb/pods/*.sh) are
# responsible for resolving the DB instance and its exact member-pod names
# using their own DB-specific libs (mongodb-recovery.sh / mariadb.sh) before
# calling in here.
# =============================================================================

[[ -n "${_PODS_LIB_LOADED:-}" ]] && return 0
_PODS_LIB_LOADED=1

# ---------------------------------------------------------------------------
# pods_status_json <member_pod_names>
# <member_pod_names>: newline-separated pod names (already resolved by the
# caller to be exact members of one DB instance — this function does not
# discover membership itself).
#
# Fetches all pods in K8S_NAMESPACE once and formats only the named members
# into a JSON array, sorted by ordinal:
#   [{name, ordinal, phase, ready ("<ready>/<total>"), restarts, node,
#     podIP, startTime, ageSeconds}]
#
# A member name with no matching live pod (e.g. mid-recreation) is silently
# omitted from the array rather than erroring — the caller's `count` will
# simply be lower than the member list for that instant. Returns 1 only when
# the pod listing itself fails.
# ---------------------------------------------------------------------------
pods_status_json() {
  local member_names="${1:-}"
  local op="pods_status_json"

  local pods_raw
  if ! pods_raw=$(_kubectl get pods -o json 2>&1); then
    log_error "$op" "Failed to list pods in namespace '$K8S_NAMESPACE': $pods_raw"
    return 1
  fi

  local members_json
  members_json=$(printf '%s\n' "$member_names" | jq -R -s -c 'split("\n") | map(select(length > 0))')
  log_debug "$op" "formatting status for members=$(jq -c . <<<"$members_json")"

  jq -c --argjson members "$members_json" '
    [ .items[]
      | select(.metadata.name as $n | $members | index($n) != null)
      | {
          name: .metadata.name,
          ordinal: (try (.metadata.name | capture("-(?<n>[0-9]+)$") | .n | tonumber) catch null),
          phase: (.status.phase // "Unknown"),
          ready: (
            ((.status.containerStatuses // []) | length) as $total
            | ((.status.containerStatuses // []) | map(select(.ready == true)) | length) as $ready
            | "\($ready)/\($total)"
          ),
          restarts: ((.status.containerStatuses // []) | map(.restartCount // 0) | add // 0),
          node: (.spec.nodeName // null),
          podIP: (.status.podIP // null),
          startTime: (.status.startTime // null),
          ageSeconds: (if .status.startTime then ((now - (.status.startTime | fromdateiso8601)) | floor) else null end)
        }
    ] | sort_by(.ordinal)
  ' <<<"$pods_raw"
}

# ---------------------------------------------------------------------------
# pods_is_ready <pod_name>
# True (rc 0) when the pod's Ready condition is "True". Used to decide
# graceful vs. forced delete — never a caller-facing input, since a stuck
# not-Ready pod is exactly the case a forced delete exists to unblock (same
# rationale as recovery_wipe_pod in mongodb-recovery.sh).
# ---------------------------------------------------------------------------
pods_is_ready() {
  local pod="${1:?pod is required}"
  local status
  status=$(_kubectl get pod "$pod" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || return 1
  [[ "$status" == "True" ]]
}

# ---------------------------------------------------------------------------
# pods_exists <pod_name>
# True (rc 0) when the pod is still present in the live cluster.
# ---------------------------------------------------------------------------
pods_exists() {
  local pod="${1:?pod is required}"
  _kubectl get pod "$pod" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# pods_delete <pod_name> <force: true|false>
# Issues the delete; stdout/stderr of kubectl is returned to the caller for
# error reporting. force=true adds --grace-period=0 --force (used only when
# the pod is not Ready — see pods_is_ready).
# ---------------------------------------------------------------------------
pods_delete() {
  local pod="${1:?pod is required}"
  local force="${2:-false}"
  if [[ "$force" == "true" ]]; then
    _kubectl delete pod "$pod" --grace-period=0 --force 2>&1
  else
    _kubectl delete pod "$pod" 2>&1
  fi
}
