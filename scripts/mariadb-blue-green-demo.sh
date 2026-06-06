#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"
TEMPLATE_DIR="${ROOT_DIR}/k8s/cluster-dbs/mariadb/blue-green-demo"

# shellcheck source=scripts/lib/mariadb-blue-green-demo.sh
source "${SCRIPT_DIR}/lib/mariadb-blue-green-demo.sh"

usage() {
  cat >&2 <<EOF
Usage:
  $0 <apply|validate|cutover|status|cleanup> [command...]

Environment:
  BG_NAMESPACE              default: mariadb-bg
  BLUE_CONTEXT              default: kind-cluster-dbs-a
  GREEN_CONTEXT             default: kind-cluster-dbs-b
  MINIO_BUCKET              default: multi-cluster
  MARIADB_ROOT_PASSWORD     default: mariadb-bg-root-pass

Expected setup:
  DB_MODE=dual ENABLE_MINIO=true ./scripts/setup-clusters.sh
  DB_MODE=dual ENABLE_MINIO=true ./scripts/deploy-infra.sh
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

for command in "$@"; do
  case "$command" in
    apply) apply_demo ;;
    validate) validate_demo ;;
    cutover) cutover_demo ;;
    status) status_demo ;;
    cleanup) cleanup_demo ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown command: ${command}" >&2; usage; exit 2 ;;
  esac
done
