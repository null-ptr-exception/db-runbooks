#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/restart.sh
# Operator-driven restart: patch the MariaDB CR restart annotation, then check
# that mariadb-operator recreated every pod and brought it back Ready.
#
# Self-contained on purpose, like the other mariadb tasks. The only task helper
# kept in a lib is mariadb-operator.sh (kubectl/jq plumbing + the rollout wait
# loop). The flow is deliberately just: guards -> patch -> check.
# =============================================================================

# Capture the caller-supplied target name BEFORE sourcing libs — lib/mariadb.sh
# defaults MARIADB_NAME to "mariadb" at load time. Empty here means auto-detect.
MDB_INPUT="${MARIADB_NAME:-${MARIADB_STS_NAME:-}}"

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
fi
# shellcheck source=../../lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=../../lib/response.sh
source "${LIB_DIR}/response.sh"
# shellcheck source=../../lib/k8s.sh
source "${LIB_DIR}/k8s.sh"
# shellcheck source=../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"
# shellcheck source=../../lib/mariadb-operator.sh
source "${LIB_DIR}/mariadb-operator.sh"

bool() { case "${1:-}" in 1 | true | TRUE | yes | YES | on | ON) return 0 ;; *) return 1 ;; esac; }

# Emit the structured task result (to stdout and $AQSH_RESULT_FILE if set).
emit() {
  local status="$1" reason="$2" summary="$3" changed="$4" pods="${5:-[]}" out
  out=$(jq -nc \
    --arg status "$status" --arg reason "$reason" --arg summary "$summary" \
    --arg namespace "$NAMESPACE" --arg mdb "$MDB" \
    --arg annotation_key "$ANNOTATION_KEY" --arg metadata_field "${METADATA_FIELD:-}" \
    --argjson dry_run "$(bool "$DRY_RUN" && echo true || echo false)" \
    --argjson confirm "$(bool "$CONFIRM" && echo true || echo false)" \
    --argjson changed "$changed" --argjson pods "$pods" \
    '{
      status: $status, reason_code: $reason, summary: $summary,
      namespace: $namespace, mdb: $mdb, operator_controlled: true,
      annotation: { key: $annotation_key, metadata_field: ($metadata_field | if . == "" then null else . end) },
      dry_run: $dry_run, confirm: $confirm, changed: $changed, pods: $pods
    }')
  [[ -n "${RESULT_FILE:-}" ]] && printf '%s\n' "$out" > "$RESULT_FILE"
  printf '%s\n' "$out"
}

# --- inputs ------------------------------------------------------------------
CONTEXT="${K8S_CONTEXT:-}"
NAMESPACE="${DB_NAMESPACE:-${K8S_NAMESPACE:-}}"
RESOURCE="${MARIADB_RESOURCE:-mariadb}"
# Empty when the caller gave no name → target CR auto-detected from the namespace.
MDB="$MDB_INPUT"
CONTAINER="${MARIADB_CONTAINER:-mariadb}"
DRY_RUN="${DRY_RUN:-true}"
CONFIRM="${CONFIRM:-false}"
ANNOTATION_KEY="${RESTART_ANNOTATION_KEY:-aqsh.null-ptr-exception.dev/restarted-at}"
RESTART_METADATA_FIELD="${RESTART_METADATA_FIELD:-auto}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
RESULT_FILE="${AQSH_RESULT_FILE:-}"
METADATA_FIELD=""
JSON_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --resource) RESOURCE="$2"; shift 2 ;;
    --mdb | --name) MDB="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --dry-run) DRY_RUN="$2"; shift 2 ;;
    --confirm) CONFIRM="$2"; shift 2 ;;
    --annotation-key) ANNOTATION_KEY="$2"; shift 2 ;;
    --metadata-field) RESTART_METADATA_FIELD="$2"; shift 2 ;;
    --wait-timeout) WAIT_TIMEOUT="$2"; shift 2 ;;
    --result-file) RESULT_FILE="$2"; shift 2 ;;
    --json) JSON_ONLY=1; shift ;;
    -h | --help) echo "usage: restart.sh --namespace <ns> [--dry-run false --confirm true] [--metadata-field auto] [--annotation-key KEY] [--wait-timeout 300]" >&2; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$NAMESPACE" ]] || { echo "error: --namespace is required" >&2; exit 2; }
case "$WAIT_TIMEOUT" in '' | *[!0-9]*) echo "error: --wait-timeout must be an unsigned integer" >&2; exit 2 ;; esac

mariadb_set_target "$CONTEXT" "$NAMESPACE" "$RESOURCE" "$MDB" "$CONTAINER"
[[ "$JSON_ONLY" -eq 1 ]] || log_info "mariadb-restart" "namespace=${NAMESPACE} mdb=${MDB} dry_run=${DRY_RUN}"

