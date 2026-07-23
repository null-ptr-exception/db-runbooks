#!/usr/bin/env bash
# MariaDB test suite setup
#
# Deploys the MariaDB control plane + test instances on the 2-cluster infra.
#
# cluster-a (server):
#   db-ops:     kube-federated-auth, kube-auth-proxy + aqsh-mariadb, Redis
#   mariadb-1 / mariadb-2: independently configured MariaDB instances
# cluster-b (server + client):
#   db-ops:     test-client pod, kube-auth-proxy + aqsh-mariadb, Redis
#   mariadb-1:  MariaDB instance (operator-managed)
#   minio:      MinIO for backup tests

wait_deployment_rollout() {
  local ctx="$1"
  local ns="$2"
  local deployment="$3"
  local timeout="$4"

  if kubectl --context "$ctx" -n "$ns" rollout status "deployment/${deployment}" --timeout="$timeout"; then
    return 0
  fi

  echo "=== diagnostics for ${ctx}/${ns}/deployment/${deployment} ===" >&2
  kubectl --context "$ctx" -n "$ns" get pods -o wide >&2 || true
  kubectl --context "$ctx" -n "$ns" describe "deployment/${deployment}" >&2 || true
  kubectl --context "$ctx" -n "$ns" describe pods -l "app=${deployment}" >&2 || true
  kubectl --context "$ctx" -n "$ns" logs -l "app=${deployment}" --all-containers --tail=200 >&2 || true
  return 1
}

ensure_minio_bucket() {
  local ctx="$1"
  local bucket="$2"
  local pod="minio-mc-${bucket}"

  kubectl --context "$ctx" -n minio delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl --context "$ctx" -n minio run "$pod" \
    --image=minio/mc \
    --restart=Never \
    --rm -i \
    --pod-running-timeout=180s \
    --command -- sh -c \
      "timeout 60 mc alias set local http://minio:9000 minioadmin minioadmin-changeme-prod && timeout 60 mc mb -p local/${bucket}"
}

delete_namespace_and_wait() {
  local ctx="$1"
  local ns="$2"
  local timeout="${3:-300s}"

  if kubectl --context "$ctx" delete ns "$ns" --ignore-not-found --wait=true --timeout="$timeout"; then
    return 0
  fi

  echo "=== namespace delete diagnostics for ${ctx}/${ns} ===" >&2
  kubectl --context "$ctx" get ns "$ns" -o yaml >&2 || true
  kubectl --context "$ctx" -n "$ns" get users.k8s.mariadb.com,grants.k8s.mariadb.com,mariadbs.k8s.mariadb.com,physicalbackups.k8s.mariadb.com -o wide >&2 || true
  return 1
}

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  "${ROOT_DIR}/scripts/preflight.sh"
  source "${ROOT_DIR}/infra/deploy.sh"

  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"
  local NS="db-ops"

  # Layer 0: shared infra (idempotent)
  setup_infra

  wait_ns_gone "$CTX_A" db-ops mariadb-1 mariadb-2
  wait_ns_gone "$CTX_B" db-ops mariadb-1 minio

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
  kind load docker-image localhost:5005/db-runbooks:latest --name cluster-a
  kind load docker-image localhost:5005/db-runbooks:latest --name cluster-b

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

  # Throwaway deployment PGP keypair for the secrets/* task family (shared
  # by both clusters' aqsh releases; callers fetch the public half through
  # the secrets/pubkey task). No gpg on the host → no key; the secrets.bats
  # file skips itself instead of failing the whole suite.
  local PGP_PRIV
  PGP_PRIV=$(provision_ephemeral_pgp_key)

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
  if [[ -n "$PGP_PRIV" ]]; then
    cat >> "$RUNTIME_VALUES" <<EOF
aqsh:
  pgpKey: |
$(echo "$PGP_PRIV" | sed 's/^/    /')
EOF
  fi

  # Second apply: inject real runtime values.
  helmfile apply -f "$HELMFILE" --values "$RUNTIME_VALUES"
  rm -f "$RUNTIME_VALUES"

  # Wait for deployments on cluster-a
  echo "Waiting for kube-federated-auth..."
  kubectl --context "$CTX_A" -n "$NS" wait \
    --for=condition=Available deployment/kube-federated-auth --timeout=300s

  echo "Waiting for redis (cluster-a)..."
  wait_deployment_rollout "$CTX_A" "$NS" redis 120s

  echo "Waiting for aqsh (cluster-a)..."
  wait_deployment_rollout "$CTX_A" "$NS" aqsh 300s

  echo "Waiting for mariadb (cluster-a)..."
  kubectl --context "$CTX_A" -n mariadb-1 wait \
    --for=condition=Ready mariadb/mariadb --timeout=900s
  kubectl --context "$CTX_A" -n mariadb-2 wait \
    --for=condition=Ready mariadb/mariadb --timeout=900s

  echo "Waiting for namespace-local database gateway..."
  wait_deployment_rollout "$CTX_A" mariadb-1 database-gateway 180s

  echo "Waiting for database gateway test client..."
  wait_deployment_rollout "$CTX_A" mariadb-1 database-gateway-client 120s

  # Wait for deployments on cluster-b
  echo "Waiting for redis (cluster-b)..."
  wait_deployment_rollout "$CTX_B" "$NS" redis 120s

  echo "Waiting for aqsh (cluster-b)..."
  wait_deployment_rollout "$CTX_B" "$NS" aqsh 300s

  echo "Waiting for mariadb (cluster-b)..."
  kubectl --context "$CTX_B" -n mariadb-1 wait \
    --for=condition=Ready mariadb/mariadb --timeout=900s

  echo "Waiting for test-client..."
  wait_deployment_rollout "$CTX_B" "$NS" test-client 120s

  echo "Waiting for minio..."
  wait_deployment_rollout "$CTX_B" minio minio 180s
  ensure_minio_bucket "$CTX_B" db-backups

  echo "=== mariadb test suite setup complete ==="
}

teardown_suite() {
  local ctx_a="kind-cluster-a"
  local ctx_b="kind-cluster-b"

  # Delete database namespaces first — the operator in db-ops processes CR finalizers.
  # Then delete db-ops — no finalizer-bearing CRs remain.
  delete_namespace_and_wait "$ctx_a" mariadb-1 300s || true
  delete_namespace_and_wait "$ctx_a" mariadb-2 300s || true
  delete_namespace_and_wait "$ctx_b" mariadb-1 300s || true
  kubectl --context "$ctx_a" delete ns db-ops --ignore-not-found --wait=false || true
  kubectl --context "$ctx_b" delete ns db-ops minio --ignore-not-found --wait=false || true

  if [[ "${TEARDOWN:-}" == "true" ]]; then
    ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    helmfile destroy -f "${ROOT_DIR}/tests/mariadb/helmfile.yaml" || true
  fi
}
