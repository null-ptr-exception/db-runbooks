#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

# Determine DB_MODE: env var takes precedence, then .env file, then default single
if [[ -z "${DB_MODE:-}" ]] && [[ -f "$ENV_FILE" ]]; then
  DB_MODE=$(grep '^DB_MODE=' "$ENV_FILE" | cut -d= -f2 || true)
fi
DB_MODE="${DB_MODE:-single}"

echo "=== Deleting Kind clusters (DB_MODE=${DB_MODE}) ==="

if [[ "$DB_MODE" == "dual" ]]; then
  DB_CLUSTERS=(cluster-dbs-a cluster-dbs-b)
else
  DB_CLUSTERS=(cluster-dbs)
fi

if [[ "$DB_MODE" != "dual" ]]; then
  EXTRA_CLUSTERS=(cluster-auth)
else
  EXTRA_CLUSTERS=()
fi

for cluster in "${EXTRA_CLUSTERS[@]}" "${DB_CLUSTERS[@]}" cluster-apps; do
  if kind get clusters 2>/dev/null | grep -qx "$cluster"; then
    echo "Deleting $cluster..."
    kind delete cluster --name "$cluster"
  else
    echo "$cluster does not exist, skipping"
  fi
done

if [ -f "$ENV_FILE" ]; then
  rm "$ENV_FILE"
  echo "Removed $ENV_FILE"
fi

echo "=== Teardown complete ==="
