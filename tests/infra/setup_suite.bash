#!/usr/bin/env bash

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  source "${ROOT_DIR}/infra/deploy.sh"
  setup_infra

  # Push nginx + curl images to local registry
  for img in nginx:alpine curlimages/curl:latest; do
    local name="${img%%:*}"
    name="${name##*/}"
    docker pull "$img" 2>/dev/null || true
    docker tag "$img" "${REGISTRY}/${name}:latest"
    docker push "${REGISTRY}/${name}:latest"
  done

  # Deploy nginx + Istio Gateway/VirtualService on both clusters
  for cluster_ctx in "$CTX_A:kind-a:infra-a" "$CTX_B:kind-b:infra-b"; do
    IFS=: read -r ctx domain ns <<< "$cluster_ctx"
    kubectl --context "$ctx" create namespace "$ns" --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

    kubectl --context "$ctx" -n "$ns" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: ${REGISTRY}/nginx:latest
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
spec:
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
EOF

    kubectl --context "$ctx" -n istio-ingress apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: infra-test-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "*.${domain}.test"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: nginx
spec:
  hosts:
    - "nginx.${domain}.test"
  gateways:
    - infra-test-gateway
  http:
    - route:
        - destination:
            host: nginx.${ns}.svc.cluster.local
            port:
              number: 80
EOF

    kubectl --context "$ctx" -n "$ns" rollout status deployment/nginx --timeout=60s
  done

  # Deploy curl pods on both clusters
  for cluster_ctx in "$CTX_A:infra-a" "$CTX_B:infra-b"; do
    IFS=: read -r ctx ns <<< "$cluster_ctx"
    kubectl --context "$ctx" -n "$ns" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl
spec:
  replicas: 1
  selector:
    matchLabels:
      app: curl
  template:
    metadata:
      labels:
        app: curl
    spec:
      containers:
        - name: curl
          image: ${REGISTRY}/curl:latest
          command: ["sleep", "infinity"]
EOF
    kubectl --context "$ctx" -n "$ns" rollout status deployment/curl --timeout=60s
  done
}

teardown_suite() {
  if [[ "${TEARDOWN:-}" != "true" ]]; then
    return 0
  fi

  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"

  for ctx in "$CTX_A" "$CTX_B"; do
    kubectl --context "$ctx" -n istio-ingress delete gateway infra-test-gateway --ignore-not-found
    kubectl --context "$ctx" -n istio-ingress delete virtualservice nginx --ignore-not-found
  done
  kubectl --context "$CTX_A" delete ns infra-a --ignore-not-found
  kubectl --context "$CTX_B" delete ns infra-b --ignore-not-found
}
