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

@test "nginx HTTP gateway is deployed in cluster-dbs" {
  run kubectl --context "${CLUSTER_DBS_CONTEXT}" -n db-ops get deployment nginx-proxy
  assert_success
}

@test "nginx HTTP gateway service has port 30083" {
  run kubectl --context "${CLUSTER_DBS_CONTEXT}" -n db-ops \
    get svc peer-db-proxy -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}'
  assert_success
  assert_output "30083"
}

@test "nginx HTTP gateway healthz endpoint works" {
  run curl -sf "http://${CLUSTER_DBS_IP}:30083/healthz"
  assert_success
  assert_output "ok"
}

@test "nginx can proxy to MinIO API via /minio/ path" {
  run curl -sf "http://${CLUSTER_DBS_IP}:30083/minio/health/live"
  assert_success
}

@test "nginx proxy preserves MinIO health check response" {
  # Direct access
  direct_response=$(curl -s "http://${CLUSTER_MINIO_IP}:30092/minio/health/live")

  # Via nginx proxy
  proxy_response=$(curl -s "http://${CLUSTER_DBS_IP}:30083/minio/health/live")

  # Both should be identical
  [[ "$direct_response" == "$proxy_response" ]]
}

@test "nginx ConfigMap contains MinIO upstream" {
  run kubectl --context "${CLUSTER_DBS_CONTEXT}" -n db-ops \
    get configmap nginx-proxy-config -o yaml
  assert_success
  assert_output --partial "upstream minio"
  assert_output --partial "CLUSTER_MINIO_IP"
}

@test "nginx deployment has HTTP containerPort 80" {
  run kubectl --context "${CLUSTER_DBS_CONTEXT}" -n db-ops \
    get deployment nginx-proxy -o jsonpath='{.spec.template.spec.containers[0].ports[?(@.name=="http")].containerPort}'
  assert_success
  assert_output "80"
}

@test "nginx readinessProbe uses HTTP /healthz" {
  run kubectl --context "${CLUSTER_DBS_CONTEXT}" -n db-ops \
    get deployment nginx-proxy -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}'
  assert_success
  assert_output "/healthz"
}
