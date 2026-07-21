#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/migration/migration-preflight.sh
# Pre-flight checks for a MariaDB instance to be used as a migration source.
#
# Checks:
#   1. Pod exec accessibility  — kubectl exec reaches the MariaDB container
#   2. MinIO TCP reachability  — run inside the pod so the pod's network is tested
#   3. MinIO HTTP health check — curl to /minio/health/live from inside the pod
#   4. MinIO credential check  — mc alias set + ls run from the aqsh-tasks context
# =============================================================================

MDB_INPUT="${MARIADB_NAME:-${MARIADB_STS_NAME:-}}"

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi

# shellcheck source=../../../lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=../../../lib/response.sh
source "${LIB_DIR}/response.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  migration-preflight.sh --namespace <namespace> [options]

Required:
  --namespace <namespace>       Kubernetes namespace of the source MariaDB.

Target options:
  --context <context>           Kubernetes context. Optional for in-cluster AQSH.
  --resource <kind>             MariaDB CR kind. Default: mariadb
  --mdb <name>                  MariaDB CR / StatefulSet name. Default: auto-detected.
  --container <name>            MariaDB container name. Default: mariadb

MinIO options (omit --minio-endpoint to skip all MinIO checks):
  --minio-endpoint <url>        MinIO server URL (e.g. http://minio.svc:9000).
  --minio-access-key <key>      MinIO access key for credential verification.
  --minio-secret-key <key>      MinIO secret key for credential verification.
  --minio-bucket <bucket>       Bucket name to verify read access against.

Output:
  --json                        Print only JSON result to stdout.
  --result-file <path>          Write JSON result to this file.
  --strict-exit                 Exit 1 on BLOCK, 2 on ERROR.

Environment equivalents:
  DB_NAMESPACE, K8S_CONTEXT, MARIADB_RESOURCE, MARIADB_NAME, MARIADB_CONTAINER,
  MINIO_ENDPOINT, MINIO_ACCESS_KEY, MINIO_SECRET_KEY, MINIO_BUCKET,
  AQSH_RESULT_FILE.
EOF
}

require_value() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo "error: $1 requires a value" >&2
    exit 2
  fi
}

CONTEXT="${K8S_CONTEXT:-${CONTEXT:-}}"
NAMESPACE="${DB_NAMESPACE:-${K8S_NAMESPACE:-}}"
RESOURCE="${MARIADB_RESOURCE:-mariadb}"
MDB="$MDB_INPUT"
CONTAINER="${MARIADB_CONTAINER:-mariadb}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-}"
MINIO_BUCKET="${MINIO_BUCKET:-}"
JSON_ONLY=0
STRICT_EXIT=0
RESULT_FILE="${AQSH_RESULT_FILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)          require_value "$1" "${2:-}"; CONTEXT="$2";          shift 2 ;;
    --namespace)        require_value "$1" "${2:-}"; NAMESPACE="$2";        shift 2 ;;
    --resource)         require_value "$1" "${2:-}"; RESOURCE="$2";         shift 2 ;;
    --mdb | --name)     require_value "$1" "${2:-}"; MDB="$2";              shift 2 ;;
    --container)        require_value "$1" "${2:-}"; CONTAINER="$2";        shift 2 ;;
    --minio-endpoint)   require_value "$1" "${2:-}"; MINIO_ENDPOINT="$2";   shift 2 ;;
    --minio-access-key) require_value "$1" "${2:-}"; MINIO_ACCESS_KEY="$2"; shift 2 ;;
    --minio-secret-key) require_value "$1" "${2:-}"; MINIO_SECRET_KEY="$2"; shift 2 ;;
    --minio-bucket)     require_value "$1" "${2:-}"; MINIO_BUCKET="$2";     shift 2 ;;
    --json)             JSON_ONLY=1; shift ;;
    --result-file)      require_value "$1" "${2:-}"; RESULT_FILE="$2"; shift 2 ;;
    --strict-exit)      STRICT_EXIT=1; shift ;;
    -h | --help)        usage; exit 0 ;;
    *)                  echo "error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$NAMESPACE" ]]; then
  usage
  exit 2
fi

# shellcheck source=../../../lib/k8s.sh
source "${LIB_DIR}/k8s.sh"
# shellcheck source=../../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"

