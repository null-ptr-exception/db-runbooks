#!/usr/bin/env bash
# MariaDB test suite setup
#
# Deploys the MariaDB control plane + test instances on the 2-cluster infra.
#
# cluster-a (server):
#   db-ops:     kube-federated-auth, kube-auth-proxy + aqsh-mariadb, Redis
#   mariadb-1:  MariaDB instance (operator-managed)
# cluster-b (server + client):
#   db-ops:     test-client pod, kube-auth-proxy + aqsh-mariadb, Redis
#   mariadb-1:  MariaDB instance (operator-managed)
#   minio:      MinIO for backup tests

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  source "${ROOT_DIR}/infra/deploy.sh"

  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"
  local NS="db-ops"

  # Layer 0: shared infra (idempotent)
  setup_infra

  # Install mariadb-operator CRDs and operator on both clusters
  helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator 2>/dev/null || true
  helm repo update mariadb-operator

  for ctx in "$CTX_A" "$CTX_B"; do
    echo "Installing mariadb-operator CRDs on ${ctx}..."
    helm upgrade --install mariadb-operator-crds mariadb-operator/mariadb-operator-crds \
      --kube-context "$ctx" \
      --wait

    echo "Installing mariadb-operator on ${ctx}..."
    helm upgrade --install mariadb-operator mariadb-operator/mariadb-operator \
      --kube-context "$ctx" \
      --namespace db-ops \
      --create-namespace \
      --wait
  done

  # Build aqsh image and push to local registry
  docker build -t localhost:5005/db-runbooks:latest "${ROOT_DIR}"
  docker push localhost:5005/db-runbooks:latest

  local HELMFILE="${ROOT_DIR}/tests/mariadb/helmfile.yaml"

  # First apply: deploy everything with default (empty) runtime values.
  helmfile apply -f "$HELMFILE"

  [[ -n "${CLUSTER_A_IP:-}" ]] || { echo "CLUSTER_A_IP not set by setup_infra" >&2; return 1; }
  [[ -n "${CLUSTER_B_IP:-}" ]] || { echo "CLUSTER_B_IP not set by setup_infra" >&2; return 1; }

  # Extract runtime credentials from live clusters
  local ISSUER_A ISSUER_B CA_A CA_B TOKEN_A TOKEN_B

  ISSUER_A=$(kubectl --context "$CTX_A" get --raw /.well-known/openid-configuration \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])")
  ISSUER_B=$(kubectl --context "$CTX_B" get --raw /.well-known/openid-configuration \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])")

  CA_A=$(kubectl --context "$CTX_A" config view --raw \
    -o jsonpath="{.clusters[?(@.name==\"kind-cluster-a\")].cluster.certificate-authority-data}" | base64 -d)
  CA_B=$(kubectl --context "$CTX_B" config view --raw \
    -o jsonpath="{.clusters[?(@.name==\"kind-cluster-b\")].cluster.certificate-authority-data}" | base64 -d)

  TOKEN_A=$(kubectl --context "$CTX_A" -n "$NS" create token kube-federated-auth-reader \
    --duration=168h --audience=https://kubernetes.default.svc.cluster.local)
  TOKEN_B=$(kubectl --context "$CTX_B" -n "$NS" create token kube-federated-auth-reader \
    --duration=168h --audience=https://kubernetes.default.svc.cluster.local)

  # Write runtime-discovered values to a temp file
  local RUNTIME_VALUES="${ROOT_DIR}/tests/mariadb/runtime-values.yaml"
  cat > "$RUNTIME_VALUES" <<EOF
federatedAuth:
  clusters:
    cluster-a:
      issuer: "${ISSUER_A}"
      apiServer: "https://${CLUSTER_A_IP}:6443"
    cluster-b:
      issuer: "${ISSUER_B}"
      apiServer: "https://${CLUSTER_B_IP}:6443"
  caCerts:
    cluster-a-ca.crt: |
$(echo "$CA_A" | sed 's/^/      /')
    cluster-b-ca.crt: |
$(echo "$CA_B" | sed 's/^/      /')
  tokens:
    cluster-a-token: "${TOKEN_A}"
    cluster-b-token: "${TOKEN_B}"
EOF

  # Second apply: inject real runtime values.
  helmfile apply -f "$HELMFILE" --values "$RUNTIME_VALUES"
  rm -f "$RUNTIME_VALUES"

  # Wait for deployments on cluster-a
  echo "Waiting for kube-federated-auth..."
  kubectl --context "$CTX_A" -n "$NS" rollout status deployment/kube-federated-auth --timeout=120s

  echo "Waiting for redis (cluster-a)..."
  kubectl --context "$CTX_A" -n "$NS" rollout status deployment/redis --timeout=60s

  echo "Waiting for aqsh (cluster-a)..."
  kubectl --context "$CTX_A" -n "$NS" rollout status deployment/aqsh --timeout=120s

  echo "Waiting for mariadb (cluster-a)..."
  kubectl --context "$CTX_A" -n mariadb-1 wait \
    --for=condition=Ready mariadb/mariadb --timeout=300s

  # Wait for deployments on cluster-b
  echo "Waiting for redis (cluster-b)..."
  kubectl --context "$CTX_B" -n "$NS" rollout status deployment/redis --timeout=60s

  echo "Waiting for aqsh (cluster-b)..."
  kubectl --context "$CTX_B" -n "$NS" rollout status deployment/aqsh --timeout=120s

  echo "Waiting for mariadb (cluster-b)..."
  kubectl --context "$CTX_B" -n mariadb-1 wait \
    --for=condition=Ready mariadb/mariadb --timeout=300s

  echo "Waiting for test-client..."
  kubectl --context "$CTX_B" -n "$NS" rollout status deployment/test-client --timeout=60s

  echo "=== mariadb test suite setup complete ==="
}

teardown_suite() {
  if [[ "${TEARDOWN:-}" != "true" ]]; then
    return 0
  fi
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  helmfile destroy -f "${ROOT_DIR}/tests/mariadb/helmfile.yaml" || true
  kubectl --context kind-cluster-a delete ns mariadb-1 --ignore-not-found
  kubectl --context kind-cluster-b delete ns mariadb-1 --ignore-not-found
}
