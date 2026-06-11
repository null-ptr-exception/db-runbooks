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

INTERNAL_STEP="${INTERNAL_STEP:-}"
BLUE_NAME="${BLUE_NAME:-}"
GREEN_NAME="${GREEN_NAME:-}"
GREEN_NAMESPACE="${GREEN_NAMESPACE:-$BG_NAMESPACE}"
PEER_AQSH_URL="${PEER_AQSH_URL:-}"
PEER_TOKEN="${PEER_TOKEN:-}"
EXPECTED_BLUE_VERSION="${EXPECTED_BLUE_VERSION:-}"
EXPECTED_GREEN_VERSION="${EXPECTED_GREEN_VERSION:-}"
EXPECTED_PRIMARY="${EXPECTED_PRIMARY:-}"
BLUE_GREEN_PRIMARY="${BLUE_GREEN_PRIMARY:-}"
LAG_THRESHOLD="${LAG_THRESHOLD:-0}"
CHECK_REPLICATION="${CHECK_REPLICATION:-true}"
SKIP_WRITE_PROBE="${SKIP_WRITE_PROBE:-false}"
PEER_TIMEOUT="${PEER_TIMEOUT:-540}"
# Overall bound on the execute phase (the write-outage window) up to and
# including Green's promotion, mirroring the AWS RDS switchover timeout
# (default 300s there as well). Exceeding it before promotion rolls Blue back.
SWITCHOVER_TIMEOUT="${SWITCHOVER_TIMEOUT:-300}"
# Guardrail: refuse to start while a statement has been running on Blue for at
# least this many seconds — long writes/DDL inflate replica lag and stretch
# the write-outage window. 0 disables the check.
LONG_TX_THRESHOLD="${LONG_TX_THRESHOLD:-60}"
# Guardrail: expect read_only=1 on Green before switching ("no writes on
# green"). The orchestrator turns this into the peer validate's expect_read_only.
EXPECT_GREEN_READ_ONLY="${EXPECT_GREEN_READ_ONLY:-}"
# Internal gtid-wait step inputs (peer orchestration only).
GTID_TARGET="${GTID_TARGET:-}"
GTID_TIMEOUT="${GTID_TIMEOUT:-0}"
PROBE_DATABASE="${PROBE_DATABASE:-bgtest}"
PROBE_TABLE="${PROBE_TABLE:-events}"
PROBE_ID="${PROBE_ID:-1}"
PROBE_NOTE="${PROBE_NOTE:-aqsh-write-probe}"

case "$INTERNAL_STEP" in
  validate)
    result="$(bg_local_step "$BG_DIR/validate.sh" \
      "DB_NAMESPACE=$BG_NAMESPACE" "MARIADB_NAME=$GREEN_NAME" \
      "EXPECTED_PRIMARY=$EXPECTED_PRIMARY" "EXPECTED_VERSION=$EXPECTED_GREEN_VERSION" \
      "CHECK_REPLICATION=$CHECK_REPLICATION" "LAG_THRESHOLD=$LAG_THRESHOLD" \
      "EXPECT_READ_ONLY=$EXPECT_GREEN_READ_ONLY")" \
      || bg_fail "$OP" "internal validation failed" "$BG_LOCAL_ERR"
    bg_write_result "$(response_ok "$OP" "internal validation completed" "$result")"
    exit 0
    ;;
  gtid-wait)
    # Block until this cluster's replica has applied the given Blue GTID, or
    # the timeout expires. Used by the orchestrator after Blue stops writes so
    # promotion never happens before Green is fully caught up.
    bg_validate_gtid "gtid_target" "$GTID_TARGET" "$OP"
    bg_validate_uint "gtid_timeout" "$GTID_TIMEOUT" "$OP"
    BG_MDB="$GREEN_NAME"
    bg_init_target
    wait_rc="$(bg_target_sql "SELECT MASTER_GTID_WAIT($(bg_sql_string "$GTID_TARGET"), ${GTID_TIMEOUT})")" \
      || bg_fail "$OP" "internal gtid wait could not run on the replica" \
        "$(jq -n --arg gtid "$GTID_TARGET" '{gtid: $gtid}')"
    if [[ "$wait_rc" != "0" ]]; then
      bg_fail "$OP" "replica did not reach the blue GTID within the timeout" \
        "$(jq -n --arg gtid "$GTID_TARGET" --arg result "$wait_rc" --argjson timeout "$GTID_TIMEOUT" \
          '{gtid: $gtid, result: $result, timeoutSeconds: $timeout}')"
    fi
    bg_write_result "$(response_ok "$OP" "internal gtid wait completed" \
      "$(jq -n --arg gtid "$GTID_TARGET" '{gtid: $gtid, result: "0"}')")"
    exit 0
    ;;
  set-primary)
    result="$(bg_local_step "$BG_DIR/set-primary.sh" \
      "DB_NAMESPACE=$BG_NAMESPACE" "MARIADB_NAME=$GREEN_NAME" \
      "BLUE_GREEN_PRIMARY=$BLUE_GREEN_PRIMARY" "CONFIRM=true")" \
      || bg_fail "$OP" "internal primary switch failed" "$BG_LOCAL_ERR"
    bg_write_result "$(response_ok "$OP" "internal primary switch completed" "$result")"
    exit 0
    ;;
  write-probe)
    result="$(bg_local_step "$BG_DIR/write-probe.sh" \
      "DB_NAMESPACE=$BG_NAMESPACE" "MARIADB_NAME=$GREEN_NAME" "CONFIRM=true" \
      "PROBE_DATABASE=$PROBE_DATABASE" "PROBE_TABLE=$PROBE_TABLE" \
      "PROBE_ID=$PROBE_ID" "PROBE_NOTE=$PROBE_NOTE")" \
      || bg_fail "$OP" "internal write probe failed" "$BG_LOCAL_ERR"
    bg_write_result "$(response_ok "$OP" "internal write probe completed" "$result")"
    exit 0
    ;;
  "")
    ;;
  *)
    bg_fail "$OP" "internal_step is not supported" "$(jq -n --arg internalStep "$INTERNAL_STEP" '{internalStep: $internalStep}')" 2
    ;;
