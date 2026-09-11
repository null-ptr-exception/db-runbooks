#!/usr/bin/env bash
set -euo pipefail
cd /workspace
export PATH="/root/.local/bin:$PATH"
# All installation is inside the disposable container.
for ((attempt=0; attempt<30; attempt++)); do
  docker info >/dev/null 2>&1 && break
  sleep 1
done
docker info >/dev/null
eval "$(mise env --shell bash)"
# Nested local networking can reject Go HTTP/2 connections to chart storage.
# Keep this transport workaround scoped to this disposable test environment.
export GODEBUG="${GODEBUG:+${GODEBUG},}http2client=0"
scripts/preflight.sh
# Retry only transient transport failures during Helmfile setup. Do not retry
# Bats or AQSH operations: those results must remain visible as test failures.
export LOCAL_E2E_HELMFILE_REAL
LOCAL_E2E_HELMFILE_REAL="$(command -v helmfile)"
retry_bin="$(mktemp -d)"
cat > "$retry_bin/helmfile" <<'RETRY'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == apply ]] || exec "$LOCAL_E2E_HELMFILE_REAL" "$@"
error_log="$(mktemp)"
trap 'rm -f "$error_log"' EXIT
for attempt in 1 2 3; do
  # Fresh nested clusters can need more than Helm's five-minute default for
  # CNI cold startup. This changes the setup budget, not readiness criteria.
  if "$LOCAL_E2E_HELMFILE_REAL" "$@" --timeout 900 2>"$error_log"; then
    cat "$error_log" >&2
    exit 0
  else
    rc=$?
    cat "$error_log" >&2
  fi
  if [[ "$attempt" == 3 ]] || ! grep -Eq 'unexpected EOF|: EOF|TLS handshake timeout|connection reset by peer|http2: client conn could not be established' "$error_log"; then
    exit "$rc"
  fi
  echo "Retrying Helmfile setup transport failure ($attempt/3)." >&2
  sleep 3
done
RETRY
chmod +x "$retry_bin/helmfile"
export PATH="$retry_bin:$PATH"
# Explicitly single-threaded: the runbook is one stateful scenario and the
# suite teardown must finish before another scenario gets its own daemon.
bats --jobs 1 "$1" | tee /workspace/e2e.tap
