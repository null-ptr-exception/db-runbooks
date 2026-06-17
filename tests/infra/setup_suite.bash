#!/usr/bin/env bash

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  "${ROOT_DIR}/scripts/preflight.sh"
  source "${ROOT_DIR}/infra/deploy.sh"
  setup_infra

  helmfile apply -f "${ROOT_DIR}/tests/infra/helmfile.yaml"

  kubectl --context kind-cluster-a -n infra-a rollout status deployment/nginx --timeout=60s
  kubectl --context kind-cluster-b -n infra-b rollout status deployment/nginx --timeout=60s
  kubectl --context kind-cluster-a -n infra-a rollout status deployment/curl --timeout=60s
  kubectl --context kind-cluster-b -n infra-b rollout status deployment/curl --timeout=60s
}

teardown_suite() {
  if [[ "${TEARDOWN:-}" != "true" ]]; then
    return 0
  fi
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  helmfile destroy -f "${ROOT_DIR}/tests/infra/helmfile.yaml" || true
}
