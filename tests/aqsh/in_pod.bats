setup_file() {
  load 'test_helper'
  aqsh_suite_setup
}

setup() {
  load 'test_helper'
}

@test "in-pod request to aqsh-mariadb via projected token returns 202" {
  run kubectl --context "$CTX_B" -n app-a exec "$TEST_POD" -- \
    sh -c 'curl -s -o /dev/null -w "%{http_code}" \
      -X POST "http://aqsh-mariadb.kind-a.localhost:38001/tasks/common%2Fhello" \
      -H "Authorization: Bearer $(cat /var/run/secrets/tokens/token)" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"from-pod\"}"'
  assert_output "202"
}

@test "in-pod request to aqsh-mongodb via projected token returns 202" {
  run kubectl --context "$CTX_B" -n app-a exec "$TEST_POD" -- \
    sh -c 'curl -s -o /dev/null -w "%{http_code}" \
      -X POST "http://aqsh-mongodb.kind-a.localhost:38001/tasks/common%2Fhello" \
      -H "Authorization: Bearer $(cat /var/run/secrets/tokens/token)" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"from-pod\"}"'
  assert_output "202"
}
