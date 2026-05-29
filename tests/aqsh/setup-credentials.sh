#!/usr/bin/env bash
set -euo pipefail

CTX_A="kind-cluster-a"
CTX_B="kind-cluster-b"

get_issuer() {
  kubectl --context "$1" get --raw /.well-known/openid-configuration \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])"
}

get_ca_cert() {
  local ctx="$1" cluster_name="$2"
  kubectl --context "$ctx" config view --raw \
    -o jsonpath="{.clusters[?(@.name==\"${cluster_name}\")].cluster.certificate-authority-data}" \
    | base64 -d
}

ISSUER_CLUSTER_A=$(get_issuer "$CTX_A")
ISSUER_CLUSTER_B=$(get_issuer "$CTX_B")
CA_B=$(get_ca_cert "$CTX_B" "kind-cluster-b")
CLUSTER_B_IP=$(docker inspect cluster-b-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

TOKEN_B=$(kubectl --context "$CTX_B" -n db-ops create token kube-federated-auth-reader \
  --duration=168h \
  --audience=https://kubernetes.default.svc.cluster.local)

kubectl --context "$CTX_A" -n db-ops create configmap kube-federated-auth-ca-certs \
  --from-literal="cluster-b-ca.crt=${CA_B}" \
  --dry-run=client -o yaml | kubectl --context "$CTX_A" apply -f -

kubectl --context "$CTX_A" -n db-ops create secret generic kube-federated-auth-tokens \
  --from-literal="cluster-b-token=${TOKEN_B}" \
  --dry-run=client -o yaml | kubectl --context "$CTX_A" apply -f -

echo "ISSUER_CLUSTER_A=${ISSUER_CLUSTER_A}"
echo "ISSUER_CLUSTER_B=${ISSUER_CLUSTER_B}"
echo "CLUSTER_B_IP=${CLUSTER_B_IP}"
