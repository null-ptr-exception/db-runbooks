setup_file() {
  load '../test_helper/common_setup'
  common_setup
}

setup() {
  load '../test_helper/common_setup'
}

@test "fedauth health check returns 200" {
  run kexec "curl -s -o /dev/null -w '%{http_code}' '${FEDAUTH_URL}/health'"
  assert_output "200"
}

@test "unauthenticated request to aqsh-mariadb returns 401" {
  run kexec "curl -s -o /dev/null -w '%{http_code}' '${MARIADB_AQSH_URL}/health'"
  assert_output "401"
}

@test "unauthenticated request to aqsh-mongodb returns 401" {
  run kexec "curl -s -o /dev/null -w '%{http_code}' '${MONGODB_AQSH_URL}/health'"
  assert_output "401"
}