# --- guards ------------------------------------------------------------------
k8s_check >/dev/null || { emit ERROR KUBECTL_UNAVAILABLE "Kubernetes API is not reachable" false; exit 0; }

# Auto-detect the target CR when --mdb / MARIADB_NAME was not supplied. Restart
# is operator-driven, so only CRs are considered (no StatefulSet fallback). The
# emitters exit, so the helper never returns on the failure paths.
_on_ambiguous() { emit BLOCKED MARIADB_AMBIGUOUS "Multiple MariaDB CRs in namespace ($1); specify --mdb" false; exit 0; }
_on_none()      { emit BLOCKED MARIADB_OPERATOR_REQUIRED "No MariaDB CR found; operator-driven restart needs a mariadb-operator resource" false; exit 0; }

if [[ -z "$MDB" ]]; then
  mariadb_autodetect_target false _on_ambiguous _on_none
  MDB="$MARIADB_NAME"
  [[ "$JSON_ONLY" -eq 1 ]] || log_info "mariadb-restart" "auto-detected mdb=${MDB}"
fi

mariadb_jsonpath "$RESOURCE" "$MDB" '{.metadata.name}' >/dev/null 2>&1 \
  || { emit BLOCKED MARIADB_OPERATOR_REQUIRED "MariaDB CR not found; operator-driven restart needs a mariadb-operator resource" false; exit 0; }

# Guard 1: the CRD must expose a Pod-template metadata field to carry the
# annotation (podMetadata on new CRDs, inheritMetadata on older ones).
sel=0
METADATA_FIELD=$(mariadb_operator_select_restart_metadata_field "$RESOURCE" "$RESTART_METADATA_FIELD") || sel=$?
if [[ "$sel" -ne 0 ]]; then
  if [[ "$sel" -eq 2 ]]; then
    emit BLOCKED RESTART_METADATA_FIELD_INVALID "metadata field must be podMetadata, inheritMetadata, or auto" false
  else
    emit BLOCKED RESTART_METADATA_FIELD_UNSUPPORTED "MariaDB CRD exposes neither spec.podMetadata nor spec.inheritMetadata" false
  fi
  exit 0
fi

mariadb_operator_load_restart_state "$RESOURCE" "$MDB"
[[ "${#PODS[@]}" -gt 0 ]] \
  || { emit BLOCKED MARIADB_PODS_NOT_FOUND "MariaDB CR exists but no MariaDB pods were found" false "$PODS_JSON"; exit 0; }

# Guard 2: refuse to restart a cluster that already has a not-Ready pod.
for pod in "${PODS[@]}"; do
  mariadb_operator_pod_ready "$pod" "$CONTAINER" \
    || { emit BLOCKED POD_NOT_READY "MariaDB already has a not-Ready pod; refusing to trigger a restart" false "$PODS_JSON"; exit 0; }
done

# --- dry-run / confirm gates -------------------------------------------------
if bool "$DRY_RUN"; then
  emit READY RESTART_DRY_RUN "Dry-run made no changes; the operator decides restart order after the patch" false "$PODS_JSON"
  exit 0
fi
bool "$CONFIRM" \
  || { emit BLOCKED RESTART_CONFIRM_REQUIRED "Set confirm=true with dry_run=false to patch the restart annotation" false "$PODS_JSON"; exit 0; }

# --- 1) PATCH the restart annotation on the CR -------------------------------
PATCH_VALUE="$(date -u +%Y-%m-%dT%H:%M:%SZ)-${RANDOM}-$$"
mariadb_operator_patch_restart_annotation "$RESOURCE" "$MDB" "$METADATA_FIELD" "$ANNOTATION_KEY" "$PATCH_VALUE" >/dev/null 2>&1 \
  || { emit ERROR RESTART_PATCH_FAILED "kubectl patch mariadb failed" false "$PODS_JSON"; exit 0; }

# --- 2) CHECK that the operator recreated every pod and it is Ready ----------
if mariadb_operator_wait_for_restart "$CONTAINER" "$WAIT_TIMEOUT" "${PODS[@]}"; then
  PODS_JSON=$(mariadb_operator_build_pods_json "${PODS[@]}")
  emit RESTARTED RESTART_COMPLETED "MariaDB CR patched and mariadb-operator restarted all pods" true "$PODS_JSON"
else
  PODS_JSON=$(mariadb_operator_build_pods_json "${PODS[@]}")
  emit ERROR OPERATOR_RESTART_TIMEOUT "CR patched, but not all pods restarted and became Ready within ${WAIT_TIMEOUT}s" true "$PODS_JSON"
fi
