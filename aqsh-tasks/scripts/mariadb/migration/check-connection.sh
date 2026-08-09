#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mariadb/migration/check-connection.sh
# Check if a MariaDB pod can connect to a given host IP using root credentials.
#
# Execs into the primary pod, then resolves the password to authenticate
# with: by default the pod's own env (MARIADB_ROOT_PASSWORD) — which only
# makes sense when the target IP shares that same password (e.g. testing
# reachability within one platform). For a cross-cluster migration, source
# and target legitimately have DIFFERENT root passwords, so --repl-password-secret
# (mirroring migration/setup-replication's flag of the same name) lets the
# caller point at the Secret migration/read-db-env-from-vault relayed the
# source's password into, and authenticate to the source with ITS password
# instead of the target pod's own.
#
# When the connection succeeds, a further check compares @@server_id on both
# sides: replication identifies servers by server_id, and a collision (or
# even just enough proximity to collide once replicas are added) between
# source and target breaks replication in a way that's easy to miss until
# it's already running. See the server_id check below for the exact rule.
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
  check-connection.sh --namespace <namespace> --ip <target-ip> [options]

Required:
  --namespace <namespace>   Kubernetes namespace of the MariaDB instance.
  --ip <target-ip>          Host IP to attempt connection to from inside the pod.

Target options:
  --context <context>       Kubernetes context. Optional for in-cluster AQSH.
  --resource <kind>         MariaDB CR kind. Default: mariadb.
  --mdb <name>              MariaDB CR / StatefulSet name. Default: auto-detected.
  --container <name>        MariaDB container name. Default: mariadb.
  --port <port>             MariaDB port on the target host. Default: 3306.

Password options:
  --repl-password-secret <name>   Secret holding the password to authenticate
                                   the target IP with. Defaults to using the
                                   pod's own MARIADB_ROOT_PASSWORD — only
                                   correct when the target shares that
                                   password. For a cross-cluster check with a
                                   differently-credentialed source, point this
                                   at the Secret migration/read-db-env-from-vault
                                   relayed the source's password into.
  --repl-password-key <key>       Key in the secret. Default: password.

Output:
  --json                    Print only JSON result to stdout.
  --result-file <path>      Write JSON result to this file.
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
TARGET_IP="${TARGET_IP:-}"
TARGET_PORT="${TARGET_PORT:-3306}"
REPL_PASSWORD_SECRET="${REPL_PASSWORD_SECRET:-}"
REPL_PASSWORD_KEY="${REPL_PASSWORD_KEY:-password}"
JSON_ONLY=0
RESULT_FILE="${AQSH_RESULT_FILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)               require_value "$1" "${2:-}"; CONTEXT="$2";              shift 2 ;;
    --namespace)             require_value "$1" "${2:-}"; NAMESPACE="$2";            shift 2 ;;
    --resource)              require_value "$1" "${2:-}"; RESOURCE="$2";             shift 2 ;;
    --mdb | --name)          require_value "$1" "${2:-}"; MDB="$2";                  shift 2 ;;
    --container)             require_value "$1" "${2:-}"; CONTAINER="$2";            shift 2 ;;
    --ip)                    require_value "$1" "${2:-}"; TARGET_IP="$2";            shift 2 ;;
    --port)                  require_value "$1" "${2:-}"; TARGET_PORT="$2";          shift 2 ;;
    --repl-password-secret)  require_value "$1" "${2:-}"; REPL_PASSWORD_SECRET="$2"; shift 2 ;;
    --repl-password-key)     require_value "$1" "${2:-}"; REPL_PASSWORD_KEY="$2";    shift 2 ;;
    --json)                  JSON_ONLY=1; shift ;;
    --result-file)           require_value "$1" "${2:-}"; RESULT_FILE="$2";          shift 2 ;;
    -h | --help)              usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$NAMESPACE" ]]; then
  echo "error: --namespace is required" >&2
  usage
  exit 2
fi

if [[ -z "$TARGET_IP" ]]; then
  echo "error: --ip is required" >&2
  usage
  exit 2
fi

if ! [[ "$TARGET_PORT" =~ ^[0-9]{1,5}$ ]] || (( TARGET_PORT < 1 || TARGET_PORT > 65535 )); then
  echo "error: --port must be an integer from 1 through 65535" >&2
  exit 2
fi

# shellcheck source=../../../lib/k8s.sh
source "${LIB_DIR}/k8s.sh"
# shellcheck source=../../../lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"

mariadb_set_target "$CONTEXT" "$NAMESPACE" "$RESOURCE" "$MDB" "$CONTAINER"

[[ "$JSON_ONLY" -ne 1 ]] && log_info "mariadb-check-connection" \
  "namespace=${NAMESPACE} mdb=${MDB:-<auto>} target=${TARGET_IP}:${TARGET_PORT}"

