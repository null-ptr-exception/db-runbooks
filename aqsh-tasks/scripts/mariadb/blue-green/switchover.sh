#!/usr/bin/env bash
set -euo pipefail

# blue-green/switchover orchestrator
#
# Runs on the BLUE cluster's AQSH and performs the whole switchover as one task:
#   guardrails (read-only) -> maintenance Blue -> demote Blue -> promote Green
#   -> verify Green -> rollback Blue if anything in the execute phase fails.
#
# Local (Blue) steps reuse the granular task scripts in this directory.
# Green steps are driven over HTTP against the peer AQSH (PEER_AQSH_URL); the
# kube single-cluster boundary is preserved - this task never runs kubectl
# against the Green cluster.

LIB_DIR="${LIB_DIR:-/tasks/lib}"
if [[ ! -d "$LIB_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
fi
BG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=aqsh-tasks/lib/mariadb-blue-green.sh
source "${LIB_DIR}/mariadb-blue-green.sh"

OP="blue-green/switchover"

BLUE_NAME="${BLUE_NAME:?BLUE_NAME is required}"
GREEN_NAME="${GREEN_NAME:?GREEN_NAME is required}"
GREEN_NAMESPACE="${GREEN_NAMESPACE:-$BG_NAMESPACE}"
PEER_AQSH_URL="${PEER_AQSH_URL:?PEER_AQSH_URL is required}"
PEER_TOKEN="${PEER_TOKEN:?PEER_TOKEN is required}"
EXPECTED_BLUE_VERSION="${EXPECTED_BLUE_VERSION:-}"
EXPECTED_GREEN_VERSION="${EXPECTED_GREEN_VERSION:-}"
LAG_THRESHOLD="${LAG_THRESHOLD:-0}"
SKIP_WRITE_PROBE="${SKIP_WRITE_PROBE:-false}"
PEER_TIMEOUT="${PEER_TIMEOUT:-540}"

# Local target is Blue.
BG_MDB="$BLUE_NAME"
bg_init_target
bg_require_confirm "$OP"

bg_validate_dns_label "blue_name" "$BLUE_NAME" "$OP"
bg_validate_dns_label "green_name" "$GREEN_NAME" "$OP"
bg_validate_dns_label "green_namespace" "$GREEN_NAMESPACE" "$OP"
bg_validate_url "peer_aqsh_url" "$PEER_AQSH_URL" "$OP"
bg_validate_uint "lag_threshold" "$LAG_THRESHOLD" "$OP"

# State flags for rollback.
blue_maintenance=0
blue_demoted=0
green_promoted=0

bg_rollback() {
  # Best-effort restoration of Blue as primary. Each step tolerates failure so
  # the rollback always attempts every undo it can.
  if (( green_promoted )); then
    bg_peer_call_task "$OP" "$PEER_AQSH_URL" "$PEER_TOKEN" "blue-green/set-primary" \
      "$(jq -n --arg ns "$GREEN_NAMESPACE" --arg mdb "$GREEN_NAME" --arg primary "$BLUE_NAME" \
        '{namespace: $ns, mdb: $mdb, primary: $primary, confirm: "true"}')" "$PEER_TIMEOUT" >/dev/null || true
  fi
  if (( blue_demoted )); then
    _kubectl patch "$BG_RESOURCE" "$BLUE_NAME" --type merge \
      -p "{\"spec\":{\"multiCluster\":{\"primary\":$(bg_json_string "$BLUE_NAME")}}}" >/dev/null 2>&1 || true
  fi
  if (( blue_maintenance )); then
    bg_set_maintenance false >/dev/null 2>&1 || true
  fi
}

fail_with_rollback() {
  local message="$1" detail="$2"
  bg_rollback
  bg_fail "$OP" "$message (rolled back Blue)" "$detail"
}

# ---------------------------------------------------------------------------
# Phase 1: guardrails (read-only; no rollback needed)
# ---------------------------------------------------------------------------

# Green must be a healthy, caught-up replica of Blue before we switch.
green_validate="$(bg_peer_call_task "$OP" "$PEER_AQSH_URL" "$PEER_TOKEN" "blue-green/validate" \
  "$(jq -n --arg ns "$GREEN_NAMESPACE" --arg mdb "$GREEN_NAME" --arg primary "$BLUE_NAME" \
    --arg version "$EXPECTED_GREEN_VERSION" --arg lag "$LAG_THRESHOLD" \
    '{namespace: $ns, mdb: $mdb, expected_primary: $primary, expected_version: $version, check_replication: "true", lag_threshold: $lag}')" \
  "$PEER_TIMEOUT")" \
  || bg_fail "$OP" "guardrail failed: green is not a healthy caught-up replica" "$BG_PEER_ERR"

# Blue must currently be the primary.
blue_validate="$(bg_local_step "$BG_DIR/validate.sh" \
  "DB_NAMESPACE=$BG_NAMESPACE" "MARIADB_NAME=$BLUE_NAME" \
  "EXPECTED_PRIMARY=$BLUE_NAME" "EXPECTED_VERSION=$EXPECTED_BLUE_VERSION" \
  "LAG_THRESHOLD=$LAG_THRESHOLD")" \
  || bg_fail "$OP" "guardrail failed: blue did not validate as current primary" "$BG_LOCAL_ERR"

# Prove writes flow through the current primary (and therefore replication is live).
if [[ "$SKIP_WRITE_PROBE" != "true" ]]; then
  bg_local_step "$BG_DIR/write-probe.sh" \
    "DB_NAMESPACE=$BG_NAMESPACE" "MARIADB_NAME=$BLUE_NAME" "CONFIRM=true" \
    "PROBE_NOTE=aqsh-switchover-preflight" >/dev/null \
    || bg_fail "$OP" "guardrail failed: pre-switchover write probe on blue failed" "$BG_LOCAL_ERR"
fi

# ---------------------------------------------------------------------------
# Phase 2: execute (state changes; roll back on any failure)
# ---------------------------------------------------------------------------

bg_set_maintenance true >/dev/null \
  || fail_with_rollback "failed to put blue into maintenance" '{"step":"maintenance"}'
blue_maintenance=1

bg_local_step "$BG_DIR/set-primary.sh" \
  "DB_NAMESPACE=$BG_NAMESPACE" "MARIADB_NAME=$BLUE_NAME" \
  "BLUE_GREEN_PRIMARY=$GREEN_NAME" "CONFIRM=true" >/dev/null \
  || fail_with_rollback "failed to demote blue" "$BG_LOCAL_ERR"
blue_demoted=1

bg_peer_call_task "$OP" "$PEER_AQSH_URL" "$PEER_TOKEN" "blue-green/set-primary" \
  "$(jq -n --arg ns "$GREEN_NAMESPACE" --arg mdb "$GREEN_NAME" --arg primary "$GREEN_NAME" \
    '{namespace: $ns, mdb: $mdb, primary: $primary, confirm: "true"}')" "$PEER_TIMEOUT" >/dev/null \
  || fail_with_rollback "failed to promote green" "$BG_PEER_ERR"
green_promoted=1

# ---------------------------------------------------------------------------
# Phase 3: verify the new primary
# ---------------------------------------------------------------------------

green_post="$(bg_peer_call_task "$OP" "$PEER_AQSH_URL" "$PEER_TOKEN" "blue-green/validate" \
  "$(jq -n --arg ns "$GREEN_NAMESPACE" --arg mdb "$GREEN_NAME" --arg primary "$GREEN_NAME" \
    --arg version "$EXPECTED_GREEN_VERSION" \
    '{namespace: $ns, mdb: $mdb, expected_primary: $primary, expected_version: $version, check_replication: "false"}')" \
  "$PEER_TIMEOUT")" \
  || fail_with_rollback "post-switchover validation of green failed" "$BG_PEER_ERR"

probe_result="{}"
if [[ "$SKIP_WRITE_PROBE" != "true" ]]; then
  probe_result="$(bg_peer_call_task "$OP" "$PEER_AQSH_URL" "$PEER_TOKEN" "blue-green/write-probe" \
    "$(jq -n --arg ns "$GREEN_NAMESPACE" --arg mdb "$GREEN_NAME" \
      '{namespace: $ns, mdb: $mdb, confirm: "true", note: "aqsh-switchover-postflight"}')" \
    "$PEER_TIMEOUT")" \
    || fail_with_rollback "green did not accept writes after promotion" "$BG_PEER_ERR"
fi

data="$(jq -n \
  --arg blue "$BLUE_NAME" \
  --arg green "$GREEN_NAME" \
  --arg blueNamespace "$BG_NAMESPACE" \
  --arg greenNamespace "$GREEN_NAMESPACE" \
  --argjson guardrails "$(jq -n --argjson green "$green_validate" --argjson blue "$blue_validate" '{green: $green, blue: $blue}')" \
  --argjson greenAfter "$green_post" \
  --argjson writeProbe "$probe_result" \
  '{
    blue: $blue,
    green: $green,
    blueNamespace: $blueNamespace,
    greenNamespace: $greenNamespace,
    newPrimary: $green,
    guardrails: $guardrails,
    greenAfter: $greenAfter,
    writeProbe: $writeProbe
  }')"

bg_write_result "$(response_ok "$OP" "blue/green switchover completed; green is now primary" "$data")"
