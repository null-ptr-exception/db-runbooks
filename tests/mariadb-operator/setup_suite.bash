#!/usr/bin/env bash

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local K8S_DIR="${ROOT_DIR}/k8s"
  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"

  # Reuse aqsh suite setup (Layers 1-3: clusters, platform, aqsh infra)
  source "${ROOT_DIR}/tests/aqsh/setup_suite.bash"
  setup_suite

  # Layer 3b: mariadb-operator on cluster-a
  helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator 2>/dev/null || true
  helm repo update mariadb-operator

  helm upgrade --install mariadb-operator-crds mariadb-operator/mariadb-operator-crds \
    --kube-context "$CTX_A" \
    --wait

  helm upgrade --install mariadb-operator mariadb-operator/mariadb-operator \
    --kube-context "$CTX_A" \
    --namespace db-ops \
    --wait

  # Layer 3c: MariaDB RBAC + instance
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/mariadb/rbac.yaml"

  kubectl --context "$CTX_A" create ns mariadb-1 --dry-run=client -o yaml \
    | kubectl --context "$CTX_A" apply -f -

  kubectl --context "$CTX_A" -n mariadb-1 apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: aqsh-mariadb-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aqsh-mariadb-manager
subjects:
  - kind: ServiceAccount
    name: kube-auth-proxy
    namespace: db-ops
EOF

  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/mariadb/mariadb-1-operator.yaml"

  echo "Waiting for MariaDB operator instance..."
  if ! kubectl --context "$CTX_A" -n mariadb-1 wait \
    --for=condition=Ready mariadb/mariadb --timeout=300s 2>/dev/null; then
    echo "MariaDB CR not ready after 300s:"
    kubectl --context "$CTX_A" -n mariadb-1 get mariadb mariadb -o yaml | tail -20
    kubectl --context "$CTX_A" -n mariadb-1 get pods
    return 1
  fi

  # Layer 3d: MinIO on cluster-b (backup target)
  kubectl --context "$CTX_B" apply -f "${K8S_DIR}/cluster-b/minio/minio.yaml"

  kubectl --context "$CTX_B" -n istio-ingress apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: minio-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "minio.kind-b.test"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: minio
spec:
  hosts:
    - "minio.kind-b.test"
  gateways:
    - minio-gateway
  http:
    - route:
        - destination:
            host: minio.minio.svc.cluster.local
            port:
              number: 9000
EOF

  echo "Waiting for MinIO on cluster-b..."
  kubectl --context "$CTX_B" -n minio rollout status deployment/minio --timeout=120s
}

teardown_suite() {
  if [[ "${TEARDOWN:-}" != "true" ]]; then
    return 0
  fi

  local CTX_A="kind-cluster-a"

  kubectl --context "$CTX_A" delete ns mariadb-1 --ignore-not-found
  kubectl --context "$CTX_A" delete clusterrole aqsh-mariadb-manager --ignore-not-found
  helm uninstall mariadb-operator --kube-context "$CTX_A" --namespace db-ops 2>/dev/null || true
  helm uninstall mariadb-operator-crds --kube-context "$CTX_A" 2>/dev/null || true
  kubectl --context kind-cluster-b -n istio-ingress delete gateway minio-gateway --ignore-not-found
  kubectl --context kind-cluster-b -n istio-ingress delete virtualservice minio --ignore-not-found
  kubectl --context kind-cluster-b delete ns minio --ignore-not-found
}