esac

bg_required "blue_name" "$BLUE_NAME" "$OP"
bg_required "green_name" "$GREEN_NAME" "$OP"
bg_required "peer_aqsh_url" "$PEER_AQSH_URL" "$OP"
bg_required "peer_token" "$PEER_TOKEN" "$OP"

# Local target is Blue.
BG_MDB="$BLUE_NAME"
bg_init_target
bg_require_confirm "$OP"

bg_validate_dns_label "blue_name" "$BLUE_NAME" "$OP"
bg_validate_dns_label "green_name" "$GREEN_NAME" "$OP"
bg_validate_dns_label "green_namespace" "$GREEN_NAMESPACE" "$OP"
bg_validate_url "peer_aqsh_url" "$PEER_AQSH_URL" "$OP"
bg_validate_uint "lag_threshold" "$LAG_THRESHOLD" "$OP"
bg_validate_uint "switchover_timeout" "$SWITCHOVER_TIMEOUT" "$OP"
bg_validate_uint "long_tx_threshold" "$LONG_TX_THRESHOLD" "$OP"

# State flags for rollback.
blue_maintenance=0
blue_demoted=0
green_promoted=0

bg_rollback() {
  # Best-effort restoration of Blue as primary. Each step tolerates failure so
  # the rollback always attempts every undo it can.
  if (( green_promoted )); then
    bg_peer_call_task "$OP" "$PEER_AQSH_URL" "$PEER_TOKEN" "blue-green/switchover" \
      "$(jq -n --arg ns "$GREEN_NAMESPACE" --arg mdb "$GREEN_NAME" --arg blue "$BLUE_NAME" --arg primary "$BLUE_NAME" \
        '{namespace: $ns, green_name: $mdb, blue_name: $blue, primary: $primary, internal_step: "set-primary", confirm: "true"}')" "$PEER_TIMEOUT" >/dev/null || true
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

fail_after_promotion() {
  local message="$1" detail="$2"
  bg_fail "$OP" "$message (green remains primary; manual inspection required)" "$detail"
}

# ---------------------------------------------------------------------------
# Phase 1: guardrails (read-only; no rollback needed)
# ---------------------------------------------------------------------------

# Green must be a healthy, caught-up, read-only replica of Blue before we
# switch. expect_green_read_only is the AWS-style "no writes on green" check;
# pass "false" to skip it.
green_validate="$(bg_peer_call_task "$OP" "$PEER_AQSH_URL" "$PEER_TOKEN" "blue-green/switchover" \
  "$(jq -n --arg ns "$GREEN_NAMESPACE" --arg mdb "$GREEN_NAME" --arg blue "$BLUE_NAME" --arg primary "$BLUE_NAME" \
    --arg version "$EXPECTED_GREEN_VERSION" --arg lag "$LAG_THRESHOLD" \
    --arg ro "${EXPECT_GREEN_READ_ONLY:-true}" \
    '{namespace: $ns, green_name: $mdb, blue_name: $blue, expected_primary: $primary, expected_green_version: $version, check_replication: "true", lag_threshold: $lag, expect_green_read_only: $ro, internal_step: "validate"}')" \
  "$PEER_TIMEOUT")" \
  || bg_fail "$OP" "guardrail failed: green is not a healthy caught-up replica" "$BG_PEER_ERR"

# Blue must currently be the primary.
blue_validate="$(bg_local_step "$BG_DIR/validate.sh" \
  "DB_NAMESPACE=$BG_NAMESPACE" "MARIADB_NAME=$BLUE_NAME" \
  "EXPECTED_PRIMARY=$BLUE_NAME" "EXPECTED_VERSION=$EXPECTED_BLUE_VERSION" \
  "LAG_THRESHOLD=$LAG_THRESHOLD")" \
  || bg_fail "$OP" "guardrail failed: blue did not validate as current primary" "$BG_LOCAL_ERR"

# No long-running writes/DDL on Blue — they inflate replica lag and stretch the
# write-outage window (same guardrail AWS runs on the blue environment).
if (( LONG_TX_THRESHOLD > 0 )); then
  long_running="$(bg_long_running_count "$LONG_TX_THRESHOLD")" \
    || bg_fail "$OP" "guardrail failed: could not inspect long-running statements on blue" '{"step":"long-tx-check"}'
  if [[ "$long_running" != "0" ]]; then
    bg_fail "$OP" "guardrail failed: blue has statements running for >= ${LONG_TX_THRESHOLD}s; finish or kill them (or lower long_tx_threshold guardrail expectations) before switching over" \
      "$(jq -n --argjson count "$long_running" --argjson threshold "$LONG_TX_THRESHOLD" '{longRunningStatements: $count, thresholdSeconds: $threshold}')"
  fi
fi

# Prove writes flow through the current primary (and therefore replication is live).
if [[ "$SKIP_WRITE_PROBE" != "true" ]]; then
  bg_local_step "$BG_DIR/write-probe.sh" \
    "DB_NAMESPACE=$BG_NAMESPACE" "MARIADB_NAME=$BLUE_NAME" "CONFIRM=true" \
    "PROBE_NOTE=aqsh-switchover-preflight" >/dev/null \
    || bg_fail "$OP" "guardrail failed: pre-switchover write probe on blue failed" "$BG_LOCAL_ERR"
fi

# ---------------------------------------------------------------------------
# Phase 2: execute (state changes; roll back on any failure)
#
# The whole phase up to and including Green's promotion is bounded by
# SWITCHOVER_TIMEOUT (the write-outage window). Past promotion the switchover
# is effectively done, so post-verification is not subject to the deadline.
# ---------------------------------------------------------------------------

deadline=$(( SECONDS + SWITCHOVER_TIMEOUT ))

check_deadline() {
  local step="$1"
  (( SECONDS < deadline )) \
    || fail_with_rollback "switchover timeout (${SWITCHOVER_TIMEOUT}s) exceeded before ${step}" \
      "$(jq -n --arg step "$step" --argjson timeout "$SWITCHOVER_TIMEOUT" '{step: $step, timeoutSeconds: $timeout}')"
}

bg_set_maintenance true >/dev/null \
  || fail_with_rollback "failed to put blue into maintenance" '{"step":"maintenance"}'
blue_maintenance=1

# The operator applies the maintenance patch asynchronously — wait until
# read-only has actually taken effect before sampling the GTID, or writes could
# still land after the position we wait on.
until [[ "$(bg_target_sql 'SELECT @@read_only' || true)" == "1" ]]; do
  check_deadline "blue becoming read-only"
  sleep 2
done

# Writes are now stopped on Blue. Capture Blue's GTID position and wait for
# Green to apply everything up to it before changing any primary intent — the
# guardrail lag check ran BEFORE maintenance, so writes that landed in between
# (including the preflight probe row) must be proven replicated. This mirrors
# AWS step "wait for replication to catch up in the green environment".
blue_gtid="$(bg_target_sql 'SELECT @@gtid_binlog_pos')" \
  || fail_with_rollback "failed to read blue GTID position after stopping writes" '{"step":"gtid-capture"}'
if [[ -n "$blue_gtid" ]]; then
  check_deadline "green catch-up"
  remaining=$(( deadline - SECONDS ))
  bg_peer_call_task "$OP" "$PEER_AQSH_URL" "$PEER_TOKEN" "blue-green/switchover" \
    "$(jq -n --arg ns "$GREEN_NAMESPACE" --arg mdb "$GREEN_NAME" --arg blue "$BLUE_NAME" \
      --arg gtid "$blue_gtid" --arg timeout "$remaining" \
      '{namespace: $ns, green_name: $mdb, blue_name: $blue, gtid_target: $gtid, gtid_timeout: $timeout, internal_step: "gtid-wait"}')" \
    "$(( remaining + 60 ))" >/dev/null \
    || fail_with_rollback "green did not catch up to blue GTID ${blue_gtid} within the switchover timeout" "$BG_PEER_ERR"
fi

check_deadline "demoting blue"
bg_local_step "$BG_DIR/set-primary.sh" \
  "DB_NAMESPACE=$BG_NAMESPACE" "MARIADB_NAME=$BLUE_NAME" \
  "BLUE_GREEN_PRIMARY=$GREEN_NAME" "CONFIRM=true" >/dev/null \
  || fail_with_rollback "failed to demote blue" "$BG_LOCAL_ERR"
blue_demoted=1

check_deadline "promoting green"
bg_peer_call_task "$OP" "$PEER_AQSH_URL" "$PEER_TOKEN" "blue-green/switchover" \
  "$(jq -n --arg ns "$GREEN_NAMESPACE" --arg mdb "$GREEN_NAME" --arg blue "$BLUE_NAME" --arg primary "$GREEN_NAME" \
    '{namespace: $ns, green_name: $mdb, blue_name: $blue, primary: $primary, internal_step: "set-primary", confirm: "true"}')" "$PEER_TIMEOUT" >/dev/null \
  || fail_with_rollback "failed to promote green" "$BG_PEER_ERR"
green_promoted=1

# ---------------------------------------------------------------------------
# Phase 3: verify the new primary
# ---------------------------------------------------------------------------

green_post="$(bg_peer_call_task "$OP" "$PEER_AQSH_URL" "$PEER_TOKEN" "blue-green/switchover" \
  "$(jq -n --arg ns "$GREEN_NAMESPACE" --arg mdb "$GREEN_NAME" --arg blue "$BLUE_NAME" --arg primary "$GREEN_NAME" \
    --arg version "$EXPECTED_GREEN_VERSION" \
    '{namespace: $ns, green_name: $mdb, blue_name: $blue, expected_primary: $primary, expected_green_version: $version, check_replication: "false", internal_step: "validate"}')" \
  "$PEER_TIMEOUT")" \
  || fail_after_promotion "post-switchover validation of green failed" "$BG_PEER_ERR"

probe_result="{}"
if [[ "$SKIP_WRITE_PROBE" != "true" ]]; then
  probe_result="$(bg_peer_call_task "$OP" "$PEER_AQSH_URL" "$PEER_TOKEN" "blue-green/switchover" \
    "$(jq -n --arg ns "$GREEN_NAMESPACE" --arg mdb "$GREEN_NAME" --arg blue "$BLUE_NAME" \
      '{namespace: $ns, green_name: $mdb, blue_name: $blue, confirm: "true", note: "aqsh-switchover-postflight", internal_step: "write-probe"}')" \
    "$PEER_TIMEOUT")" \
    || fail_after_promotion "green did not accept writes after promotion" "$BG_PEER_ERR"
fi

data="$(jq -n \
  --arg blue "$BLUE_NAME" \
  --arg green "$GREEN_NAME" \
  --arg blueNamespace "$BG_NAMESPACE" \
  --arg greenNamespace "$GREEN_NAMESPACE" \
  --arg blueGtid "$blue_gtid" \
  --argjson switchoverTimeout "$SWITCHOVER_TIMEOUT" \
  --argjson guardrails "$(jq -n --argjson green "$green_validate" --argjson blue "$blue_validate" '{green: $green, blue: $blue}')" \
  --argjson greenAfter "$green_post" \
  --argjson writeProbe "$probe_result" \
  '{
    blue: $blue,
    green: $green,
    blueNamespace: $blueNamespace,
    greenNamespace: $greenNamespace,
    newPrimary: $green,
    blueGtidAtSwitchover: ($blueGtid | if . == "" then null else . end),
    switchoverTimeoutSeconds: $switchoverTimeout,
    guardrails: $guardrails,
    greenAfter: $greenAfter,
    writeProbe: $writeProbe
  }')"

bg_write_result "$(response_ok "$OP" "blue/green switchover completed; green is now primary" "$data")"
