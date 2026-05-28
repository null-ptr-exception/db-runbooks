#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

# shellcheck source=/dev/null
source "$ENV_FILE"

DB_MODE="${DB_MODE:-single}"

if [[ "$DB_MODE" == "dual" ]]; then
  FEDAUTH_CONTEXT="kind-cluster-dbs-a"
else
  FEDAUTH_CONTEXT="kind-cluster-auth"
fi

echo "=== Extracting OIDC issuers ==="

get_issuer() {
  local context="kind-${1}"
  kubectl --context "$context" get --raw /.well-known/openid-configuration | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])"
}

get_ca_cert() {
  local context="kind-${1}"
  kubectl --context "$context" config view --raw -o jsonpath="{.clusters[?(@.name==\"kind-${1}\")].cluster.certificate-authority-data}" | base64 -d
}

create_token() {
  local cluster="$1"
  kubectl --context "kind-${cluster}" -n db-ops create token kube-federated-auth-reader \
    --duration=168h \
    --audience=https://kubernetes.default.svc.cluster.local
}

ISSUER_APPS=$(get_issuer cluster-apps)
CA_APPS=$(get_ca_cert cluster-apps)
TOKEN_APPS=$(create_token cluster-apps)

echo "cluster-apps issuer: $ISSUER_APPS"

if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then
  ISSUER_MINIO=$(get_issuer cluster-minio)
  CA_MINIO=$(get_ca_cert cluster-minio)
  TOKEN_MINIO=$(create_token cluster-minio)
  echo "cluster-minio issuer: $ISSUER_MINIO"
fi

# Remove any previously written issuer/cert entries from .env (idempotency)
sed -i '/^ISSUER_DBS/d;/^ISSUER_APPS=/d;/^ISSUER_MINIO=/d' "$ENV_FILE"

if [[ "$DB_MODE" == "dual" ]]; then
  ISSUER_DBS_A=$(get_issuer cluster-dbs-a)
  ISSUER_DBS_B=$(get_issuer cluster-dbs-b)
  echo "cluster-dbs-a issuer: $ISSUER_DBS_A"
  echo "cluster-dbs-b issuer: $ISSUER_DBS_B"

  cat >> "$ENV_FILE" <<EOF
ISSUER_DBS_A=${ISSUER_DBS_A}
ISSUER_DBS_B=${ISSUER_DBS_B}
ISSUER_APPS=${ISSUER_APPS}
$(if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then echo "ISSUER_MINIO=${ISSUER_MINIO}"; fi)
EOF

  echo "=== Extracting CA certificates ==="
  CA_DBS_A=$(get_ca_cert cluster-dbs-a)
  CA_DBS_B=$(get_ca_cert cluster-dbs-b)

  echo "=== Creating bootstrap tokens ==="
  TOKEN_DBS_A=$(create_token cluster-dbs-a)
  TOKEN_DBS_B=$(create_token cluster-dbs-b)

  echo "=== Storing CA certs as ConfigMap in cluster-auth ==="
  if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then
    kubectl --context "${FEDAUTH_CONTEXT}" -n db-ops create configmap kube-federated-auth-ca-certs \
      --from-literal="cluster-dbs-a-ca.crt=${CA_DBS_A}" \
      --from-literal="cluster-dbs-b-ca.crt=${CA_DBS_B}" \
      --from-literal="cluster-apps-ca.crt=${CA_APPS}" \
      --from-literal="cluster-minio-ca.crt=${CA_MINIO}" \
      --dry-run=client -o yaml | kubectl --context "${FEDAUTH_CONTEXT}" apply -f -
  else
    kubectl --context "${FEDAUTH_CONTEXT}" -n db-ops create configmap kube-federated-auth-ca-certs \
      --from-literal="cluster-dbs-a-ca.crt=${CA_DBS_A}" \
      --from-literal="cluster-dbs-b-ca.crt=${CA_DBS_B}" \
      --from-literal="cluster-apps-ca.crt=${CA_APPS}" \
      --dry-run=client -o yaml | kubectl --context "${FEDAUTH_CONTEXT}" apply -f -
  fi

  echo "=== Storing tokens as Secret in cluster-auth ==="
  if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then
    kubectl --context "${FEDAUTH_CONTEXT}" -n db-ops create secret generic kube-federated-auth-tokens \
      --from-literal="cluster-dbs-a-token=${TOKEN_DBS_A}" \
      --from-literal="cluster-dbs-b-token=${TOKEN_DBS_B}" \
      --from-literal="cluster-apps-token=${TOKEN_APPS}" \
      --from-literal="cluster-minio-token=${TOKEN_MINIO}" \
      --dry-run=client -o yaml | kubectl --context "${FEDAUTH_CONTEXT}" apply -f -
  else
    kubectl --context "${FEDAUTH_CONTEXT}" -n db-ops create secret generic kube-federated-auth-tokens \
      --from-literal="cluster-dbs-a-token=${TOKEN_DBS_A}" \
      --from-literal="cluster-dbs-b-token=${TOKEN_DBS_B}" \
      --from-literal="cluster-apps-token=${TOKEN_APPS}" \
      --dry-run=client -o yaml | kubectl --context "${FEDAUTH_CONTEXT}" apply -f -
  fi
