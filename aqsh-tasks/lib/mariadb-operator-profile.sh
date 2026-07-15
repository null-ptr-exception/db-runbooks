#!/usr/bin/env bash
# =============================================================================
# lib/mariadb-operator-profile.sh
# Detect which mariadb-operator generation a cluster runs and expose the
# resolved CRD apiGroup / apiVersion plus per-CRD availability.
#
# Two operator generations exist with different CRD groups:
#   - current: k8s.mariadb.com        (PhysicalBackup, ExternalMariaDB, ...)
#   - legacy:  mariadb.*.mmontes.io   (Backup/Restore only; no PhysicalBackup,
#                                       ExternalMariaDB, multiCluster)
# Tasks must build CRs and RBAC against the *real* group of the cluster they run
# on, and fail fast with a clear message when a required CRD is absent instead of
# emitting a cryptic `no matches for kind "PhysicalBackup"`.
#
# Resolution mirrors the 3-tier chain documented in CLAUDE.md:
#   1. Internal config  — MARIADB_OPERATOR_GROUP_DEFAULT, set once per deployment
#   2. Auto-detect      — the group serving the `mariadbs` CRD (present in BOTH
#                         generations); trusted only when exactly one group does
#   3. Hardcoded fallback — k8s.mariadb.com (current generation)
# Detection uses Kubernetes API discovery rather than reading cluster-scoped
# CustomResourceDefinition objects. Authenticated service accounts receive
# discovery access through Kubernetes' standard system:discovery binding, so
# tasks do not need a broad ClusterRoleBinding that can list every CRD.
# Detection fails soft: any ambiguity or query error falls through to the next
# tier, never a guess.
# =============================================================================

[[ -n "${_MARIADB_OPERATOR_PROFILE_LOADED:-}" ]] && return 0
_MARIADB_OPERATOR_PROFILE_LOADED=1

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  _MOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$_MOP_DIR"
fi

# shellcheck source=aqsh-tasks/lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=aqsh-tasks/lib/k8s.sh
source "${LIB_DIR}/k8s.sh"   # for _kubectl_global (API discovery is cluster-wide)

# Both generations serve these kinds at v1alpha1.
MDB_OPERATOR_VERSION="${MDB_OPERATOR_VERSION:-v1alpha1}"

# Tier-3 hardcoded fallback: the current generation's group.
_MDB_OPERATOR_GROUP_FALLBACK="k8s.mariadb.com"

# _mdb_discover_operator_groups
# Print every group serving the MariaDB kind. Unlike the tiered resolver below,
# this preserves API discovery failures so mutating capability routes can fail
# closed rather than confusing "unknown" with "CRD absent".
_mdb_discover_operator_groups() {
  local resources groups rc=0
  resources="$(_kubectl_global api-resources --cached=false -o name 2>/dev/null)" || rc=$?
  groups="$(sed -n 's/^mariadbs\.//p' <<<"$resources" | sed '/^$/d' | sort -u)"
  if [[ -n "$groups" ]]; then
    printf '%s\n' "$groups"
    return 0
  fi
  [[ "$rc" -eq 0 ]] || return 2
}

# _mdb_detect_operator_group
# Tier 2: return the CRD group serving the mariadbs kind (the one CRD both
# generations share), but only when exactly one group serves it — otherwise
# print nothing so resolution falls through. Never fails the caller.
_mdb_detect_operator_group() {
  local groups
  groups="$(_mdb_discover_operator_groups)" || return 0
  [[ "$(printf '%s\n' "$groups" | grep -c .)" -eq 1 ]] && printf '%s' "$groups"
  return 0
}

# mdb_operator_group
# Resolve the operator CRD apiGroup (3-tier, see header). Memoized in
# _MDB_OPERATOR_GROUP for the life of the process; unset it to force a re-resolve.
mdb_operator_group() {
  if [[ -n "${_MDB_OPERATOR_GROUP:-}" ]]; then
    printf '%s' "$_MDB_OPERATOR_GROUP"
    return 0
  fi
  local g=""
  if [[ -n "${MARIADB_OPERATOR_GROUP_DEFAULT:-}" ]]; then
    g="$MARIADB_OPERATOR_GROUP_DEFAULT"                 # tier 1
  else
    g="$(_mdb_detect_operator_group)"                   # tier 2
    [[ -n "$g" ]] || g="$_MDB_OPERATOR_GROUP_FALLBACK"  # tier 3
  fi
  _MDB_OPERATOR_GROUP="$g"
  printf '%s' "$g"
}

