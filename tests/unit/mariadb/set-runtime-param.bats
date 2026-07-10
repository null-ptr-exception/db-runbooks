#!/usr/bin/env bats
#
# Contract tests for mariadb/set-runtime-param.sh against a mock kubectl (no
# cluster). Covers discovery/list, allow-list + value validation, static->BLOCK,
# dry_run, confirm gate, apply + read-back, and scope resolution.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/set-runtime-param.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"
  MOCK_DIR="$(mktemp -d)"
  RESULT="${MOCK_DIR}/result.json"
  STATE="${MOCK_DIR}/state"; mkdir -p "$STATE"

  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
args="$*"
[[ "$args" == *"get pods"* ]] && { printf 'mariadb-0\nmariadb-1\nmariadb-2\n'; exit 0; }
# MOCK_PRIMARY defaults to mariadb-0 only when UNSET; set it to "" to simulate no primary
[[ "$args" == *"get mariadb"*"currentPrimary"* ]] && { printf '%s' "${MOCK_PRIMARY-mariadb-0}"; exit 0; }
[[ "$args" == *"get mariadb"*"metadata.name"* ]] && { printf 'mariadb'; exit 0; }
if [[ " ${args} " == *" exec "* ]]; then
  [[ "$args" == *"printenv MARIADB_ROOT_PASSWORD"* ]] && { printf 'testpass'; exit 0; }
  pod=""; prev=""; for a in "$@"; do [[ "$prev" == "exec" ]] && { pod="$a"; break; }; prev="$a"; done
  q=""; prev=""
  for a in "$@"; do [[ "$prev" == "-e" ]] && { q="$a"; break; }; prev="$a"; done
  case "$q" in
    "SET GLOBAL "*)
      [[ -n "${MOCK_FAIL_POD:-}" && "$pod" == "${MOCK_FAIL_POD}" ]] && exit 1
      rest="${q#SET GLOBAL }"; p="${rest%% =*}"; v="${rest##*= }"
      printf '%s' "$v" > "${MOCK_STATE}/${p}"; exit 0 ;;
    "SELECT @@GLOBAL."*)
      [[ -n "${MOCK_READBACK+x}" ]] && { printf '%s' "${MOCK_READBACK}"; exit 0; }
      p="${q#SELECT @@GLOBAL.}"
      if [[ -f "${MOCK_STATE}/${p}" ]]; then cat "${MOCK_STATE}/${p}"; else printf '%s' "${MOCK_DEFAULT:-151}"; fi; exit 0 ;;
    "SELECT READ_ONLY FROM"*)
      vn="${q##*VARIABLE_NAME=\'}"; vn="${vn%%\'*}"
      if [[ " ${MOCK_STATIC:-} " == *" ${vn} "* ]]; then printf 'YES'; else printf 'NO'; fi; exit 0 ;;
    *) printf '1'; exit 0 ;;
  esac
fi
exit 0
MOCK
  chmod +x "${MOCK_DIR}/kubectl"

  export DB_NAMESPACE="mariadb-1" MARIADB_NAME="mariadb" MARIADB_ROOT_PASSWORD="testpass"
  export MOCK_STATE="$STATE"
}
teardown() { rm -rf "${MOCK_DIR}"; }

run_srp() {
  run env "PATH=${MOCK_DIR}:${PATH}" "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" "MOCK_STATE=${STATE}" "$@" bash "${SCRIPT}"
}
field() { jq -r "$1" "${RESULT}"; }

@test "set-runtime-param lists supported params when none given" {
  run_srp DRY_RUN=true
  [ "$(field '.reason_code')" = "SRP_LIST" ]
  [ "$(field '.params | map(.param) | index("max_connections") | type')" = "number" ]
}

@test "set-runtime-param rejects a param not in the allow-list" {
  run_srp DRY_RUN=true RUNTIME_PARAM=some_random_var RUNTIME_VALUE=1
  [ "$(field '.reason_code')" = "PARAM_NOT_ALLOWED" ]
}

@test "set-runtime-param requires a value for an allowed param" {
  run_srp DRY_RUN=true RUNTIME_PARAM=max_connections
  [ "$(field '.reason_code')" = "VALUE_REQUIRED" ]
}

@test "set-runtime-param rejects an invalid value" {
  run_srp DRY_RUN=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=abc
  [ "$(field '.reason_code')" = "VALUE_INVALID" ]
}

@test "set-runtime-param blocks a static (restart-only) param" {
  run_srp DRY_RUN=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=500 MOCK_STATIC=MAX_CONNECTIONS
  [ "$(field '.reason_code')" = "PARAM_STATIC" ]
}

@test "set-runtime-param dry_run shows current -> target without applying" {
  run_srp DRY_RUN=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=500
  [ "$(field '.reason_code')" = "SRP_DRY_RUN" ]
  [ "$(field '.tier')" = "safe" ]
  [ "$(field '.targets | length')" = "3" ]
  [ "$(field '.ephemeral')" = "true" ]
}

@test "set-runtime-param requires confirm to apply" {
  run_srp DRY_RUN=false CONFIRM=false RUNTIME_PARAM=max_connections RUNTIME_VALUE=500
  [ "$(field '.reason_code')" = "CONFIRM_REQUIRED" ]
}

@test "set-runtime-param applies SET GLOBAL on confirm (all pods) and reads it back" {
  run_srp DRY_RUN=false CONFIRM=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=500
  [ "$status" -eq 0 ]
  [ "$(field '.status')" = "CHANGED" ]
  [ "$(field '.reason_code')" = "SRP_APPLIED" ]
  [ "$(field '.results | length')" = "3" ]
  [ "$(field '.results | all(.applied == true)')" = "true" ]
  [ "$(field '.results[0].value')" = "500" ]
}

