#!/usr/bin/env bash
# =============================================================================
# lib/custom.sh
# Sanity-check result counters and output helpers (_sc_*).
#
# Provides the PASS/WARN/FAIL accounting and formatted output used by all
# layered sanity-check scripts (check_k8s_layer, check_mongo_internals …).
#
# Usage:
#   source lib/custom.sh
#   _sc_pass  "message"
#   _sc_warn  "message" ["detail"]
#   _sc_fail  "message" ["detail"]
#   _sc_section "Section Title"
#   _sc_summary
# =============================================================================

[[ -n "${_CUSTOM_LIB_LOADED:-}" ]] && return 0
_CUSTOM_LIB_LOADED=1

# ── Result counters ───────────────────────────────────────────────────────────
SC_PASS=0
SC_WARN=0
SC_FAIL=0

# ── Output helpers ────────────────────────────────────────────────────────────
_sc_pass() {
  SC_PASS=$(( SC_PASS + 1 ))
  printf '  \033[0;32m[PASS]\033[0m  %s\n' "$1"
}

_sc_warn() {
  SC_WARN=$(( SC_WARN + 1 ))
  printf '  \033[0;33m[WARN]\033[0m  %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '           %s\n' "$2"
}

_sc_fail() {
  SC_FAIL=$(( SC_FAIL + 1 ))
  printf '  \033[0;31m[FAIL]\033[0m  %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '           %s\n' "$2"
}

_sc_section() {
  printf '\n\033[1;34m── %s ──────────────────────────────────────────────────────────\033[0m\n' "$1"
}

_sc_summary() {
  local total=$(( SC_PASS + SC_WARN + SC_FAIL ))
  printf '\n\033[1m═══ Sanity Check Summary ═══════════════════════════════════════\033[0m\n'
  printf '  PASS : %d\n' "$SC_PASS"
  printf '  WARN : %d\n' "$SC_WARN"
  printf '  FAIL : %d\n' "$SC_FAIL"
  printf '  TOTAL: %d checks\n' "$total"
  if (( SC_FAIL > 0 )); then
    printf '\n  \033[0;31mResult: FAILED (%d critical issue(s))\033[0m\n' "$SC_FAIL"
  elif (( SC_WARN > 0 )); then
    printf '\n  \033[0;33mResult: WARNING (%d warning(s))\033[0m\n' "$SC_WARN"
  else
    printf '\n  \033[0;32mResult: HEALTHY\033[0m\n'
  fi
}
