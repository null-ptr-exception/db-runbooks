#!/usr/bin/env bash
# preflight.sh — verify (and auto-install) all host-side tools required by setup.sh / test.sh
set -euo pipefail

KUBECTL_VERSION="v1.30.0"
PASS=0
FAIL=0

_ok()   { echo "  [OK]  $*"; PASS=$((PASS+1)); }
_fix()  { echo "  [FIX] $*"; }
_err()  { echo "  [ERR] $*"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_arch() {
  case "$(uname -m)" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    *)       echo "$(uname -m)" ;;
  esac
}

_APT_UPDATED=0
_install_apt() {
  local pkgs=("$@")
  if [[ "$_APT_UPDATED" -eq 0 ]]; then
    _fix "Updating apt package index"
    DEBIAN_FRONTEND=noninteractive sudo apt-get update -qq >/dev/null 2>&1
    _APT_UPDATED=1
  fi
  _fix "Installing via apt-get: ${pkgs[*]}"
  DEBIAN_FRONTEND=noninteractive sudo apt-get install -y --no-install-recommends "${pkgs[@]}" >/dev/null 2>&1
}

_download_binary() {
  local name="$1"
  local url="$2"
  local dest="${3:-/usr/local/bin/$name}"
  _fix "Downloading $name → $dest"
  sudo curl -fsSLo "$dest" "$url"
  sudo chmod +x "$dest"
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

check_docker() {
  echo "=== docker ==="
  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    _ok "$(docker --version)"
  else
    _err "docker not found or Docker daemon not running — install manually: https://docs.docker.com/engine/install/"
  fi
}

check_kind() {
  echo "=== kind ==="
  if command -v kind &>/dev/null; then
    _ok "$(kind --version)"
    return
  fi
  local arch; arch=$(_arch)
  local url
  url="https://github.com/kubernetes-sigs/kind/releases/latest/download/kind-linux-${arch}"
  _install_apt curl
  _download_binary kind "$url"
  _ok "$(kind --version)"
}

check_kubectl() {
  echo "=== kubectl ==="
  if command -v kubectl &>/dev/null && kubectl version --client --output=yaml 2>/dev/null | grep -q "gitVersion"; then
    _ok "$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
    return
  fi
  local arch; arch=$(_arch)
  local url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl"
  local sha_url="${url}.sha256"
  _fix "Installing kubectl ${KUBECTL_VERSION}"
  sudo curl -fsSLo /usr/local/bin/kubectl "$url"
  curl -fsSLo /tmp/kubectl.sha256 "$sha_url"
  echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c - >/dev/null
  rm -f /tmp/kubectl.sha256
  sudo chmod +x /usr/local/bin/kubectl
  _ok "$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
}

check_helm() {
  echo "=== helm ==="
  if command -v helm &>/dev/null; then
    _ok "$(helm version --short)"
    return
  fi
  _fix "Installing helm via get.helm.sh"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null 2>&1
  _ok "$(helm version --short)"
}

check_skaffold() {
  echo "=== skaffold ==="
  if command -v skaffold &>/dev/null; then
    _ok "$(skaffold version)"
    return
  fi
  local arch; arch=$(_arch)
  local latest
  latest=$(curl -fsSL "https://storage.googleapis.com/skaffold/releases/latest/VERSION")
  local url="https://storage.googleapis.com/skaffold/releases/${latest}/skaffold-linux-${arch}"
  _download_binary skaffold "$url"
  _ok "$(skaffold version)"
}

check_apt_tools() {
  echo "=== apt tools (jq, curl, openssl, python3, envsubst) ==="
  local missing=()
  command -v jq       &>/dev/null || missing+=(jq)
  command -v curl     &>/dev/null || missing+=(curl)
  command -v openssl  &>/dev/null || missing+=(openssl)
  command -v python3  &>/dev/null || missing+=(python3)
  command -v envsubst &>/dev/null || missing+=(gettext-base)

  if [ ${#missing[@]} -gt 0 ]; then
    _install_apt "${missing[@]}"
  fi

  _ok "jq      $(jq --version)"
  _ok "curl    $(curl --version | head -1)"
  _ok "openssl $(openssl version)"
  _ok "python3 $(python3 --version)"
  _ok "envsubst $(envsubst --version 2>&1 | head -1)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "======================================="
echo " Preflight: checking required tools"
echo "======================================="
echo ""

check_docker
echo ""
check_kubectl
echo ""
check_kind
echo ""
check_helm
echo ""
check_skaffold
echo ""
check_apt_tools

echo ""
echo "======================================="
if [ "$FAIL" -eq 0 ]; then
  echo " Preflight PASSED ($PASS checks)"
else
  echo " Preflight FAILED ($FAIL failed, $PASS passed)"
  exit 1
fi
echo "======================================="
