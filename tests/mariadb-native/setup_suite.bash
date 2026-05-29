#!/usr/bin/env bash

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local K8S_DIR="${ROOT_DIR}/k8s"
  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"

  # Reuse aqsh suite setup (Layers 1-3: clusters, platform, aqsh infra)
  source "${ROOT_DIR}/tests/aqsh/setup_suite.bash"
  setup_suite

  # Layer 3b: MariaDB on cluster-a (mariadb-1 namespace, native StatefulSet)

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

  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/mariadb/mariadb-1-native.yaml"

  # Layer 3c: MariaDB on cluster-b (mariadb-2 namespace, native StatefulSet)

  kubectl --context "$CTX_B" apply -f "${K8S_DIR}/cluster-b/mariadb/rbac.yaml"

  kubectl --context "$CTX_B" create ns mariadb-2 --dry-run=client -o yaml \
    | kubectl --context "$CTX_B" apply -f -

  kubectl --context "$CTX_B" -n mariadb-2 apply -f - <<'EOF'
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

  kubectl --context "$CTX_B" apply -f "${K8S_DIR}/cluster-b/mariadb/mariadb-2-native.yaml"

  # Layer 3d: Istio TCP Gateway + VirtualServices for cross-cluster MariaDB

  kubectl --context "$CTX_A" -n istio-ingress apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: mariadb-tcp-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 3306
        name: mysql
        protocol: TCP
      hosts:
        - "*.kind-a.test"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: mariadb-tcp
spec:
  hosts:
    - "mariadb.kind-a.test"
  gateways:
    - mariadb-tcp-gateway
  tcp:
    - route:
        - destination:
            host: mariadb.mariadb-1.svc.cluster.local
            port:
              number: 3306
EOF

  kubectl --context "$CTX_B" -n istio-ingress apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: mariadb-tcp-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 3306
        name: mysql
        protocol: TCP
      hosts:
        - "*.kind-b.test"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: mariadb-tcp
spec:
  hosts:
    - "mariadb.kind-b.test"
  gateways:
    - mariadb-tcp-gateway
  tcp:
    - route:
        - destination:
            host: mariadb.mariadb-2.svc.cluster.local
            port:
              number: 3306
EOF

  echo "Waiting for MariaDB on cluster-a..."
  kubectl --context "$CTX_A" -n mariadb-1 rollout status statefulset/mariadb --timeout=120s
  echo "Waiting for MariaDB on cluster-b..."
  kubectl --context "$CTX_B" -n mariadb-2 rollout status statefulset/mariadb --timeout=120s

  # Layer 3e: MinIO on cluster-b (backup target)
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
  local CTX_B="kind-cluster-b"

  kubectl --context "$CTX_A" -n istio-ingress delete gateway mariadb-tcp-gateway --ignore-not-found
  kubectl --context "$CTX_A" -n istio-ingress delete virtualservice mariadb-tcp --ignore-not-found
  kubectl --context "$CTX_B" -n istio-ingress delete gateway mariadb-tcp-gateway --ignore-not-found
  kubectl --context "$CTX_B" -n istio-ingress delete virtualservice mariadb-tcp --ignore-not-found
  kubectl --context "$CTX_A" delete ns mariadb-1 --ignore-not-found
  kubectl --context "$CTX_B" delete ns mariadb-2 --ignore-not-found
  kubectl --context "$CTX_A" delete clusterrole aqsh-mariadb-manager --ignore-not-found
  kubectl --context "$CTX_B" delete clusterrole aqsh-mariadb-manager --ignore-not-found
  kubectl --context "$CTX_B" -n istio-ingress delete gateway minio-gateway --ignore-not-found
  kubectl --context "$CTX_B" -n istio-ingress delete virtualservice minio --ignore-not-found
  kubectl --context "$CTX_B" delete ns minio --ignore-not-found
}
