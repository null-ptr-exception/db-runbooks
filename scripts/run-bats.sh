#!/usr/bin/env bash
set -euo pipefail

if command -v mise >/dev/null 2>&1; then
  bats_root="$(mise where bats 2>/dev/null || true)"
  if [[ -n "$bats_root" && -d "$bats_root" ]]; then
    bats_bin="$(find "$bats_root" -type f -path '*/bin/bats' -print -quit)"
    bats_core_dir="$(find "$bats_root" -type d -path '*/libexec/bats-core' -print -quit)"
    if [[ -n "$bats_bin" && -x "$bats_bin" && -n "$bats_core_dir" ]]; then
      export PATH="$bats_core_dir:$PATH"
      exec "$bats_bin" "$@"
    fi
  fi
fi

exec bats "$@"