mariadb_set_target "$CONTEXT" "$NAMESPACE" "$RESOURCE" "$MDB" "$CONTAINER"

PASS_COUNT=0
WARN_COUNT=0
BLOCK_COUNT=0
ERROR_COUNT=0
CHECKS_JSON=""
FIRST_WARN_REASON=""
FIRST_BLOCK_REASON=""
FIRST_ERROR_REASON=""

json_escape() { _escape_json_string "$1"; }

append_check_json() {
  local name="$1" status="$2" reason_code="$3" detail="$4" pod="${5:-}"
  local sep=""
  [[ -n "$CHECKS_JSON" ]] && sep=","
  CHECKS_JSON="${CHECKS_JSON}${sep}{\"name\":\"$(json_escape "$name")\",\"status\":\"${status}\",\"reason_code\":\"$(json_escape "$reason_code")\",\"detail\":\"$(json_escape "$detail")\""
  [[ -n "$pod" ]] && CHECKS_JSON="${CHECKS_JSON},\"pod\":\"$(json_escape "$pod")\""
  CHECKS_JSON="${CHECKS_JSON}}"
}

emit_check() {
  local name="$1" status="$2" reason_code="$3" detail="$4" pod="${5:-}"
  case "$status" in
    PASS)  PASS_COUNT=$((PASS_COUNT + 1)) ;;
    WARN)  WARN_COUNT=$((WARN_COUNT + 1));  [[ -z "$FIRST_WARN_REASON"  ]] && FIRST_WARN_REASON="$reason_code" ;;
    BLOCK) BLOCK_COUNT=$((BLOCK_COUNT + 1)); [[ -z "$FIRST_BLOCK_REASON" ]] && FIRST_BLOCK_REASON="$reason_code" ;;
    ERROR) ERROR_COUNT=$((ERROR_COUNT + 1)); [[ -z "$FIRST_ERROR_REASON" ]] && FIRST_ERROR_REASON="$reason_code" ;;
  esac
  append_check_json "$name" "$status" "$reason_code" "$detail" "$pod"
  if [[ "$JSON_ONLY" -ne 1 ]]; then
    printf '[%-5s] %-38s %s\n' "$status" "$reason_code" "$detail"
  fi
}

if [[ "$JSON_ONLY" -ne 1 ]]; then
  echo "=== MariaDB Migration Preflight ==="
  echo "context=${CONTEXT:-<current>} namespace=${NAMESPACE} resource=${RESOURCE} mdb=${MDB:-<auto>}"
  echo
fi

# ---------------------------------------------------------------------------
# Check 1: kubectl availability
# ---------------------------------------------------------------------------
if ! k8s_check >/dev/null; then
  emit_check kubectl ERROR KUBECTL_UNAVAILABLE "kubectl is not available or cannot reach the cluster"
fi

# ---------------------------------------------------------------------------
# Auto-detect MDB target
# ---------------------------------------------------------------------------
_on_ambiguous() { emit_check target_resolve ERROR MARIADB_AMBIGUOUS "Multiple MariaDB targets in namespace ($1); specify --mdb"; }
_on_none()      { emit_check target_resolve ERROR MARIADB_NOT_FOUND "No MariaDB CR or StatefulSet found in namespace"; }

if [[ -z "$MDB" ]]; then
  if mariadb_autodetect_target true _on_ambiguous _on_none; then
    MDB="$MARIADB_NAME"
    [[ "$JSON_ONLY" -ne 1 ]] && log_info "migration-preflight" "auto-detected mdb=${MDB}"
  fi
fi

# Resolve pod list
REPLICAS=""
REPLICAS=$(mariadb_cr_replicas 2>/dev/null || true)
if [[ -z "$REPLICAS" ]]; then
  REPLICAS=$(mariadb_sts_replicas 2>/dev/null || true)
fi
TARGET_POD=""
mapfile -t PODS < <(mariadb_list_pods "$REPLICAS")
[[ "${#PODS[@]}" -gt 0 ]] && TARGET_POD="${PODS[0]}"

# ---------------------------------------------------------------------------
# Check 2: Pod exec accessibility
# ---------------------------------------------------------------------------
[[ "$JSON_ONLY" -ne 1 ]] && echo "=== Pod Exec ==="

