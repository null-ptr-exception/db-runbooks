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
  local ctx_a="kind-cluster-a"
  local ctx_b="kind-cluster-b"

  kubectl --context "$ctx_a" delete ns infra-a --ignore-not-found || true
  kubectl --context "$ctx_b" delete ns infra-b --ignore-not-found || true

  if [[ "${TEARDOWN:-}" == "true" ]]; then
    ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    helmfile destroy -f "${ROOT_DIR}/tests/infra/helmfile.yaml" || true
  fi
}
