#!/usr/bin/env bash

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  "${ROOT_DIR}/scripts/setup-clusters.sh"
  "${ROOT_DIR}/scripts/deploy-infra.sh"
}

teardown_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  "${ROOT_DIR}/scripts/teardown.sh"
}
