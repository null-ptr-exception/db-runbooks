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
for tool in curl git; do
  if ! command -v "$tool" &>/dev/null; then
    _err "$tool not found — please install it first"
    exit 1
  fi
done

# 1. Docker — check only
echo ""
echo "=== docker ==="
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  _ok "$(docker --version)"
else
  _err "docker not found or daemon not running"
  echo "       Install: https://docs.docker.com/engine/install/"
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
for lib in bats-support bats-assert; do
  if [ ! -d "${HELPER_DIR}/${lib}" ]; then
    _fix "Cloning ${lib}..."
    git clone --depth 1 "https://github.com/bats-core/${lib}.git" "${HELPER_DIR}/${lib}"
  fi
done
if [ ! -d "${HELPER_DIR}/bats-mock" ]; then
  _fix "Cloning bats-mock..."
  git clone --depth 1 --branch v1 "https://github.com/jasonkarns/bats-mock.git" "${HELPER_DIR}/bats-mock"
fi
_ok "bats-support + bats-assert + bats-mock installed"

# Done
echo ""
echo "======================================="
echo " Preflight PASSED"
echo "======================================="

if [ "$NEED_PATH" -eq 1 ]; then
  echo ""
  echo "NOTE: ~/.local/bin is not in your PATH."
  echo "Add it by running:"
  echo ""
  echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
  echo "  source ~/.bashrc"
fi