# mdb_operator_apiversion
# The resolved "<group>/<version>" string for building CRs. Replaces the
# hardcoded "k8s.mariadb.com/v1alpha1" literals across the tasks.
mdb_operator_apiversion() {
  printf '%s/%s' "$(mdb_operator_group)" "$MDB_OPERATOR_VERSION"
}

# mdb_operator_group_is_confident
# 0 when the selected group is explicitly configured or is the single group
# returned by live discovery. 1 means missing/ambiguous discovery; 2 means the
# discovery request itself failed. Mutating fallbacks must require rc=0.
mdb_operator_group_is_confident() {
  local group groups count rc=0
  group="$(mdb_operator_group)"
  if [[ -n "${MARIADB_OPERATOR_GROUP_DEFAULT:-}" ]]; then
    [[ "$MARIADB_OPERATOR_GROUP_DEFAULT" == "$group" ]]
    return
  fi
  groups="$(_mdb_discover_operator_groups)" || rc=$?
  [[ "$rc" -eq 0 ]] || return 2
  count="$(printf '%s\n' "$groups" | grep -c . || true)"
  [[ "$count" -eq 1 && "$groups" == "$group" ]]
}

# mdb_is_legacy_operator
# The historical forks use mariadb[.<fork>].mmontes.io. Keep the predicate in
# the profile layer so scripts never infer a generation from one missing CRD.
mdb_is_legacy_operator() {
  case "$(mdb_operator_group)" in
    mariadb*.mmontes.io) return 0 ;;
    *) return 1 ;;
  esac
}

# mdb_crd_status <plural>
# Tri-state capability query:
#   0 = definitely present, 1 = definitely absent, 2 = discovery unavailable.
# This is intentionally distinct from a plain boolean because absence enables
# the hand-rolled legacy path, whereas "unknown" must never enable mutations.
mdb_crd_status() {
  local plural="${1:?plural is required}" group resources rc=0
  group="$(mdb_operator_group)"
  resources="$(_kubectl_global api-resources --cached=false --api-group="$group" -o name 2>/dev/null)" || rc=$?
  grep -Fxq "${plural}.${group}" <<<"$resources" && return 0
  # A partial result for the requested group proves that its discovery worked;
  # a non-zero kubectl status may only describe an unrelated broken APIService.
  [[ "$rc" -eq 0 || "$resources" == *".${group}"* ]] && return 1
  return 2
}

# mdb_has_crd <plural>
# Compatibility boolean used by older callers. New mutating routes should call
# mdb_crd_status so an API discovery error is not treated as confirmed absence.
mdb_has_crd() {
  mdb_crd_status "$1"
}

# mdb_physical_backup_mode
# Print "operator" only for a confidently selected current group with the
# PhysicalBackup CRD; print "hand-rolled" only for a confidently selected
# legacy mmontes group where that CRD is confirmed absent.
# rc 2 = discovery unknown/ambiguous, rc 3 = inconsistent/unsupported profile.
mdb_physical_backup_mode() {
  local group capability_rc=0
  mdb_operator_group_is_confident || return 2
  group="$(mdb_operator_group)"
  mdb_crd_status physicalbackups || capability_rc=$?
  [[ "$capability_rc" -ne 2 ]] || return 2

  if [[ "$group" == "k8s.mariadb.com" && "$capability_rc" -eq 0 ]]; then
    printf 'operator'
    return 0
  fi
  if mdb_is_legacy_operator && [[ "$capability_rc" -eq 1 ]]; then
    printf 'hand-rolled'
    return 0
  fi
  return 3
}

# mdb_require_crd <plural> <op> [hint]
# Fail fast via mdbt_fail (loaded by mariadb-task-common.sh) when a required CRD
# is absent, turning `no matches for kind` into an actionable message. Returns
# non-zero after writing the failure result so the caller can `|| exit`.
mdb_require_crd() {
  local plural="${1:?plural is required}" op="${2:?op is required}" hint="${3:-}" rc=0
  mdb_crd_status "$plural" || rc=$?
  [[ "$rc" -ne 0 ]] || return 0
  local group; group="$(mdb_operator_group)"
  if [[ "$rc" -eq 2 ]]; then
    mdbt_fail "$op" \
      "could not verify the '${plural}' capability for mariadb-operator group ${group}; Kubernetes API discovery failed" \
      "$(jq -n --arg c "${plural}.${group}" '{capability: $c, discovery: "unknown"}')" 1
  fi
  mdbt_fail "$op" \
    "this cluster's mariadb-operator (group ${group}) has no '${plural}' CRD${hint:+; ${hint}}" \
    "$(jq -n --arg c "${plural}.${group}" '{missingCrd: $c}')" 2
}
