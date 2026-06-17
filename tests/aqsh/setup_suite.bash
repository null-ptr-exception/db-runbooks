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
  "${ROOT_DIR}/scripts/preflight.sh"
  source "${ROOT_DIR}/infra/deploy.sh"

  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"
  local NS="aqsh-test"

  # Layer 0: shared infra (idempotent)
  setup_infra

  # Build aqsh image and push to local registry
  docker build -t localhost:5005/db-runbooks:latest "${ROOT_DIR}"
  docker push localhost:5005/db-runbooks:latest

  local HELMFILE="${ROOT_DIR}/tests/aqsh/helmfile.yaml"

  # First apply: deploy everything with default (empty) runtime values.
  # This creates SAs, RBAC, and all workloads. Federated-auth starts
  # without real tokens — that's fine, we fix it in the second apply.
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

  local RUNTIME_VALUES="${ROOT_DIR}/tests/aqsh/runtime-values.yaml"
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

  # Second apply: inject real runtime values. Helm updates only the
  # resources whose values changed (Secret, ConfigMaps). Drift-free.
  # The checksum annotation on the Deployment triggers a rollout automatically.
  helmfile apply -f "$HELMFILE" --values "$RUNTIME_VALUES"
  rm -f "$RUNTIME_VALUES"

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
