#!/usr/bin/env bash
# preflight.sh — verify and auto-install all tools required by setup.sh / test.sh
set -euo pipefail

LOCAL_BIN="$HOME/.local/bin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
NEED_PATH=0

_ok()  { echo "  [OK]  $*"; }
_fix() { echo "  [FIX] $*"; }
_err() { echo "  [ERR] $*"; }

_arch() {
  case "$(uname -m)" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    *)       echo "$(uname -m)" ;;
  esac
}

_os() {
  case "$(uname -s)" in
    Linux)  echo "linux" ;;
    Darwin) echo "darwin" ;;
    *)      _err "unsupported OS: $(uname -s)"; exit 1 ;;
  esac
}

_ensure_local_bin() {
  mkdir -p "$LOCAL_BIN"
  if [[ ":$PATH:" != *":$LOCAL_BIN:"* ]]; then
    export PATH="$LOCAL_BIN:$PATH"
    NEED_PATH=1
  fi
}

echo "======================================="
echo " Preflight: checking required tools"
echo "======================================="

# 0. Required system tools
echo ""
echo "=== system tools ==="
MISSING=0
for tool in curl git jq openssl python3 envsubst docker; do
  if command -v "$tool" &>/dev/null; then
    _ok "$tool"
  else
    _err "$tool not found"
    MISSING=1
  fi
done
if ! docker info &>/dev/null 2>&1; then
  _err "docker daemon not running"
  MISSING=1
fi
if [ "$MISSING" -eq 1 ]; then
  exit 1
fi

# 2. Kind — download binary to ~/.local/bin
echo ""
echo "=== kind ==="
if command -v kind &>/dev/null; then
  _ok "$(kind --version)"
else
  _ensure_local_bin
  _fix "Installing kind v0.31.0 to $LOCAL_BIN..."
  curl -fsSL -o "$LOCAL_BIN/kind" "https://kind.sigs.k8s.io/dl/v0.31.0/kind-$(_os)-$(_arch)"
  chmod +x "$LOCAL_BIN/kind"
  _ok "$(kind --version)"
fi

# 3. mise — install via official installer
echo ""
echo "=== mise ==="
if command -v mise &>/dev/null; then
  _ok "$(mise --version)"
else
  _fix "Installing mise..."
  curl -fsSL https://mise.jdx.dev/install.sh | sh
  _ensure_local_bin
  _ok "$(mise --version)"
fi

# 4. mise tools (bats, kubectl, helm, skaffold) — from .mise.toml
echo ""
echo "=== mise tools ==="
mise trust "$ROOT_DIR" 2>/dev/null || true
mise install
mise ls --current kubectl helm skaffold bats

# 5. bats helpers (bats-support, bats-assert, bats-mock)
echo ""
echo "=== bats helpers ==="
HELPER_DIR="${ROOT_DIR}/tests/test_helper"
BATS_SUPPORT_REF="v0.3.0"  # 64e7436962affbe15974d181173c37e1fac70063
BATS_ASSERT_REF="v2.1.0"   # 22612dc4c4332dac0e40491f1dc2ec93c59773f7
BATS_MOCK_REF="v1"         # 24f995f9618b493d0a2db148bea272b3c9133826

for lib_ref in "bats-support:bats-core:${BATS_SUPPORT_REF}" "bats-assert:bats-core:${BATS_ASSERT_REF}" "bats-mock:jasonkarns:${BATS_MOCK_REF}"; do
  IFS=: read -r lib org ref <<< "$lib_ref"
  if [ ! -d "${HELPER_DIR}/${lib}" ]; then
    _fix "Cloning ${lib} (${ref})..."
    git clone --depth 1 --branch "$ref" "https://github.com/${org}/${lib}.git" "${HELPER_DIR}/${lib}"
  fi
done
_ok "bats-support + bats-assert + bats-mock installed"

# Done
echo ""
echo "======================================="
echo " Preflight PASSED"
echo "======================================="

if [ "$NEED_PATH" -eq 1 ]; then
  echo ""
  echo "ERROR: ~/.local/bin is not in your PATH."
  echo "Add it by running:"
  echo ""
  echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
  echo "  source ~/.bashrc"
  echo ""
  echo "Then re-run this script."
  exit 1
fi
