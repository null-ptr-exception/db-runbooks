#!/usr/bin/env bash

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local K8S_DIR="${ROOT_DIR}/k8s"
  local CTX_A="kind-cluster-a"

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
}