PASS_COUNT=0
BLOCK_COUNT=0
ERROR_COUNT=0
CHECKS_JSON=""
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
    BLOCK) BLOCK_COUNT=$((BLOCK_COUNT + 1)); [[ -z "$FIRST_BLOCK_REASON" ]] && FIRST_BLOCK_REASON="$reason_code" ;;
    ERROR) ERROR_COUNT=$((ERROR_COUNT + 1)); [[ -z "$FIRST_ERROR_REASON" ]] && FIRST_ERROR_REASON="$reason_code" ;;
  esac
  append_check_json "$name" "$status" "$reason_code" "$detail" "$pod"
  if [[ "$JSON_ONLY" -ne 1 ]]; then
    printf '[%-5s] %-38s %s\n' "$status" "$reason_code" "$detail"
  fi
}

if [[ "$JSON_ONLY" -ne 1 ]]; then
  echo "=== MariaDB Connection Check ==="
  echo "context=${CONTEXT:-<current>} namespace=${NAMESPACE} target=${TARGET_IP}:${TARGET_PORT}"
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
    [[ "$JSON_ONLY" -ne 1 ]] && log_info "check-connection" "auto-detected mdb=${MDB}"
  fi
fi

# Resolve primary pod
REPLICAS=""
REPLICAS=$(mariadb_cr_replicas 2>/dev/null || true)
if [[ -z "$REPLICAS" ]]; then
  REPLICAS=$(mariadb_sts_replicas 2>/dev/null || true)
fi
TARGET_POD=""
mapfile -t PODS < <(mariadb_list_pods "$REPLICAS")
[[ "${#PODS[@]}" -gt 0 ]] && TARGET_POD="${PODS[0]}"

# ---------------------------------------------------------------------------
# Check 2: pod exec accessibility
# ---------------------------------------------------------------------------
if [[ "$JSON_ONLY" -ne 1 ]]; then echo "=== Pod Exec ==="; fi

if [[ -z "$TARGET_POD" ]]; then
  emit_check pod_exec BLOCK NO_POD_FOUND "No MariaDB pod found in namespace ${NAMESPACE}"
elif mariadb_exec "$TARGET_POD" true 2>/dev/null; then
  emit_check pod_exec PASS POD_EXEC_OK "kubectl exec succeeded on pod=${TARGET_POD}" "$TARGET_POD"
else
  emit_check pod_exec BLOCK POD_EXEC_FAILED "kubectl exec failed on pod=${TARGET_POD}" "$TARGET_POD"
fi

if [[ "$JSON_ONLY" -ne 1 ]]; then echo; fi

# A source and its replicas are assumed to number at most 8 in this
# sandbox's topology; server_id collisions are checked mod 10 (rather than
# exactly), leaving headroom so a target that's "close" to colliding is
# still flagged, not just an exact match.
SERVER_ID_COLLISION_MODULUS=10

