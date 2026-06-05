#!/usr/bin/env bash
# aqsh test suite setup
#
# Deploys the aqsh framework layer on top of the shared infra (2 Kind clusters
# with Cilium + Istio).
#
# cluster-a (server): kube-federated-auth, kube-auth-proxy + aqsh, Redis
# cluster-b (client): test-client pod
#
# All cross-component traffic goes through Istio Gateway.

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  source "${ROOT_DIR}/infra/deploy.sh"

  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"
  local NS="aqsh-test"

  # Layer 0: shared infra (idempotent)
  setup_infra

  # Build aqsh image and load into cluster-a
  skaffold build --filename="${ROOT_DIR}/skaffold.yaml" --tag=latest
  kind load docker-image ghcr.io/null-ptr-exception/db-runbooks:latest --name cluster-a

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

  # Install RBAC first (needed for token creation)
  helmfile apply -f "${ROOT_DIR}/tests/aqsh/helmfile.yaml" -l name=aqsh-rbac-a
  helmfile apply -f "${ROOT_DIR}/tests/aqsh/helmfile.yaml" -l name=aqsh-client

  TOKEN_A=$(kubectl --context "$CTX_A" -n "$NS" create token kube-federated-auth-reader \
    --duration=168h --audience=https://kubernetes.default.svc.cluster.local)
  TOKEN_B=$(kubectl --context "$CTX_B" -n "$NS" create token kube-federated-auth-reader \
    --duration=168h --audience=https://kubernetes.default.svc.cluster.local)

  # Install server components with runtime credentials
  helmfile apply -f "${ROOT_DIR}/tests/aqsh/helmfile.yaml" -l name=aqsh-server \
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

  echo "Waiting for test-client..."
  kubectl --context "$CTX_B" -n "$NS" rollout status deployment/test-client --timeout=60s

  echo "=== aqsh test suite setup complete ==="
}

teardown_suite() {
  if [[ "${TEARDOWN:-}" != "true" ]]; then
    return 0
  fi
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  helmfile destroy -f "${ROOT_DIR}/tests/aqsh/helmfile.yaml" || true
}
