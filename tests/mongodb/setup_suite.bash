#!/usr/bin/env bash

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local K8S_DIR="${ROOT_DIR}/k8s"
  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"

  # Reuse aqsh suite setup (Layers 1-3: clusters, platform, aqsh infra)
  source "${ROOT_DIR}/tests/aqsh/setup_suite.bash"
  setup_suite

  # Layer 3b: MongoDB on cluster-a (mongo-1 namespace)

  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/mongodb/rbac.yaml"

  kubectl --context "$CTX_A" create ns mongo-1 --dry-run=client -o yaml \
    | kubectl --context "$CTX_A" apply -f -

  kubectl --context "$CTX_A" -n mongo-1 apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: aqsh-mongo-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aqsh-mongo-manager
subjects:
  - kind: ServiceAccount
    name: kube-auth-proxy
    namespace: db-ops
EOF

  if ! kubectl --context "$CTX_A" -n mongo-1 get secret mongodb-credentials &>/dev/null; then
    kubectl --context "$CTX_A" -n mongo-1 create secret generic mongodb-credentials \
      --from-literal="MONGO_ROOT_USER=mongo-admin" \
      --from-literal="MONGO_ROOT_PASS=$(openssl rand -base64 16 | tr -d '=+/')"
  fi

  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/mongodb/mongo-1.yaml"

  # Layer 3c: MongoDB on cluster-b (mongo-2 namespace)

  kubectl --context "$CTX_B" apply -f "${K8S_DIR}/cluster-b/mongodb/rbac.yaml"

  kubectl --context "$CTX_B" create ns mongo-2 --dry-run=client -o yaml \
    | kubectl --context "$CTX_B" apply -f -

  kubectl --context "$CTX_B" -n mongo-2 apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: aqsh-mongo-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aqsh-mongo-manager
subjects:
  - kind: ServiceAccount
    name: kube-auth-proxy
    namespace: db-ops
EOF

  if ! kubectl --context "$CTX_B" -n mongo-2 get secret mongodb-credentials &>/dev/null; then
    kubectl --context "$CTX_B" -n mongo-2 create secret generic mongodb-credentials \
      --from-literal="MONGO_ROOT_USER=mongo-admin" \
      --from-literal="MONGO_ROOT_PASS=$(openssl rand -base64 16 | tr -d '=+/')"
  fi

  kubectl --context "$CTX_B" apply -f "${K8S_DIR}/cluster-b/mongodb/mongo-2.yaml"

  # Layer 3d: Istio TCP Gateway + VirtualServices for cross-cluster MongoDB

  # cluster-a: expose mongo-1 via TCP on port 27017
  kubectl --context "$CTX_A" -n istio-ingress apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: mongodb-tcp-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 27017
        name: mongo
        protocol: TCP
      hosts:
        - "*.kind-a.test"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: mongodb-tcp
spec:
  hosts:
    - "mongodb.kind-a.test"
  gateways:
    - mongodb-tcp-gateway
  tcp:
    - route:
        - destination:
            host: mongodb.mongo-1.svc.cluster.local
            port:
              number: 27017
EOF

  # cluster-b: expose mongo-2 via TCP on port 27017
  kubectl --context "$CTX_B" -n istio-ingress apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: mongodb-tcp-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 27017
        name: mongo
        protocol: TCP
      hosts:
        - "*.kind-b.test"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: mongodb-tcp
spec:
  hosts:
    - "mongodb.kind-b.test"
  gateways:
    - mongodb-tcp-gateway
  tcp:
    - route:
        - destination:
            host: mongodb.mongo-2.svc.cluster.local
            port:
              number: 27017
EOF

  echo "Waiting for MongoDB on cluster-a..."
  kubectl --context "$CTX_A" -n mongo-1 rollout status statefulset/mongodb --timeout=120s
  echo "Waiting for MongoDB on cluster-b..."
  kubectl --context "$CTX_B" -n mongo-2 rollout status statefulset/mongodb --timeout=120s
}

teardown_suite() {
  if [[ "${TEARDOWN:-}" != "true" ]]; then
    return 0
  fi

  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"

  kubectl --context "$CTX_A" -n istio-ingress delete gateway mongodb-tcp-gateway --ignore-not-found
  kubectl --context "$CTX_A" -n istio-ingress delete virtualservice mongodb-tcp --ignore-not-found
  kubectl --context "$CTX_B" -n istio-ingress delete gateway mongodb-tcp-gateway --ignore-not-found
  kubectl --context "$CTX_B" -n istio-ingress delete virtualservice mongodb-tcp --ignore-not-found
  kubectl --context "$CTX_A" delete ns mongo-1 --ignore-not-found
  kubectl --context "$CTX_B" delete ns mongo-2 --ignore-not-found
  kubectl --context "$CTX_A" delete clusterrole aqsh-mongo-manager aqsh-mongo-node-reader --ignore-not-found
  kubectl --context "$CTX_A" delete clusterrolebinding aqsh-mongo-node-reader --ignore-not-found
  kubectl --context "$CTX_B" delete clusterrole aqsh-mongo-manager --ignore-not-found
}
