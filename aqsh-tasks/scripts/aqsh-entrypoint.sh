#!/usr/bin/env bash
set -euo pipefail
umask 077
if [[ "${AQSH_DEBUG:-false}" == true ]]; then export GOCOVERDIR=/coverage; fi
runtime="$(mktemp -d "${TMPDIR:-/tmp}/aqsh-job-report.XXXXXX")"
AQSH_TASKS_CONFIG="$(python3 "${AQSH_LIB_DIR:-/tasks/lib}/job-report-config.py" \
  "$AQSH_TASKS_CONFIG" "${AQSH_TASKS_DIR:-/tasks}" "$runtime")"
export AQSH_TASKS_CONFIG
exec aqsh "$@"
