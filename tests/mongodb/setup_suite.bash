#!/usr/bin/env bash
# MongoDB test suite setup
#
# Deploys the MongoDB control plane + a test instance on the 2-cluster infra.
#
# cluster-a (server):
#   mongo-core: kube-federated-auth, kube-auth-proxy + aqsh-mongodb, Redis
#   mongo-1:   MongoDB StatefulSet
# cluster-b (client):
#   mongo-core: test-client pod

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  source "${ROOT_DIR}/infra/deploy.sh"

  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"
  local NS="mongo-core"

  # Layer 0: shared infra (idempotent)
  setup_infra

  # Build aqsh image and push to local registry
  docker build -t localhost:5005/db-runbooks:latest "${ROOT_DIR}"
  docker push localhost:5005/db-runbooks:latest

  # Extract runtime credentials (issuers, CA certs)
  local ISSUER_A ISSUER_B CA_A CA_B TOKEN_A TOKEN_B

  ISSUER_A=$(kubectl --context "$CTX_A" get --raw /.well-known/openid-configuration \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])")
  ISSUER_B=$(kubectl --context "$CTX_B" get --raw /.well-known/openid-configuration \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])")

  CA_A=$(kubectl --context "$CTX_A" config view --raw \
    -o jsonpath="{.clusters[?(@.name==\"kind-cluster-a\")].cluster.certificate-authority-data}" | base64 -d)
  CA_B=$(kubectl --context "$CTX_B" config view --raw \
    -o jsonpath="{.clusters[?(@.name==\"kind-cluster-b\")].cluster.certificate-authority-data}" | base64 -d)

  # Install RBAC + client + MongoDB instance first (needed for token creation)
  helmfile apply -f "${ROOT_DIR}/tests/mongodb/helmfile.yaml" \
    -l name=mongodb-rbac-a
  helmfile apply -f "${ROOT_DIR}/tests/mongodb/helmfile.yaml" \
    -l name=mongodb-client
  helmfile apply -f "${ROOT_DIR}/tests/mongodb/helmfile.yaml" \
    -l name=mongo-1

  # Mint real tokens now that SAs exist
  TOKEN_A=$(kubectl --context "$CTX_A" -n "$NS" create token kube-federated-auth-reader \
    --duration=168h --audience=https://kubernetes.default.svc.cluster.local)
  TOKEN_B=$(kubectl --context "$CTX_B" -n "$NS" create token kube-federated-auth-reader \
    --duration=168h --audience=https://kubernetes.default.svc.cluster.local)

  # Install server components with real tokens
  helmfile apply -f "${ROOT_DIR}/tests/mongodb/helmfile.yaml" \
    -l name=mongodb-server \
    --set "federatedAuth.clusters.cluster-a.issuer=${ISSUER_A}" \
    --set "federatedAuth.clusters.cluster-a.apiServer=https://${CLUSTER_A_IP}:6443" \
    --set "federatedAuth.clusters.cluster-b.issuer=${ISSUER_B}" \
    --set "federatedAuth.clusters.cluster-b.apiServer=https://${CLUSTER_B_IP}:6443" \
    --set "federatedAuth.caCerts.cluster-a-ca\\.crt=${CA_A}" \
    --set "federatedAuth.caCerts.cluster-b-ca\\.crt=${CA_B}" \
    --set "federatedAuth.tokens.cluster-a-token=${TOKEN_A}" \
    --set "federatedAuth.tokens.cluster-b-token=${TOKEN_B}" \
    --set "federatedAuth.authorizedClients[0]=cluster-a/${NS}/kube-auth-proxy"

  # Wait for deployments
  echo "Waiting for kube-federated-auth..."
  kubectl --context "$CTX_A" -n "$NS" rollout status deployment/kube-federated-auth --timeout=120s

  echo "Waiting for redis..."
  kubectl --context "$CTX_A" -n "$NS" rollout status deployment/redis --timeout=60s

  echo "Waiting for aqsh..."
  kubectl --context "$CTX_A" -n "$NS" rollout status deployment/aqsh --timeout=120s

  echo "Waiting for mongodb..."
  kubectl --context "$CTX_A" -n mongo-1 rollout status statefulset/mongodb --timeout=120s

  echo "Waiting for test-client..."
  kubectl --context "$CTX_B" -n "$NS" rollout status deployment/test-client --timeout=60s

  echo "=== mongodb test suite setup complete ==="
}

teardown_suite() {
  if [[ "${TEARDOWN:-}" != "true" ]]; then
    return 0
  fi
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  helmfile destroy -f "${ROOT_DIR}/tests/mongodb/helmfile.yaml" || true
  kubectl --context kind-cluster-a delete ns mongo-1 --ignore-not-found
}
