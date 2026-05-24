setup_file() {
  load '../test_helper/common_setup'
  common_setup

  # Wait for test-client pod to be ready
  if ! kubectl --context kind-cluster-apps -n app-a wait \
    --for=condition=Ready pod -l app=test-client --timeout=120s >/dev/null 2>&1; then
    echo "test-client pod not ready within 120s" >&2
    return 1
  fi

  TEST_POD=$(kubectl --context kind-cluster-apps -n app-a \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  export TEST_POD
}

setup() {
  load '../test_helper/common_setup'
}

@test "in-pod request to aqsh-mariadb returns 202" {
  run kubectl --context kind-cluster-apps -n app-a exec "$TEST_POD" -- \
    sh -c 'curl -s -o /dev/null -w "%{http_code}" \
      -X POST "http://'"${CLUSTER_DBS_IP}"':30081/tasks/common%2Fhello" \
      -H "Authorization: Bearer $(cat /var/run/secrets/tokens/token)" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"from-pod\"}"'
  assert_output "202"
}

@test "in-pod request to aqsh-mongodb returns 202" {
  run kubectl --context kind-cluster-apps -n app-a exec "$TEST_POD" -- \
    sh -c 'curl -s -o /dev/null -w "%{http_code}" \
      -X POST "http://'"${CLUSTER_DBS_IP}"':30082/tasks/common%2Fhello" \
      -H "Authorization: Bearer $(cat /var/run/secrets/tokens/token)" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"from-pod\"}"'
  assert_output "202"
}
