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
# rc 0: the pod's Ready condition is "True".
# rc 1: confirmed negative — the pod exists but isn't Ready, or is gone
#       (NotFound). Used to decide graceful vs. forced delete — never a
#       caller-facing input, since a stuck not-Ready pod is exactly the case
#       a forced delete exists to unblock (same rationale as
#       recovery_wipe_pod in mongodb-recovery.sh).
# rc 2: the kubectl call itself failed (API/auth/transport error) — NOT a
#       confirmed negative. Callers must not treat this the same as rc 1:
#       collapsing a transient read failure into "not ready" would force a
#       --grace-period=0 --force delete based on no real signal.
# ---------------------------------------------------------------------------
pods_is_ready() {
  local pod="${1:?pod is required}"
  local out
  if ! out=$(_kubectl get pod "$pod" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>&1); then
    grep -qi 'notfound' <<<"$out" && return 1
    log_error "pods_is_ready" "could not determine readiness of ${pod}: ${out}"
    return 2
  fi
  [[ "$out" == "True" ]]
}

# ---------------------------------------------------------------------------
# pods_exists <pod_name>
# rc 0: the pod is present in the live cluster.
# rc 1: confirmed negative — the API server returned NotFound.
# rc 2: the kubectl call itself failed for any other reason (API/auth/
#       transport error) — NOT a confirmed negative. Callers must not treat
#       this the same as rc 1: collapsing a transient read failure into
#       "pod is gone" can report a false POD_ALREADY_DELETED success while
#       an API outage — not an actual deletion — is what happened.
# ---------------------------------------------------------------------------
pods_exists() {
  local pod="${1:?pod is required}"
  local out
  if out=$(_kubectl get pod "$pod" -o name 2>&1); then
    return 0
  fi
  grep -qi 'notfound' <<<"$out" && return 1
  log_error "pods_exists" "could not determine whether ${pod} exists: ${out}"
  return 2
}

# ---------------------------------------------------------------------------
# pods_delete <pod_name> <force: true|false>
# Issues the delete and returns as soon as the API server accepts it
# (--wait=false) — callers only "issue" the delete, they never wait for the
# Pod to fully terminate (see docs/mongodb/pods.md, docs/mariadb/pods.md).
# Without --wait=false, `kubectl delete pod` blocks until the Pod object is
# fully removed, which can outlast the task's own exec timeout under normal
# termination-grace-period delays or cluster slowness and turn a successful
# delete into a spurious task failure. --ignore-not-found keeps this call
# idempotent for its own callers too: pods_exists is checked first, but the
# Pod can disappear between that check and this call (e.g. a concurrent
# delete), and a named-Pod delete does not treat NotFound as success by
# default. stdout/stderr of kubectl is returned to the caller for error
# reporting. force=true adds --grace-period=0 --force (used only when the
# pod is not Ready — see pods_is_ready).
# ---------------------------------------------------------------------------
pods_delete() {
  local pod="${1:?pod is required}"
  local force="${2:-false}"
  if [[ "$force" == "true" ]]; then
    _kubectl delete pod "$pod" --grace-period=0 --force --wait=false --ignore-not-found 2>&1
  else
    _kubectl delete pod "$pod" --wait=false --ignore-not-found 2>&1
  fi
}
