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
# pods_fetch_json <pod_name>
# Single-call snapshot of one Pod's full object. The delete flow derives
# existence, StatefulSet ownership, readiness, and UID from this one
# consistent read, rather than checking membership against a separately
# listed live member set (which silently drops an already-deleted target —
# making "already gone" indistinguishable from "never a member" — and gives
# no UID to guard a confirmed delete against a same-name replacement Pod
# that already exists by the time the confirm call runs).
#
# rc 0: pod found — JSON printed to stdout.
# rc 1: confirmed negative — the API server returned NotFound.
# rc 2: the kubectl call itself failed for any other reason (API/auth/
#       transport error) — NOT a confirmed negative. Callers must not treat
#       this the same as rc 1: collapsing a transient read failure into
#       "pod is gone" can report a false POD_ALREADY_DELETED success while
#       an API outage — not an actual deletion — is what happened.
# ---------------------------------------------------------------------------
pods_fetch_json() {
  local pod="${1:?pod is required}"
  # stderr goes to a temp file, not 2>&1 (same idiom as k8s_get_sts_pods):
  # kubectl can emit exit-0 stderr in shapes we can't enumerate (admission
  # "Warning:" lines, client-go throttling notices, plugin output), and any
  # of it merged into stdout would corrupt the JSON parsed downstream by
  # pods_owned_by_sts/pods_uid/pods_ready — silently making a healthy Pod
  # look like a non-member or non-ready one.
  local out stderr_tmp err_detail
  stderr_tmp=$(mktemp)
  if out=$(_kubectl get pod "$pod" -o json 2>"$stderr_tmp"); then
    rm -f "$stderr_tmp"
    printf '%s\n' "$out"
    return 0
  fi
  err_detail=$(cat "$stderr_tmp")
  rm -f "$stderr_tmp"
  grep -qi 'notfound' <<<"$err_detail" && return 1
  log_error "pods_fetch_json" "could not read ${pod}: ${err_detail}"
  return 2
}

# ---------------------------------------------------------------------------
# pods_owned_by_sts <pod_json> <sts_name>
# rc 0 iff <pod_json>'s ownerReferences name a StatefulSet called
# <sts_name> — exact ownership, never a label/name guess (same rationale as
# _k8s_sts_owned_pod_names). Pure JSON check over an already-fetched object,
# no kubectl call of its own.
# ---------------------------------------------------------------------------
pods_owned_by_sts() {
  local pod_json="${1:?pod_json is required}" sts_name="${2:?sts_name is required}"
  jq -e --arg sts "$sts_name" \
    'any(.metadata.ownerReferences[]?; .kind == "StatefulSet" and .name == $sts)' \
    <<<"$pod_json" >/dev/null
}

# ---------------------------------------------------------------------------
# pods_uid <pod_json> / pods_ready <pod_json>
# Pure extraction/predicate helpers over a pods_fetch_json result — no
# kubectl call. pods_ready's rc 0 means the Ready condition is "True"; used
# to decide graceful vs. forced delete — never a caller-facing input, since
# a stuck not-Ready pod is exactly the case a forced delete exists to
# unblock (same rationale as recovery_wipe_pod in mongodb-recovery.sh).
# ---------------------------------------------------------------------------
pods_uid() {
  jq -r '.metadata.uid // empty' <<<"${1:?pod_json is required}"
}

pods_ready() {
  jq -e '([.status.conditions[]? | select(.type == "Ready") | .status] | first) == "True"' \
    <<<"${1:?pod_json is required}" >/dev/null
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
# idempotent for its own callers too: pods_fetch_json is checked first, but
# the Pod can disappear between that check and this call (e.g. a concurrent
# delete), and a named-Pod delete does not treat NotFound as success by
# default. stdout/stderr of kubectl is returned to the caller for error
# reporting. force=true adds --grace-period=0 --force (used only when the
# pod is not Ready — see pods_ready).
#
# This does NOT take a UID precondition: the `kubectl delete` CLI has no
# flag for one (client-go's DeleteOptions.Preconditions.UID is not exposed
# via any documented flag). Callers that need identity-aware delete
# semantics (see mongodb/pods/delete.sh, mariadb/pods/delete.sh) compare
# pods_uid's freshly-fetched value against a caller-supplied expected UID
# themselves, immediately before calling this function — a script-level
# check, not a server-enforced atomic precondition.
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
