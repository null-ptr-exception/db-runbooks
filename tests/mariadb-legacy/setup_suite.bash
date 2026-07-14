#!/usr/bin/env bash

wait_deployment_rollout() {
  local ctx="$1" ns="$2" deployment="$3" timeout="$4"
  kubectl --context "$ctx" -n "$ns" rollout status "deployment/${deployment}" --timeout="$timeout"
}

delete_namespace() {
  local ctx="$1" ns="$2"
  kubectl --context "$ctx" delete ns "$ns" --ignore-not-found --wait=true --timeout=300s >/dev/null 2>&1 || true
}

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  "${ROOT_DIR}/scripts/preflight.sh"
  # shellcheck source=../../infra/deploy.sh
  source "${ROOT_DIR}/infra/deploy.sh"
  setup_infra

  local ctx
  for ctx in kind-cluster-a kind-cluster-b; do
    helm uninstall mariadb-operator -n db-ops --kube-context "$ctx" >/dev/null 2>&1 || true
    helm uninstall mariadb-operator-crds --kube-context "$ctx" >/dev/null 2>&1 || true
    delete_namespace "$ctx" mariadb-1
    delete_namespace "$ctx" db-ops
    [[ "$ctx" == kind-cluster-b ]] && delete_namespace "$ctx" minio
    # Do not let stale current-generation CRDs make discovery ambiguous when a
    # developer reruns this suite on an existing kind cluster.
    kubectl --context "$ctx" get crd -o name 2>/dev/null \
      | sed -n '/\.k8s\.mariadb\.com$/p' \
      | xargs -r kubectl --context "$ctx" delete >/dev/null 2>&1 || true
  done

  helm repo add mariadb-operator-legacy https://mariadb-operator.github.io/mariadb-operator >/dev/null 2>&1 || true
  helm repo update mariadb-operator-legacy
  helm upgrade --install mariadb-operator mariadb-operator-legacy/mariadb-operator \
    --version 0.24.0 --kube-context kind-cluster-a --namespace db-ops --create-namespace --wait --timeout 10m

  docker build -t localhost:5005/db-runbooks:latest "$ROOT_DIR"
  docker push localhost:5005/db-runbooks:latest
  kind load docker-image localhost:5005/db-runbooks:latest --name cluster-a
  kind load docker-image localhost:5005/db-runbooks:latest --name cluster-b

  # First pass creates the federated-auth reader ServiceAccounts; the real
  # issuer/CA/token values are injected on the second pass below.
  helmfile apply -f "${ROOT_DIR}/tests/mariadb-legacy/helmfile.yaml"

  local ca_ip cb_ip issuer_a issuer_b ca_a ca_b token_a token_b values_file
  ca_ip="$(docker inspect cluster-a-control-plane -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
  cb_ip="$(docker inspect cluster-b-control-plane -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
  issuer_a="$(kubectl --context kind-cluster-a get --raw /.well-known/openid-configuration | jq -r .issuer)"
  issuer_b="$(kubectl --context kind-cluster-b get --raw /.well-known/openid-configuration | jq -r .issuer)"
  ca_a="$(kubectl --context kind-cluster-a config view --raw -o jsonpath='{.clusters[?(@.name=="kind-cluster-a")].cluster.certificate-authority-data}' | base64 -d)"
  ca_b="$(kubectl --context kind-cluster-b config view --raw -o jsonpath='{.clusters[?(@.name=="kind-cluster-b")].cluster.certificate-authority-data}' | base64 -d)"
  token_a="$(kubectl --context kind-cluster-a -n db-ops create token kube-federated-auth-reader --duration=168h --audience=https://kubernetes.default.svc.cluster.local)"
  token_b="$(kubectl --context kind-cluster-b -n db-ops create token kube-federated-auth-reader --duration=168h --audience=https://kubernetes.default.svc.cluster.local)"
  values_file="${ROOT_DIR}/tests/mariadb-legacy/runtime-values.yaml"
  {
    printf 'federatedAuth:\n  clusters:\n    cluster-a:\n      issuer: "%s"\n      apiServer: "https://%s:6443"\n    cluster-b:\n      issuer: "%s"\n      apiServer: "https://%s:6443"\n  caCerts:\n' "$issuer_a" "$ca_ip" "$issuer_b" "$cb_ip"
    printf '    cluster-a-ca.crt: |\n'; sed 's/^/      /' <<<"$ca_a"
    printf '    cluster-b-ca.crt: |\n'; sed 's/^/      /' <<<"$ca_b"
    printf '  tokens:\n    cluster-a-token: "%s"\n    cluster-b-token: "%s"\n' "$token_a" "$token_b"
  } > "$values_file"
  helmfile apply -f "${ROOT_DIR}/tests/mariadb-legacy/helmfile.yaml" --values "$values_file"
  rm -f "$values_file"

  kubectl --context kind-cluster-a -n mariadb-1 wait --for=condition=Ready mariadb/mariadb --timeout=900s
  wait_deployment_rollout kind-cluster-a db-ops kube-federated-auth 300s
  wait_deployment_rollout kind-cluster-a db-ops redis 180s
  wait_deployment_rollout kind-cluster-a db-ops aqsh 300s
  wait_deployment_rollout kind-cluster-b db-ops test-client 180s
  wait_deployment_rollout kind-cluster-b minio minio 180s

  kubectl --context kind-cluster-b -n minio run s5cmd-bucket --image=peakcom/s5cmd:v2.3.0 \
    --restart=Never --rm -i --env=AWS_ACCESS_KEY_ID=minioadmin --env=AWS_SECRET_ACCESS_KEY=minioadmin-changeme-prod \
    --command -- /s5cmd --endpoint-url http://minio:9000 mb s3://db-backups
}

teardown_suite() {
  delete_namespace kind-cluster-a mariadb-1
  delete_namespace kind-cluster-b mariadb-1
  delete_namespace kind-cluster-a db-ops
  delete_namespace kind-cluster-b db-ops
  delete_namespace kind-cluster-b minio
  if [[ "${TEARDOWN:-}" == true ]]; then
    kind delete cluster --name cluster-a >/dev/null 2>&1 || true
    kind delete cluster --name cluster-b >/dev/null 2>&1 || true
  fi
}
