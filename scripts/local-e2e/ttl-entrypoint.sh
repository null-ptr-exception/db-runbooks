#!/bin/sh
# A container-side deadline survives the host runner being killed/disconnected.
set -eu
ttl="${LOCAL_E2E_MAX_SECONDS:-3600}"
case "$ttl" in ''|*[!0-9]*) echo 'Invalid LOCAL_E2E_MAX_SECONDS' >&2; exit 2 ;; esac
[ "$ttl" -gt 0 ] || exit 2
(
  sleep "$ttl"
  echo "Local verification deadline reached (${ttl}s); stopping container." >&2
  kill -TERM 1
  sleep 15
  kill -KILL 1
) &
exec /usr/local/bin/dockerd-entrypoint.sh "$@"
