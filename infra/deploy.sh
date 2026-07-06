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

wait_ns_gone() {
  local ctx="$1"; shift
  local max_wait="${WAIT_NS_GONE_TIMEOUT:-180}"
  for ns in "$@"; do
    local elapsed=0
    while kubectl --context "$ctx" get ns "$ns" 2>/dev/null | grep -q Terminating; do
      if (( elapsed >= max_wait )); then
        echo "Timed out waiting for namespace ${ns} to terminate on ${ctx}" >&2
        kubectl --context "$ctx" get ns "$ns" -o yaml >&2 || true
        return 1
      fi
      echo "Waiting for namespace $ns to terminate on $ctx..."
      sleep 3
      elapsed=$((elapsed + 3))
    done
  done
}

ensure_kind_registry() {
  if docker inspect registry >/dev/null 2>&1; then
    docker start registry >/dev/null 2>&1 || true
  else
    docker run -d --restart=always -p "127.0.0.1:5005:5000" --name registry registry:2 >/dev/null
  fi
}

ensure_kind_cluster() {
  local name="$1"
  local config_file

  if kind get clusters | grep -qx "$name"; then
    return 0
  fi

  config_file="$(mktemp)"
  cat > "$config_file" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${name}
networking:
  disableDefaultCNI: true
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5005"]
      endpoint = ["http://registry:5000"]
nodes:
  - role: control-plane
    image: kindest/node:v1.31.6
EOF
  kind create cluster --config "$config_file"
  rm -f "$config_file"
}

setup_kind_infra_fallback() {
  echo "Using direct kind cluster setup..."
  ensure_kind_registry
  ensure_kind_cluster cluster-a
  ensure_kind_cluster cluster-b

  docker network connect kind registry >/dev/null 2>&1 || true

  for ctx in "$CTX_A" "$CTX_B"; do
    kubectl --context "$ctx" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:5005"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
  done
}

setup_infra() {
  local INFRA_DIR
  INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Layer 1: clusters + registry
  if [[ "$(uname -s)" == "Darwin" && ! -S "${HOME}/Library/Containers/com.docker.docker/Data/backend.sock" ]]; then
    setup_kind_infra_fallback
  else
    ctlptl apply -f "${INFRA_DIR}/ctlptl-infra.yaml" || setup_kind_infra_fallback
  fi

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
