#!/usr/bin/env bash
set -euo pipefail
TARGET="$(dirname "$0")/../tests/test_helper"
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
for lib in bats-support bats-assert; do
  if [ ! -d "${TARGET}/${lib}" ]; then
    git clone --depth 1 "https://github.com/bats-core/${lib}.git" "${TARGET}/${lib}"
  fi
done
