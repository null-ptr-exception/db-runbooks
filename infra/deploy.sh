#!/usr/bin/env bash
# Common infra setup shared by all test suites.
# Sources this from setup_suite.bash: source "${ROOT_DIR}/infra/deploy.sh"
# Then call: setup_infra
#
# Provides: CTX_A, CTX_B, REGISTRY, CLUSTER_A_IP, CLUSTER_B_IP

set -euo pipefail

export CTX_A="kind-cluster-a"
export CTX_B="kind-cluster-b"
export REGISTRY="localhost:5005"

setup_infra() {
  local INFRA_DIR
  INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Layer 1: clusters + registry
  ctlptl apply -f "${INFRA_DIR}/ctlptl-infra.yaml"

  # Layer 2: Cilium + Istio
  helmfile apply -f "${INFRA_DIR}/helmfile-infra.yaml"

  # Layer 3: CoreDNS — resolve *.kind-a.test / *.kind-b.test to Docker container IPs
  export CLUSTER_A_IP
  export CLUSTER_B_IP
  CLUSTER_A_IP=$(docker inspect cluster-a-control-plane -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
  CLUSTER_B_IP=$(docker inspect cluster-b-control-plane -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

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
        answer \"{{ .Name }} 60 IN A ${CLUSTER_B_IP}\"
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

  kubectl --context "$CTX_A" -n kube-system rollout status deployment coredns --timeout=60s
  kubectl --context "$CTX_B" -n kube-system rollout status deployment coredns --timeout=60s
}