if [[ -z "$TARGET_POD" ]]; then
  emit_check pod_exec BLOCK NO_POD_FOUND "No MariaDB pod found in namespace ${NAMESPACE}"
elif mariadb_exec "$TARGET_POD" true 2>/dev/null; then
  emit_check pod_exec PASS POD_EXEC_OK "kubectl exec succeeded on pod=${TARGET_POD}" "$TARGET_POD"
else
  emit_check pod_exec BLOCK POD_EXEC_FAILED "kubectl exec failed on pod=${TARGET_POD}" "$TARGET_POD"
fi

[[ "$JSON_ONLY" -ne 1 ]] && echo

# ---------------------------------------------------------------------------
# MinIO checks (skipped when --minio-endpoint is not supplied)
# ---------------------------------------------------------------------------
if [[ -z "$MINIO_ENDPOINT" ]]; then
  emit_check minio WARN MINIO_ENDPOINT_NOT_PROVIDED "No --minio-endpoint supplied; skipping MinIO checks"
else
  [[ "$JSON_ONLY" -ne 1 ]] && echo "=== MinIO Connectivity ==="

  # Parse host and port from the endpoint URL
  _minio_no_proto="${MINIO_ENDPOINT#http://}"
  _minio_no_proto="${_minio_no_proto#https://}"
  _minio_host_port="${_minio_no_proto%%/*}"
  if [[ "$_minio_host_port" == *:* ]]; then
    _minio_host="${_minio_host_port%:*}"
    _minio_port="${_minio_host_port##*:}"
  else
    _minio_host="$_minio_host_port"
    _minio_port="9000"
  fi

  # Check 3: TCP reachability from inside the pod using bash /dev/tcp
  if [[ -z "$TARGET_POD" ]]; then
    emit_check minio_tcp BLOCK NO_POD_FOUND "Cannot test MinIO TCP connectivity without a reachable pod"
  elif mariadb_exec "$TARGET_POD" bash -c \
      "echo -n > /dev/tcp/${_minio_host}/${_minio_port}" 2>/dev/null; then
    emit_check minio_tcp PASS MINIO_TCP_OK \
      "TCP ${_minio_host}:${_minio_port} reachable from pod=${TARGET_POD}" "$TARGET_POD"
  else
    emit_check minio_tcp BLOCK MINIO_TCP_FAILED \
      "TCP ${_minio_host}:${_minio_port} unreachable from pod=${TARGET_POD}" "$TARGET_POD"
  fi

  # Check 4: HTTP health check from inside the pod using curl
  if [[ -z "$TARGET_POD" ]]; then
    emit_check minio_http BLOCK NO_POD_FOUND "Cannot test MinIO HTTP health without a reachable pod"
  else
    _minio_health_url="${MINIO_ENDPOINT%/}/minio/health/live"
    if mariadb_exec "$TARGET_POD" bash -c \
        "curl -sf --connect-timeout 5 --max-time 10 '${_minio_health_url}'" 2>/dev/null; then
      emit_check minio_http PASS MINIO_HTTP_OK \
        "MinIO health OK from pod=${TARGET_POD}: ${_minio_health_url}" "$TARGET_POD"
    else
      # curl may not exist in the MariaDB image; treat as WARN so TCP result drives BLOCK
      emit_check minio_http WARN MINIO_HTTP_UNAVAILABLE \
        "MinIO HTTP health check failed or curl not available in pod=${TARGET_POD}" "$TARGET_POD"
    fi
  fi

  # Check 5: Credential verification from aqsh-tasks context via mc
  if [[ -z "$MINIO_ACCESS_KEY" || -z "$MINIO_SECRET_KEY" ]]; then
    emit_check minio_auth WARN MINIO_CREDS_NOT_PROVIDED \
      "No MinIO credentials supplied; skipping credential check"
  else
    _mc_alias="preflight-$$"
    if mc alias set "$_mc_alias" "$MINIO_ENDPOINT" \
        "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" --api S3v4 >/dev/null 2>&1; then
      emit_check minio_auth PASS MINIO_AUTH_OK \
        "MinIO credentials verified against ${MINIO_ENDPOINT}"

      if [[ -n "$MINIO_BUCKET" ]]; then
        if mc ls "${_mc_alias}/${MINIO_BUCKET}" >/dev/null 2>&1; then
          emit_check minio_bucket PASS MINIO_BUCKET_ACCESSIBLE \
            "Bucket '${MINIO_BUCKET}' accessible on ${MINIO_ENDPOINT}"
        else
          emit_check minio_bucket BLOCK MINIO_BUCKET_NOT_ACCESSIBLE \
            "Bucket '${MINIO_BUCKET}' not accessible on ${MINIO_ENDPOINT}"
        fi
      fi

      mc alias rm "$_mc_alias" >/dev/null 2>&1 || true
    else
      mc alias rm "$_mc_alias" >/dev/null 2>&1 || true
      emit_check minio_auth BLOCK MINIO_AUTH_FAILED \
        "MinIO credential verification failed against ${MINIO_ENDPOINT}"
    fi
  fi

  [[ "$JSON_ONLY" -ne 1 ]] && echo