else
  ISSUER_DBS=$(get_issuer cluster-dbs)
  echo "cluster-dbs issuer:  $ISSUER_DBS"

  cat >> "$ENV_FILE" <<EOF
ISSUER_DBS=${ISSUER_DBS}
ISSUER_APPS=${ISSUER_APPS}
$(if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then echo "ISSUER_MINIO=${ISSUER_MINIO}"; fi)
EOF

  echo "=== Extracting CA certificates ==="
  CA_DBS=$(get_ca_cert cluster-dbs)

  echo "=== Creating bootstrap tokens ==="
  TOKEN_DBS=$(create_token cluster-dbs)

  echo "=== Storing CA certs as ConfigMap in cluster-auth ==="
  if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then
    kubectl --context "${FEDAUTH_CONTEXT}" -n db-ops create configmap kube-federated-auth-ca-certs \
      --from-literal="cluster-dbs-ca.crt=${CA_DBS}" \
      --from-literal="cluster-apps-ca.crt=${CA_APPS}" \
      --from-literal="cluster-minio-ca.crt=${CA_MINIO}" \
      --dry-run=client -o yaml | kubectl --context "${FEDAUTH_CONTEXT}" apply -f -
  else
    kubectl --context "${FEDAUTH_CONTEXT}" -n db-ops create configmap kube-federated-auth-ca-certs \
      --from-literal="cluster-dbs-ca.crt=${CA_DBS}" \
      --from-literal="cluster-apps-ca.crt=${CA_APPS}" \
      --dry-run=client -o yaml | kubectl --context "${FEDAUTH_CONTEXT}" apply -f -
  fi

  echo "=== Storing tokens as Secret in cluster-auth ==="
  if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then
    kubectl --context "${FEDAUTH_CONTEXT}" -n db-ops create secret generic kube-federated-auth-tokens \
      --from-literal="cluster-dbs-token=${TOKEN_DBS}" \
      --from-literal="cluster-apps-token=${TOKEN_APPS}" \
      --from-literal="cluster-minio-token=${TOKEN_MINIO}" \
      --dry-run=client -o yaml | kubectl --context "${FEDAUTH_CONTEXT}" apply -f -
  else
    kubectl --context "${FEDAUTH_CONTEXT}" -n db-ops create secret generic kube-federated-auth-tokens \
      --from-literal="cluster-dbs-token=${TOKEN_DBS}" \
      --from-literal="cluster-apps-token=${TOKEN_APPS}" \
      --dry-run=client -o yaml | kubectl --context "${FEDAUTH_CONTEXT}" apply -f -
  fi
fi

echo "=== Credentials setup complete ==="
