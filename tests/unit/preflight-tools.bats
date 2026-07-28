#!/usr/bin/env bats

setup() {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

@test "active toolchain excludes unused Skaffold binary" {
  run grep -Eq '^[[:space:]]*skaffold[[:space:]]*=' "${ROOT_DIR}/.mise.toml"
  [ "$status" -ne 0 ]

  run grep -E '^[[:space:]]*RUNTIME_MISE_TOOLS=.*skaffold' \
    "${ROOT_DIR}/scripts/preflight.sh"
  [ "$status" -ne 0 ]
}