fi

# ---------------------------------------------------------------------------
# Determine overall result
# ---------------------------------------------------------------------------
TOTAL=$((PASS_COUNT + WARN_COUNT + BLOCK_COUNT + ERROR_COUNT))
if [[ "$ERROR_COUNT" -gt 0 ]]; then
  RESULT_STATUS="ERROR"
  RESULT_REASON="${FIRST_ERROR_REASON:-PREFLIGHT_ERROR}"
elif [[ "$BLOCK_COUNT" -gt 0 ]]; then
  RESULT_STATUS="BLOCK"
  RESULT_REASON="${FIRST_BLOCK_REASON:-PREFLIGHT_BLOCK}"
elif [[ "$WARN_COUNT" -gt 0 ]]; then
  RESULT_STATUS="WARN"
  RESULT_REASON="${FIRST_WARN_REASON:-PREFLIGHT_WARN}"
else
  RESULT_STATUS="PASS"
  RESULT_REASON="PREFLIGHT_PASS"
fi

case "$RESULT_STATUS" in
  PASS)  SUMMARY="Migration preflight passed: pod exec and MinIO connectivity OK" ;;
  WARN)  SUMMARY="Migration preflight passed with non-blocking warnings" ;;
  BLOCK) SUMMARY="Migration preflight found blocking issues; resolve before migrating" ;;
  *)     SUMMARY="Migration preflight could not complete cleanly" ;;
esac

RESULT_JSON=$(printf \
  '{"status":"%s","reason_code":"%s","summary":"%s","target":{"context":"%s","namespace":"%s","resource":"%s","mdb":"%s","pod":"%s"},"minio":{"endpoint":"%s","bucket":"%s"},"counts":{"pass":%d,"warn":%d,"block":%d,"error":%d,"total":%d},"checks":[%s]}' \
  "$RESULT_STATUS" \
  "$(json_escape "$RESULT_REASON")" \
  "$(json_escape "$SUMMARY")" \
  "$(json_escape "${CONTEXT:-}")" \
  "$(json_escape "$NAMESPACE")" \
  "$(json_escape "$RESOURCE")" \
  "$(json_escape "$MDB")" \
  "$(json_escape "$TARGET_POD")" \
  "$(json_escape "$MINIO_ENDPOINT")" \
  "$(json_escape "$MINIO_BUCKET")" \
  "$PASS_COUNT" \
  "$WARN_COUNT" \
  "$BLOCK_COUNT" \
  "$ERROR_COUNT" \
  "$TOTAL" \
  "$CHECKS_JSON")

if [[ -n "$RESULT_FILE" ]]; then
  printf '%s\n' "$RESULT_JSON" > "$RESULT_FILE"
fi

if [[ "$JSON_ONLY" -eq 1 || -z "$RESULT_FILE" ]]; then
  printf '%s\n' "$RESULT_JSON"
else
  echo "=== PREFLIGHT: ${RESULT_STATUS} ==="
  echo "$SUMMARY"
fi

if [[ "$STRICT_EXIT" -eq 1 ]]; then
  case "$RESULT_STATUS" in
    PASS | WARN) exit 0 ;;
    BLOCK) exit 1 ;;
    ERROR) exit 2 ;;
  esac
fi

exit 0
