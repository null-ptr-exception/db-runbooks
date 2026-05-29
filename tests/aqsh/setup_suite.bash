#!/usr/bin/env bash

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local INFRA_DIR="${ROOT_DIR}/infra"
  local K8S_DIR="${ROOT_DIR}/k8s"
  local SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"

  # Layer 1: ensure clusters exist
  "${INFRA_DIR}/create-clusters.sh"

  # Layer 2: shared platform (Cilium + Istio + Gateway)
  helmfile sync -f "${INFRA_DIR}/helmfile-platform.yaml"

  # Layer 3: suite-specific infra

  # 3a. Namespaces + RBAC
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/namespace.yaml"
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/federated-auth-rbac.yaml"
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/kube-federated-auth-rbac.yaml"
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/aqsh-rbac.yaml"
  kubectl --context "$CTX_B" apply -f "${K8S_DIR}/cluster-b/namespace.yaml"
  kubectl --context "$CTX_B" apply -f "${K8S_DIR}/cluster-b/federated-auth-rbac.yaml"

  # 3b. Credentials (OIDC issuers, CA certs, bootstrap tokens)
  local cred_output
  cred_output=$("${SUITE_DIR}/setup-credentials.sh")
  local ISSUER_CLUSTER_A ISSUER_CLUSTER_B CLUSTER_B_IP
  eval "$(echo "$cred_output" | grep '^ISSUER_CLUSTER_A=\|^ISSUER_CLUSTER_B=\|^CLUSTER_B_IP=')"
  export ISSUER_CLUSTER_A ISSUER_CLUSTER_B CLUSTER_B_IP

  # 3c. kube-federated-auth configmap + deployment
  envsubst < "${K8S_DIR}/cluster-a/kube-federated-auth-configmap.yaml.tpl" \
    | kubectl --context "$CTX_A" apply -f -
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/kube-federated-auth-deployment.yaml"
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/kube-federated-auth-service.yaml"

  echo "Waiting for kube-federated-auth..."
  kubectl --context "$CTX_A" -n db-ops rollout status deployment/kube-federated-auth --timeout=120s

  # 3d. Build and load aqsh images
  skaffold build --filename="${ROOT_DIR}/skaffold.yaml" --tag=latest --quiet
  kind load docker-image aqsh-mariadb:latest --name cluster-a
  kind load docker-image aqsh-mongodb:latest --name cluster-a

  # 3e. Redis + aqsh deployments
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/redis.yaml"
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/aqsh-mariadb-service.yaml"
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/aqsh-mongodb-service.yaml"
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/aqsh-mariadb-deployment.yaml"
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/aqsh-mongodb-deployment.yaml"

  echo "Waiting for Redis..."
  kubectl --context "$CTX_A" -n db-ops rollout status deployment/redis --timeout=120s
  echo "Waiting for aqsh-mariadb..."
  kubectl --context "$CTX_A" -n db-ops rollout status deployment/aqsh-mariadb --timeout=120s
  echo "Waiting for aqsh-mongodb..."
  kubectl --context "$CTX_A" -n db-ops rollout status deployment/aqsh-mongodb --timeout=120s

  # 3f. Istio Gateway + VirtualServices for routing
  kubectl --context "$CTX_A" -n istio-ingress apply -f - <<'VSEOF'
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: aqsh-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "*.kind-a.test"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: aqsh-mariadb
spec:
  hosts:
    - "aqsh-mariadb.kind-a.test"
  gateways:
    - aqsh-gateway
  http:
    - route:
        - destination:
            host: aqsh-mariadb.db-ops.svc.cluster.local
            port:
              number: 4180
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: aqsh-mongodb
spec:
  hosts:
    - "aqsh-mongodb.kind-a.test"
  gateways:
    - aqsh-gateway
  http:
    - route:
        - destination:
            host: aqsh-mongodb.db-ops.svc.cluster.local
            port:
              number: 4180
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: fedauth
spec:
  hosts:
    - "fedauth.kind-a.test"
  gateways:
    - aqsh-gateway
  http:
    - route:
        - destination:
            host: kube-federated-auth.db-ops.svc.cluster.local
            port:
              number: 8080
VSEOF

  # 3g. Patch CoreDNS on both clusters to resolve *.kind-a.test / *.kind-b.test
  # curl treats *.localhost as 127.0.0.1 (RFC 6761), so we use .test TLD instead.
  # Pods resolve *.kind-a.test to cluster-a's Docker container IP directly.
  local CLUSTER_A_IP CLUSTER_B_IP_DOCKER
  CLUSTER_A_IP=$(docker inspect cluster-a-control-plane -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
  CLUSTER_B_IP_DOCKER=$(docker inspect cluster-b-control-plane -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

  for ctx in "$CTX_A" "$CTX_B"; do
    kubectl --context "$ctx" -n kube-system create configmap coredns \
      --from-literal=Corefile="
kind-a.test:53 {
    template IN A kind-a.test {
        answer \"{{ .Name }} 60 IN A ${CLUSTER_A_IP}\"
    }
}
kind-b.test:53 {
    template IN A kind-b.test {
        answer \"{{ .Name }} 60 IN A ${CLUSTER_B_IP_DOCKER}\"
    }
}
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30
    loop
    reload
    loadbalance
}
" --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -
    kubectl --context "$ctx" -n kube-system rollout restart deployment coredns
  done

  kubectl --context "$CTX_A" -n kube-system rollout status deployment coredns --timeout=30s
  kubectl --context "$CTX_B" -n kube-system rollout status deployment coredns --timeout=30s

  # 3h. Test client on cluster-b
  kubectl --context "$CTX_B" apply -f "${K8S_DIR}/cluster-b/test-client.yaml"
  echo "Waiting for test-client..."
  kubectl --context "$CTX_B" -n app-a rollout status deployment/test-client --timeout=60s
}

teardown_suite() {
  if [[ "${TEARDOWN:-}" != "true" ]]; then
    return 0
  fi

  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"

  kubectl --context "$CTX_A" -n istio-ingress delete gateway aqsh-gateway --ignore-not-found
  kubectl --context "$CTX_A" -n istio-ingress delete virtualservice aqsh-mariadb aqsh-mongodb fedauth --ignore-not-found
  kubectl --context "$CTX_A" delete ns db-ops --ignore-not-found
  kubectl --context "$CTX_B" delete ns db-ops app-a --ignore-not-found
}
