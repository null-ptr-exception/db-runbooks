#!/usr/bin/env bats

setup() {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

runtime_tools_include_skaffold() {
  awk '
    BEGIN { IGNORECASE = 1 }
    /^[[:space:]]*RUNTIME_MISE_TOOLS[+]?=/ { in_tools = 1 }
    in_tools && /skaffold/ { found = 1 }
    in_tools && /\)/ { in_tools = 0 }
    END { exit found ? 0 : 1 }
  ' "$1"
}

@test "active toolchain excludes unused Skaffold binary" {
  run grep -Eq '^[[:space:]]*skaffold[[:space:]]*=' "${ROOT_DIR}/.mise.toml"
  [ "$status" -ne 0 ]

  run runtime_tools_include_skaffold "${ROOT_DIR}/scripts/preflight.sh"
  [ "$status" -ne 0 ]
}

@test "toolchain guard detects append and multiline Skaffold entries" {
  local fixture="${BATS_TEST_TMPDIR}/preflight.sh"

  printf '%s\n' 'RUNTIME_MISE_TOOLS+=(skaffold)' > "$fixture"
  run runtime_tools_include_skaffold "$fixture"
  [ "$status" -eq 0 ]

  printf '%s\n' \
    'RUNTIME_MISE_TOOLS+=(' \
    '  skaffold' \
    ')' > "$fixture"
  run runtime_tools_include_skaffold "$fixture"
  [ "$status" -eq 0 ]
}

@test "preflight purges Skaffold left on self-hosted runners" {
  run grep -F 'mise uninstall --all --yes skaffold' \
    "${ROOT_DIR}/scripts/preflight.sh"
  [ "$status" -eq 0 ]

  run grep -F '_remove_obsolete_binary "$LOCAL_BIN/skaffold"' \
    "${ROOT_DIR}/scripts/preflight.sh"
  [ "$status" -eq 0 ]

  run grep -F '_remove_obsolete_binary "/app/kin/bin/skaffold"' \
    "${ROOT_DIR}/scripts/preflight.sh"
  [ "$status" -eq 0 ]
}

@test "removed Skaffold output is not ignored" {
  run grep -Fx '.skaffold-rendered/' "${ROOT_DIR}/.gitignore"
  [ "$status" -ne 0 ]
}
