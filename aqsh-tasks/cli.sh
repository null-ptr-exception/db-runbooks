#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# cli.sh
# Standalone CLI entry point for the MongoDB sanity check.
#
# Runs the same 3-layer check as the aqsh task but directly from the shell,
# without going through the task API.  Useful for debugging inside the pod or
# from any host that has kubectl + mongosh access.
#
# Usage:
#   bash aqsh-tasks/cli.sh --namespace mongo-1 [OPTIONS]
#
# Run with --help for the full option list.
# =============================================================================

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"

source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"
source "${LIB_DIR}/mongodb_constant.sh"
source "${LIB_DIR}/custom.sh"

# =============================================================================
# Usage
# =============================================================================
_usage() {
  cat <<EOF
Usage: bash cli.sh [OPTIONS]

Options:
  --namespace <ns>       Kubernetes namespace (required)
  --sts <name>           StatefulSet name (default: mongodb)
  --pvc-path <path>      PVC mount path to df-check (default: /data/db)
  --pvc-warn <pct>       PVC warn threshold % (default: 80)
  --pvc-crit <pct>       PVC critical threshold % (default: 90)
  --lag-warn <sec>       Replication lag warn threshold s (default: 10)
  --lag-crit <sec>       Replication lag critical threshold s (default: 60)
  --oplog-warn-days <n>  Oplog warn if below N days (default: 3)
  --oplog-crit-days <n>  Oplog critical if below N days (default: 1)
  --conn-warn <pct>      Connection utilisation warn % (default: 80)
  --conn-crit <pct>      Connection utilisation critical % (default: 90)
  --wt-cache-warn <pct>  WiredTiger dirty cache warn % (default: 80)
  --wt-cache-crit <pct>  WiredTiger dirty cache critical % (default: 95)
  --lock-queue-warn <n>  Global lock queue warn depth (default: 3)
  --lock-queue-fail <n>  Global lock queue critical depth (default: 10)
  --standalone-ok        Skip RS-only checks on standalone nodes
  --help                 Show this help

Environment variables: K8S_NAMESPACE, K8S_KUBECONFIG, STS_NAME,
  PVC_MOUNT_PATH, PVC_WARN_PERCENT, PVC_CRIT_PERCENT, RESTART_WARN_COUNT,
  LAG_WARN_SECONDS, LAG_CRIT_SECONDS, OPLOG_WARN_DAYS, OPLOG_CRIT_DAYS,
  CONN_WARN_PERCENT, CONN_CRIT_PERCENT, WT_CACHE_WARN_PERCENT,
  WT_CACHE_CRIT_PERCENT, LOCK_QUEUE_WARN, LOCK_QUEUE_FAIL,
  MAX_LONG_OP_SECONDS, STANDALONE_OK
  Plus all MONGO_* variables from lib/mongodb.sh (URI, HOST, USER, PASS …)
EOF
  exit 0
}

# =============================================================================
# Main
# =============================================================================
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace)       K8S_NAMESPACE="${2:?}"; shift 2 ;;
      --sts)             STS_NAME="${2:?}"; shift 2 ;;
      --pvc-path)        PVC_MOUNT_PATH="${2:?}"; shift 2 ;;
      --pvc-warn)        PVC_WARN_PERCENT="${2:?}"; shift 2 ;;
      --pvc-crit)        PVC_CRIT_PERCENT="${2:?}"; shift 2 ;;
      --lag-warn)        LAG_WARN_SECONDS="${2:?}"; shift 2 ;;
      --lag-crit)        LAG_CRIT_SECONDS="${2:?}"; shift 2 ;;
      --oplog-warn-days) OPLOG_WARN_DAYS="${2:?}"; shift 2 ;;
      --oplog-crit-days) OPLOG_CRIT_DAYS="${2:?}"; shift 2 ;;
      --conn-warn)       CONN_WARN_PERCENT="${2:?}"; shift 2 ;;
      --conn-crit)       CONN_CRIT_PERCENT="${2:?}"; shift 2 ;;
      --wt-cache-warn)   WT_CACHE_WARN_PERCENT="${2:?}"; shift 2 ;;
      --wt-cache-crit)   WT_CACHE_CRIT_PERCENT="${2:?}"; shift 2 ;;
      --lock-queue-warn) LOCK_QUEUE_WARN="${2:?}"; shift 2 ;;
      --lock-queue-fail) LOCK_QUEUE_FAIL="${2:?}"; shift 2 ;;
      --standalone-ok)   STANDALONE_OK="1"; shift ;;
      --help|-h)         _usage ;;
      *) log_error "cli" "Unknown argument: $1"; exit 1 ;;
    esac
  done

  if [[ -z "${K8S_NAMESPACE:-}" ]]; then
    log_error "cli" "--namespace is required"
    _usage
  fi

  export K8S_NAMESPACE

  log_set_level "${LOG_LEVEL:-INFO}"

  printf '\033[1m══ MongoDB Sanity Check ══════════════════════════════════════════\033[0m\n'
  printf 'Namespace       : %s\n' "$K8S_NAMESPACE"
  printf 'STS             : %s\n' "$STS_NAME"
  printf 'PVC path        : %s  (warn: %s%%  crit: %s%%)\n' \
    "$PVC_MOUNT_PATH" "$PVC_WARN_PERCENT" "$PVC_CRIT_PERCENT"
  printf 'Lag thresholds  : warn ≥ %ss  crit ≥ %ss\n' "$LAG_WARN_SECONDS" "$LAG_CRIT_SECONDS"
  printf 'Oplog thresholds: warn < %sd  crit < %sd\n' "$OPLOG_WARN_DAYS" "$OPLOG_CRIT_DAYS"
  printf 'Connections     : warn ≥ %s%%  crit ≥ %s%%\n' "$CONN_WARN_PERCENT" "$CONN_CRIT_PERCENT"
  printf 'WT cache dirty  : warn ≥ %s%%  crit ≥ %s%%\n' "$WT_CACHE_WARN_PERCENT" "$WT_CACHE_CRIT_PERCENT"
  printf '═══════════════════════════════════════════════════════════════════\n'

  check_k8s_layer || true

  if ! check_mongo_connectivity; then
    _sc_summary
    (( SC_FAIL == 0 ))
    return
  fi

  check_mongo_internals || true

  _sc_summary
  (( SC_FAIL == 0 ))
}

main "$@"
