#!/usr/bin/env bash
# =============================================================================
# lib/mongodb_constant.sh
# Default threshold values for MongoDB sanity-check operations.
#
# All variables use ${VAR:-default} so callers can override via environment
# or tasks.yaml inputs before sourcing this file.
#
# Industry-standard reference thresholds used:
#   Replication lag  WARN ≥ 10 s  (MongoDB Atlas default)  |  CRIT ≥ 60 s
#   Oplog window     WARN < 3 d   (MongoDB recommendation)  |  CRIT < 1 d
#   PVC usage        WARN ≥ 80%                              |  CRIT ≥ 90%
#   Connections      WARN ≥ 80% capacity                    |  CRIT ≥ 90%
#   WT cache dirty   WARN ≥ 80%                              |  CRIT ≥ 95%
# =============================================================================

[[ -n "${_MONGODB_CONSTANT_LOADED:-}" ]] && return 0
_MONGODB_CONSTANT_LOADED=1

# StatefulSet name (overridden per-task via MONGO_STS_NAME)
STS_NAME="${STS_NAME:-mongodb}"

# PVC disk usage
PVC_MOUNT_PATH="${PVC_MOUNT_PATH:-/data/db}"
PVC_WARN_PERCENT="${PVC_WARN_PERCENT:-80}"
PVC_CRIT_PERCENT="${PVC_CRIT_PERCENT:-90}"

# Pod restart count
RESTART_WARN_COUNT="${RESTART_WARN_COUNT:-5}"

# Replication lag — MongoDB Atlas default alert thresholds
LAG_WARN_SECONDS="${LAG_WARN_SECONDS:-10}"
LAG_CRIT_SECONDS="${LAG_CRIT_SECONDS:-60}"

# Oplog retention — MongoDB recommended minimum = 72 h (3 days)
OPLOG_WARN_DAYS="${OPLOG_WARN_DAYS:-3}"
OPLOG_CRIT_DAYS="${OPLOG_CRIT_DAYS:-1}"
# Backward-compat alias
[[ -n "${OPLOG_MIN_DAYS:-}" ]] && OPLOG_CRIT_DAYS="$OPLOG_MIN_DAYS"

# Connection utilisation
CONN_WARN_PERCENT="${CONN_WARN_PERCENT:-80}"
CONN_CRIT_PERCENT="${CONN_CRIT_PERCENT:-90}"

# WiredTiger cache dirty-page utilisation
WT_CACHE_WARN_PERCENT="${WT_CACHE_WARN_PERCENT:-80}"
WT_CACHE_CRIT_PERCENT="${WT_CACHE_CRIT_PERCENT:-95}"

# Global lock queue depth
LOCK_QUEUE_WARN="${LOCK_QUEUE_WARN:-3}"
LOCK_QUEUE_FAIL="${LOCK_QUEUE_FAIL:-10}"

# Long-running operations
MAX_LONG_OP_SECONDS="${MAX_LONG_OP_SECONDS:-60}"

# Set to 1 to suppress RS-only check warnings on standalone nodes
STANDALONE_OK="${STANDALONE_OK:-0}"
