#!/usr/bin/env bash
# =============================================================================
# lib/mariadb-restart-input.sh
# Input defaults, parsing, and validation for the MariaDB restart task.
# =============================================================================

[[ -n "${_MARIADB_RESTART_INPUT_LIB_LOADED:-}" ]] && return 0
_MARIADB_RESTART_INPUT_LIB_LOADED=1

mariadb_restart_usage() {
  cat >&2 <<'EOF'
Usage:
  restart.sh --namespace <namespace> [options]

Options:
  --context <context>            Kubernetes context. Optional for in-cluster AQSH.
  --resource <kind>              MariaDB CR kind. Default: mariadb.
  --mdb <name>                   MariaDB CR name. Default: mariadb.
  --container <name>             MariaDB container name. Default: mariadb.
  --allow-role-change <bool>     Tolerate a primary role move during restart. Default: false.
  --wait-timeout <sec>           Operator restart wait timeout in seconds. Default: 300.
  --dry-run <true|false>         Plan only, change nothing. Default: true.
  --confirm <true|false>         Required with --dry-run false. Default: false.
  --annotation-key <key>         Pod template annotation patched on the MariaDB CR.
  --metadata-field <field>       podMetadata, inheritMetadata, or auto. Default: auto.
  --json                         Print only JSON result to stdout.
  --result-file <path>           Write JSON result to this file.

Deprecated compatibility options:
  --target-pod <pod>             Unsupported; operator-driven restart is resource-scoped.
  --include-primary <true|false> Ignored; mariadb-operator decides rollout order.
EOF
}

# shellcheck disable=SC2034  # Defaults are task globals consumed by restart.sh and result helpers.
mariadb_restart_set_defaults() {
  CONTEXT="${K8S_CONTEXT:-${CONTEXT:-}}"
  NAMESPACE="${DB_NAMESPACE:-${K8S_NAMESPACE:-}}"
  RESOURCE="${MARIADB_RESOURCE:-mariadb}"
  MDB="${MARIADB_NAME:-${MARIADB_STS_NAME:-mariadb}}"
  CONTAINER="${MARIADB_CONTAINER:-mariadb}"
  TARGET_POD="${TARGET_POD:-}"
  INCLUDE_PRIMARY="${INCLUDE_PRIMARY:-false}"
  ALLOW_ROLE_CHANGE="${ALLOW_ROLE_CHANGE:-false}"
  WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
  DRY_RUN="${DRY_RUN:-true}"
  CONFIRM="${CONFIRM:-false}"
  ANNOTATION_KEY="${RESTART_ANNOTATION_KEY:-aqsh.null-ptr-exception.dev/restarted-at}"
  RESTART_METADATA_FIELD="${RESTART_METADATA_FIELD:-auto}"
  METADATA_FIELD=""
  RESULT_FILE="${AQSH_RESULT_FILE:-}"
  JSON_ONLY=0

  PRIMARY_BEFORE=""
  PRIMARY_AFTER=""
  UPDATE_STRATEGY=""
  REPLICAS=""
  PATCH_VALUE=""
  PATCH_OUT=""
}

# shellcheck disable=SC2034  # Parsed task globals are consumed by restart.sh and result helpers.
mariadb_restart_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context) task_require_value "$1" "${2:-}"; CONTEXT="$2"; shift 2 ;;
      --namespace) task_require_value "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
      --resource) task_require_value "$1" "${2:-}"; RESOURCE="$2"; shift 2 ;;
      --mdb | --name) task_require_value "$1" "${2:-}"; MDB="$2"; shift 2 ;;
      --container) task_require_value "$1" "${2:-}"; CONTAINER="$2"; shift 2 ;;
      --target-pod) task_require_value "$1" "${2:-}"; TARGET_POD="$2"; shift 2 ;;
      --include-primary) task_require_value "$1" "${2:-}"; INCLUDE_PRIMARY="$2"; shift 2 ;;
      --allow-role-change) task_require_value "$1" "${2:-}"; ALLOW_ROLE_CHANGE="$2"; shift 2 ;;
      --wait-timeout) task_require_value "$1" "${2:-}"; WAIT_TIMEOUT="$2"; shift 2 ;;
      --dry-run) task_require_value "$1" "${2:-}"; DRY_RUN="$2"; shift 2 ;;
      --confirm) task_require_value "$1" "${2:-}"; CONFIRM="$2"; shift 2 ;;
      --annotation-key) task_require_value "$1" "${2:-}"; ANNOTATION_KEY="$2"; shift 2 ;;
      --metadata-field) task_require_value "$1" "${2:-}"; RESTART_METADATA_FIELD="$2"; shift 2 ;;
      --json) JSON_ONLY=1; shift ;;
      --result-file) task_require_value "$1" "${2:-}"; RESULT_FILE="$2"; shift 2 ;;
      -h | --help) mariadb_restart_usage; exit 0 ;;
      *) echo "error: unknown option: $1" >&2; mariadb_restart_usage; exit 2 ;;
    esac
  done
}

mariadb_restart_validate_inputs() {
  if [[ -z "${NAMESPACE:-}" ]]; then
    mariadb_restart_usage
    exit 2
  fi

  if ! task_is_uint "${WAIT_TIMEOUT:-}"; then
    echo "error: WAIT_TIMEOUT must be an unsigned integer (got: ${WAIT_TIMEOUT:-})" >&2
    exit 2
  fi
}
