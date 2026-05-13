#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

# shellcheck source=/dev/null
source "$ENV_FILE"

echo "=== Extracting OIDC issuers ==="

get_issuer() {
  local context="kind-${1}"
  kubectl --context "$context" get --raw /.well-known/openid-configuration | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])"
}

ISSUER_DBS=$(get_issuer cluster-dbs)
ISSUER_APPS=$(get_issuer cluster-apps)

echo "cluster-dbs issuer:  $ISSUER_DBS"
echo "cluster-apps issuer: $ISSUER_APPS"

# Update issuers in .env (remove old entries first for idempotency)
sed -i '/^ISSUER_DBS=/d;/^ISSUER_APPS=/d' "$ENV_FILE"
cat >> "$ENV_FILE" <<EOF
ISSUER_DBS=${ISSUER_DBS}
ISSUER_APPS=${ISSUER_APPS}
EOF

echo "=== Extracting CA certificates ==="

get_ca_cert() {
  local context="kind-${1}"
  kubectl --context "$context" config view --raw -o jsonpath="{.clusters[?(@.name==\"kind-${1}\")].cluster.certificate-authority-data}" | base64 -d
}

CA_DBS=$(get_ca_cert cluster-dbs)
CA_APPS=$(get_ca_cert cluster-apps)

echo "=== Creating bootstrap tokens for cluster-dbs and cluster-apps ==="

create_token() {
  local cluster="$1"
  local context="kind-${cluster}"
  kubectl --context "$context" -n db-ops create token kube-federated-auth-reader \
    --duration=168h \
    --audience=https://kubernetes.default.svc.cluster.local
}

TOKEN_DBS=$(create_token cluster-dbs)
TOKEN_APPS=$(create_token cluster-apps)

echo "=== Storing CA certs as ConfigMap in cluster-auth ==="

kubectl --context kind-cluster-auth -n db-ops create configmap kube-federated-auth-ca-certs \
  --from-literal="cluster-dbs-ca.crt=${CA_DBS}" \
  --from-literal="cluster-apps-ca.crt=${CA_APPS}" \
  --dry-run=client -o yaml | kubectl --context kind-cluster-auth apply -f -

echo "=== Storing tokens as Secret in cluster-auth ==="

kubectl --context kind-cluster-auth -n db-ops create secret generic kube-federated-auth-tokens \
  --from-literal="cluster-dbs-token=${TOKEN_DBS}" \
  --from-literal="cluster-apps-token=${TOKEN_APPS}" \
  --dry-run=client -o yaml | kubectl --context kind-cluster-auth apply -f -

echo "=== Credentials setup complete ==="
