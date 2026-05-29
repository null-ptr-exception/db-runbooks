#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

create_cluster() {
  local name="$1"
  local config="$2"

  if kind get clusters 2>/dev/null | grep -qx "$name"; then
    echo "Cluster ${name} already exists, skipping"
    return 0
  fi

  echo "Creating cluster ${name}..."
  kind create cluster --name "$name" --config "$config" --wait 60s
}

create_cluster cluster-a "${SCRIPT_DIR}/kind-cluster-a.yaml"
create_cluster cluster-b "${SCRIPT_DIR}/kind-cluster-b.yaml"

echo "=== Clusters ready ==="
echo "cluster-a: $(docker inspect cluster-a-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
echo "cluster-b: $(docker inspect cluster-b-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