@test "set-runtime-param scope=primary targets only the primary" {
  run_srp DRY_RUN=false CONFIRM=true RUNTIME_SCOPE=primary RUNTIME_PARAM=max_connections RUNTIME_VALUE=400
  [ "$(field '.results | length')" = "1" ]
  [ "$(field '.results[0].pod')" = "mariadb-0" ]
}

@test "set-runtime-param scope=<pod> targets only the named pod" {
  run_srp DRY_RUN=false CONFIRM=true RUNTIME_SCOPE=mariadb-1 RUNTIME_PARAM=max_connections RUNTIME_VALUE=400
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = "SRP_APPLIED" ]
  [ "$(field '.results | length')" = "1" ]
  [ "$(field '.results[0].pod')" = "mariadb-1" ]
}

@test "set-runtime-param rejects a nonexistent pod scope" {
  run_srp DRY_RUN=true RUNTIME_SCOPE=mariadb-9 RUNTIME_PARAM=max_connections RUNTIME_VALUE=400
  [ "$(field '.reason_code')" = "SCOPE_INVALID" ]
  [ "$(field '.changed')" = "false" ]
}

@test "set-runtime-param dry_run warns on a memory-tier param" {
  run_srp DRY_RUN=true RUNTIME_PARAM=innodb_buffer_pool_size RUNTIME_VALUE=1073741824
  [ "$(field '.tier')" = "memory" ]
  [[ "$(field '.summary')" == *"OOM"* ]]
}

@test "set-runtime-param accepts and flags an adjusted memory-tier read-back" {
  run_srp DRY_RUN=false CONFIRM=true RUNTIME_PARAM=innodb_buffer_pool_size \
    RUNTIME_VALUE=1073741824 MOCK_READBACK=1073741823
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = "SRP_APPLIED" ]
  [ "$(field '.results | all(.applied == true and .adjusted == true)')" = "true" ]
  [ "$(field '.results | all(.requested == "1073741824" and .value == "1073741823")')" = "true" ]
}

@test "set-runtime-param dry_run warns on a durability-tier param" {
  run_srp DRY_RUN=true RUNTIME_PARAM=innodb_flush_log_at_trx_commit RUNTIME_VALUE=2
  [ "$(field '.tier')" = "durability" ]
  [[ "$(field '.summary')" == *"relaxes durability"* ]]
  [[ "$(field '.summary')" == *"data-loss window"* ]]
}

@test "set-runtime-param dry_run warns on a protect-tier param" {
  run_srp DRY_RUN=true RUNTIME_PARAM=read_only RUNTIME_VALUE=ON
  [ "$(field '.tier')" = "protect" ]
  [[ "$(field '.summary')" == *"read/write mode"* ]]
}

@test "set-runtime-param fails closed on an invalid dry_run value" {
  run_srp DRY_RUN=treu CONFIRM=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=500
  [ "$(field '.reason_code')" = "INVALID_BOOL" ]
}

@test "set-runtime-param blocks scope=primary when primary is unknown and multi-pod" {
  run_srp DRY_RUN=false CONFIRM=true RUNTIME_SCOPE=primary RUNTIME_PARAM=max_connections RUNTIME_VALUE=500 MOCK_PRIMARY=
  [ "$(field '.reason_code')" = "PRIMARY_UNKNOWN" ]
}

@test "set-runtime-param treats a read-back mismatch as failure" {
  run_srp DRY_RUN=false CONFIRM=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=500 MOCK_READBACK=151
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = "SRP_APPLY_FAILED" ]
  [ "$(field '.results | all(.applied == false)')" = "true" ]
}

@test "set-runtime-param resolves a *multiplier relative value (current 151)" {
  run_srp DRY_RUN=true RUNTIME_PARAM=max_connections RUNTIME_VALUE='*2'
  [ "$(field '.reason_code')" = "SRP_DRY_RUN" ]
  [ "$(field '.value')" = "302" ]
  [ "$(field '.value_expr')" != "null" ]
}

@test "set-runtime-param resolves a +N additive relative value" {
  run_srp DRY_RUN=true RUNTIME_PARAM=max_connections RUNTIME_VALUE='+100'
  [ "$(field '.value')" = "251" ]
}

@test "set-runtime-param resolves a +percentage relative value" {
  run_srp DRY_RUN=true RUNTIME_PARAM=max_connections RUNTIME_VALUE='+25%'
  [ "$(field '.value')" = "189" ]
}

@test "set-runtime-param resolves a -percentage (scale down) relative value" {
  run_srp DRY_RUN=true RUNTIME_PARAM=wait_timeout RUNTIME_VALUE='-25%'
  [ "$(field '.value')" = "113" ]
}

@test "set-runtime-param rejects a relative value on a non-numeric param" {
  run_srp DRY_RUN=true RUNTIME_PARAM=slow_query_log RUNTIME_VALUE='*2'
  [ "$(field '.reason_code')" = "RELATIVE_UNSUPPORTED" ]
}

@test "set-runtime-param reports partial mutation as changed on failure" {
  # pod mariadb-1's SET GLOBAL fails; mariadb-0 already applied -> changed=true
  run_srp DRY_RUN=false CONFIRM=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=500 MOCK_FAIL_POD=mariadb-1
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = "SRP_APPLY_FAILED" ]
  [ "$(field '.changed')" = "true" ]
  [ "$(field '.partial')" = "true" ]
}
