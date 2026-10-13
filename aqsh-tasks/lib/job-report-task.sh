#!/usr/bin/env bash
# Report a completed task using shared read-only target/credential resolution.
set -euo pipefail
LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=aqsh-tasks/lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=aqsh-tasks/lib/response.sh
source "${LIB_DIR}/response.sh"
# shellcheck source=aqsh-tasks/lib/k8s.sh
source "${LIB_DIR}/k8s.sh"
MDB_INPUT="${MARIADB_NAME:-${MARIADB_STS_NAME:-}}"
# shellcheck source=aqsh-tasks/lib/mariadb.sh
source "${LIB_DIR}/mariadb.sh"
# shellcheck source=aqsh-tasks/lib/job-report.sh
source "${LIB_DIR}/job-report.sh"

[[ -n "${JOB_REPORT_DATABASE:-}${JOB_REPORT_TABLE:-}" ]] || exit 0
if [[ ! "${JOB_REPORT_DATABASE:-}" =~ ^[A-Za-z0-9_]+$ || ! "${JOB_REPORT_TABLE:-}" =~ ^[A-Za-z0-9_]+$ ]]; then
  _job_report_warn; exit 0
fi
[[ -n "${DB_NAMESPACE:-}" ]] || { _job_report_warn; exit 0; }
mariadb_set_target "${K8S_CONTEXT:-}" "$DB_NAMESPACE" \
  "${MARIADB_RESOURCE:-mariadb}" "$MDB_INPUT" "${MARIADB_CONTAINER:-mariadb}"
_report_unresolved() { _job_report_warn; exit 0; }
if [[ -z "$MDB_INPUT" ]]; then
  mariadb_autodetect_target true _report_unresolved _report_unresolved || exit 0
fi
members="$(mariadb_list_member_pods)" || { _job_report_warn; exit 0; }
mapfile -t pods < <(printf '%s\n' "$members" | sed '/^$/d')
primary="$(mariadb_jsonpath "$MARIADB_RESOURCE" "$MARIADB_NAME" '{.status.currentPrimary}' || true)"
if [[ -z "$primary" && ${#pods[@]} -eq 1 ]]; then primary="${pods[0]}"; fi
[[ -n "$primary" ]] || { _job_report_warn; exit 0; }
printf '%s\n' "${pods[@]}" | grep -qxF "$primary" || { _job_report_warn; exit 0; }
password="$(mariadb_read_root_password "$primary" "${pods[@]}")" || { _job_report_warn; exit 0; }
job_report_enable "${JOB_REPORT_NAME:-}"
trap 'job_report_exit "$?"' EXIT
job_report_start "$primary" "$password"
job_report_finish "$1" "$2"