# ---------------------------------------------------------------------------
# Checks 3 & 4: root password and connection (skipped if pod exec blocked)
# ---------------------------------------------------------------------------
if [[ "$BLOCK_COUNT" -eq 0 && "$ERROR_COUNT" -eq 0 ]]; then
  if [[ "$JSON_ONLY" -ne 1 ]]; then echo "=== Root Password ==="; fi

  ROOT_PASSWORD=""
  if [[ -n "$REPL_PASSWORD_SECRET" ]]; then
    ROOT_PASSWORD="$(k8s_secret_value "$REPL_PASSWORD_SECRET" "$REPL_PASSWORD_KEY")" || true
    if [[ -z "$ROOT_PASSWORD" ]]; then
      emit_check root_password ERROR ROOT_PASSWORD_NOT_FOUND \
        "Cannot read password from secret ${REPL_PASSWORD_SECRET} (key: ${REPL_PASSWORD_KEY})" "${TARGET_POD:-}"
    else
      emit_check root_password PASS ROOT_PASSWORD_OK \
        "Password retrieved from secret ${REPL_PASSWORD_SECRET} (key: ${REPL_PASSWORD_KEY})" "${TARGET_POD:-}"
    fi
  else
    if [[ -n "$TARGET_POD" ]]; then
      ROOT_PASSWORD=$(mariadb_exec "$TARGET_POD" printenv MARIADB_ROOT_PASSWORD 2>/dev/null) || true
    fi

    if [[ -z "$ROOT_PASSWORD" ]]; then
      emit_check root_password ERROR ROOT_PASSWORD_NOT_FOUND \
        "MARIADB_ROOT_PASSWORD not set in pod=${TARGET_POD:-<none>}" "${TARGET_POD:-}"
    else
      emit_check root_password PASS ROOT_PASSWORD_OK \
        "MARIADB_ROOT_PASSWORD retrieved from pod=${TARGET_POD}" "$TARGET_POD"
    fi
  fi

  if [[ "$JSON_ONLY" -ne 1 ]]; then echo; fi

  if [[ "$JSON_ONLY" -ne 1 ]]; then echo "=== Connection to ${TARGET_IP}:${TARGET_PORT} ==="; fi

  if [[ -n "$ROOT_PASSWORD" ]]; then
    if mariadb_exec "$TARGET_POD" mariadb -u root -p"$ROOT_PASSWORD" \
        -h "$TARGET_IP" -P "$TARGET_PORT" \
        --connect-timeout=5 -e "SELECT 1" 2>/dev/null; then
      emit_check connection PASS CONNECTION_OK \
        "Connected to ${TARGET_IP}:${TARGET_PORT} as root from pod=${TARGET_POD}" "$TARGET_POD"

      if [[ "$JSON_ONLY" -ne 1 ]]; then echo; echo "=== server_id collision check ==="; fi

      # This pod's own server_id (local connection, no -h/-P) vs. the
      # remote's, over the same connection that just passed above.
      LOCAL_SERVER_ID=""
      LOCAL_SERVER_ID=$(mariadb_sql "$TARGET_POD" "$ROOT_PASSWORD" "SELECT @@server_id") || true
      REMOTE_SERVER_ID=""
      REMOTE_SERVER_ID=$(mariadb_exec "$TARGET_POD" mariadb -u root -p"$ROOT_PASSWORD" \
        -h "$TARGET_IP" -P "$TARGET_PORT" --connect-timeout=5 -N -B \
        -e "SELECT @@server_id" 2>/dev/null) || true

      if [[ ! "$LOCAL_SERVER_ID" =~ ^[0-9]+$ || ! "$REMOTE_SERVER_ID" =~ ^[0-9]+$ ]]; then
        emit_check server_id ERROR SERVER_ID_UNAVAILABLE \
          "Could not read @@server_id from this pod (got '${LOCAL_SERVER_ID}') and/or ${TARGET_IP}:${TARGET_PORT} (got '${REMOTE_SERVER_ID}')" "$TARGET_POD"
      elif (( LOCAL_SERVER_ID % SERVER_ID_COLLISION_MODULUS == REMOTE_SERVER_ID % SERVER_ID_COLLISION_MODULUS )); then
        emit_check server_id BLOCK SERVER_ID_COLLISION_RISK \
          "this pod's server_id=${LOCAL_SERVER_ID} and ${TARGET_IP}:${TARGET_PORT}'s server_id=${REMOTE_SERVER_ID} collide mod ${SERVER_ID_COLLISION_MODULUS} — replicating from it risks a server_id clash with it or one of its own replicas" "$TARGET_POD"
      else
        emit_check server_id PASS SERVER_ID_OK \
          "this pod's server_id=${LOCAL_SERVER_ID} and ${TARGET_IP}:${TARGET_PORT}'s server_id=${REMOTE_SERVER_ID} do not collide mod ${SERVER_ID_COLLISION_MODULUS}" "$TARGET_POD"
      fi
    else
      emit_check connection BLOCK CONNECTION_FAILED \
        "Cannot connect to ${TARGET_IP}:${TARGET_PORT} as root from pod=${TARGET_POD}" "$TARGET_POD"
    fi
  else
    emit_check connection ERROR CONNECTION_SKIPPED \
      "Skipping connection check: root password not available"
  fi

  if [[ "$JSON_ONLY" -ne 1 ]]; then echo; fi
fi

# ---------------------------------------------------------------------------
# Determine overall result
# ---------------------------------------------------------------------------
TOTAL=$((PASS_COUNT + BLOCK_COUNT + ERROR_COUNT))
if [[ "$ERROR_COUNT" -gt 0 ]]; then
  RESULT_STATUS="ERROR"
  RESULT_REASON="${FIRST_ERROR_REASON:-CHECK_ERROR}"
elif [[ "$BLOCK_COUNT" -gt 0 ]]; then
  RESULT_STATUS="BLOCK"
  RESULT_REASON="${FIRST_BLOCK_REASON:-CONNECTION_FAILED}"
else
  RESULT_STATUS="PASS"
  RESULT_REASON="CONNECTION_OK"
fi

case "$RESULT_STATUS" in
  PASS)  SUMMARY="Connection to ${TARGET_IP}:${TARGET_PORT} succeeded from pod=${TARGET_POD:-<pod>}" ;;
  BLOCK) SUMMARY="Connection to ${TARGET_IP}:${TARGET_PORT} failed from pod=${TARGET_POD:-<pod>}" ;;
  *)     SUMMARY="Connection check could not complete" ;;
esac

RESULT_JSON=$(printf \
  '{"status":"%s","reason_code":"%s","summary":"%s","target":{"context":"%s","namespace":"%s","resource":"%s","mdb":"%s","pod":"%s"},"connection":{"host":"%s","port":%s},"counts":{"pass":%d,"block":%d,"error":%d,"total":%d},"checks":[%s]}' \
  "$RESULT_STATUS" \
  "$(json_escape "$RESULT_REASON")" \
  "$(json_escape "$SUMMARY")" \
  "$(json_escape "${CONTEXT:-}")" \
  "$(json_escape "$NAMESPACE")" \
  "$(json_escape "$RESOURCE")" \
  "$(json_escape "$MDB")" \
  "$(json_escape "$TARGET_POD")" \
  "$(json_escape "$TARGET_IP")" \
  "$TARGET_PORT" \
  "$PASS_COUNT" \
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
  echo "=== CONNECTION CHECK: ${RESULT_STATUS} ==="
  echo "$SUMMARY"
fi

exit 0
