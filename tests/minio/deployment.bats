#!/usr/bin/env bats

setup_file() {
  load '../test_helper/common_setup'
  common_setup

  if [[ "${ENABLE_MINIO:-false}" != "true" ]]; then
    skip "MinIO not enabled (ENABLE_MINIO!=true)"
  fi
}

setup() {
  load '../test_helper/common_setup'
}

@test "cluster-minio exists" {
  run kind get clusters
  assert_success
  assert_output --partial "cluster-minio"
}

@test "MinIO namespace exists" {
  kubectl --context kind-cluster-minio get namespace minio
}

@test "MinIO deployment is ready" {
  kubectl --context kind-cluster-minio -n minio \
    rollout status deployment/minio --timeout=60s
}

@test "MinIO pod is running" {
  run kubectl --context kind-cluster-minio -n minio get pod -l app=minio
  assert_success
  assert_output --partial "Running"
}

@test "MinIO service exists with NodePort" {
  run kubectl --context kind-cluster-minio -n minio get svc minio -o jsonpath='{.spec.type}'
  assert_success
  assert_output "NodePort"

  run kubectl --context kind-cluster-minio -n minio get svc minio -o jsonpath='{.spec.ports[?(@.name=="api")].nodePort}'
  assert_success
  assert_output "30092"

  run kubectl --context kind-cluster-minio -n minio get svc minio -o jsonpath='{.spec.ports[?(@.name=="console")].nodePort}'
  assert_success
  assert_output "30093"
}

@test "MinIO API accessible via NodePort" {
  run curl -sf "http://${CLUSTER_MINIO_IP}:30092/minio/health/live"
  assert_success
}

@test "MinIO Console accessible via NodePort" {
  run curl -sf -o /dev/null -w "%{http_code}" "http://${CLUSTER_MINIO_IP}:30093/"
  assert_success
  assert_output "200"
}

@test "MinIO PVC is bound" {
  run kubectl --context kind-cluster-minio -n minio get pvc minio-data -o jsonpath='{.status.phase}'
  assert_success
  assert_output "Bound"
}
