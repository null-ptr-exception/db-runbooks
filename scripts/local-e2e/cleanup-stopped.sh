#!/usr/bin/env bash
# Only stopped, explicitly owned verification containers. Never force removal.
set -euo pipefail
stopped="$(docker ps -aq --filter label=db-runbooks.local-e2e=true --filter status=exited --filter status=dead)"
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  docker rm -v "$id"
done <<< "$stopped"
