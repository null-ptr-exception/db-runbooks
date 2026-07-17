#!/usr/bin/env bats

setup_file() {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
  export REPO_ROOT
}

@test "database task definitions do not expose Kubernetes context" {
  run grep -nE 'name: context|env: K8S_CONTEXT' \
    "${REPO_ROOT}/aqsh-tasks/tasks-mariadb.yaml" \
    "${REPO_ROOT}/aqsh-tasks/tasks-mongodb.yaml"
  [ "$status" -ne 0 ]
}

@test "Kubernetes library retains context support for local development" {
  run grep -nF 'K8S_CONTEXT="${K8S_CONTEXT:-}"' \
    "${REPO_ROOT}/aqsh-tasks/lib/k8s.sh"
  [ "$status" -eq 0 ]
}
