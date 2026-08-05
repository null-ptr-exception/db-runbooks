#!/usr/bin/env bats
# =============================================================================
# Unit tests for the peer-AQSH transport.
#
# Regression: replication/rebuild originally called blue-green's
# bg_peer_call_task to ask the primary for a physical backup. That variant
# injects peer_aqsh_url/peer_token into the payload — required by blue/green's
# own task contract, but physical-backup does not declare those inputs, so aqsh
# rejected every request with 400 and the rebuild failed at its first step.
#
# The distinction is now structural (neutral transport + blue/green wrapper) and
# pinned here: what each one puts on the wire.
# =============================================================================

setup() {
  LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../../../aqsh-tasks/lib" && pwd)"
  export LIB_DIR
  # blue-green.sh reads ${DB_NAMESPACE:?} at source time.
  export DB_NAMESPACE="test-ns"
  PAYLOAD_FILE="$BATS_TEST_TMPDIR/payload.json"
  export PAYLOAD_FILE

  # shellcheck disable=SC1091
  source "$LIB_DIR/mariadb-blue-green.sh"   # also pulls in mariadb-task-common.sh

  # Intercept the wire. The submit call carries -d <payload>; the poll call does
  # not, and answers "completed" so the transport returns immediately.
  curl() {
    local args=("$@") body="" i
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ "${args[i]}" == "-d" ]]; then
        body="${args[i+1]}"
      fi
    done
    if [[ -n "$body" ]]; then
      printf '%s' "$body" > "$PAYLOAD_FILE"
      printf '%s\n202' '{"id":"task-1"}'
    else
      # %s, not a format string: printf would turn the \" escapes into bare
      # quotes and emit invalid JSON, which jq then cannot parse — the poll loop
      # would spin to its full timeout instead of seeing "completed".
      printf '%s' '{"status":"completed","result":{"data":"{\"data\":{\"ok\":true}}"}}'
    fi
  }
}

@test "the neutral transport sends the payload verbatim" {
  run mdbt_peer_call_task "http://peer:8080" "tok" "physical-backup" \
    '{"namespace":"ns-1","confirm":"true"}'
  [ "$status" -eq 0 ]

  # Exactly the declared fields — anything extra is a 400 from aqsh.
  run jq -Sc 'keys' "$PAYLOAD_FILE"
  [ "$output" = '["confirm","namespace"]' ]
}

@test "the neutral transport does not inject peer credentials" {
  mdbt_peer_call_task "http://peer:8080" "tok" "physical-backup" '{"namespace":"ns-1"}'

  run jq -r 'has("peer_aqsh_url") or has("peer_token")' "$PAYLOAD_FILE"
  [ "$output" = "false" ]
}

@test "the blue-green wrapper does inject peer credentials" {
  # Its own tasks declare these as required inputs, including on internal-step
  # calls, so the injection has to stay — just not in the shared transport.
  run bg_peer_call_task "op" "http://peer:8080" "tok" "blue-green/create" \
    '{"namespace":"ns-1"}'
  [ "$status" -eq 0 ]

  run jq -r '.peer_aqsh_url + "|" + .peer_token' "$PAYLOAD_FILE"
  [ "$output" = "http://peer:8080|tok" ]
}

@test "the blue-green wrapper preserves the caller's own fields" {
  bg_peer_call_task "op" "http://peer:8080" "tok" "blue-green/create" \
    '{"namespace":"ns-1","internal_step":"bootstrap"}'

  run jq -r '.namespace + "|" + .internal_step' "$PAYLOAD_FILE"
  [ "$output" = "ns-1|bootstrap" ]
}

@test "the transport returns the peer task's inner result data" {
  run mdbt_peer_call_task "http://peer:8080" "tok" "physical-backup" '{"namespace":"ns-1"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<<"$output")" = "true" ]
}

@test "a non-202 submit is a failure with a public-safe marker" {
  curl() { printf '%s\n400' '{"error":"bad request"}'; }

  run mdbt_peer_call_task "http://peer:8080" "tok" "physical-backup" '{"namespace":"ns-1"}'
  [ "$status" -eq 1 ]

  # Called without `run` so MDBT_PEER_ERR lands in this shell.
  mdbt_peer_call_task "http://peer:8080" "tok" "physical-backup" '{"namespace":"ns-1"}' || true
  [ "$(jq -r '.stage' <<<"$MDBT_PEER_ERR")" = "peer-operation" ]
  # No backend diagnostics leak into the marker.
  [[ "$MDBT_PEER_ERR" != *"bad request"* ]]
}

@test "a failed peer task is reported as a failure" {
  curl() {
    local args=("$@") body="" i
    for ((i = 0; i < ${#args[@]}; i++)); do
      [[ "${args[i]}" == "-d" ]] && body="${args[i+1]}"
    done
    if [[ -n "$body" ]]; then printf '%s\n202' '{"id":"task-1"}'; else printf '%s' '{"status":"failed"}'; fi
  }

  run mdbt_peer_call_task "http://peer:8080" "tok" "physical-backup" '{"namespace":"ns-1"}'
  [ "$status" -eq 1 ]
}
