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
  EXEC_LOG="${MOCK_DIR}/exec.log"
  export MOCK_SQL_LOG="${MOCK_DIR}/sql.log"
  export JOB_REPORT_CONFIG_FILE="${MOCK_DIR}/absent.env"
  unset JOB_REPORT_DATABASE JOB_REPORT_TABLE

  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
args="$*"
[[ "$args" == *"get mariadb"*".spec.replicas"* ]] && { printf '%s' "${MOCK_CR_REPLICAS-3}"; exit 0; }
[[ "$args" == *"get statefulset"*".spec.replicas"* ]] && { printf '%s' "${MOCK_STS_REPLICAS-}"; exit 0; }
if [[ "$args" == *"get pods"*"-o json"* ]]; then
  # _k8s_sts_owned_pod_names: live ownerReferences check, same replica
  # precedence as mariadb_list_member_pods (CR replicas, else STS replicas).
  mock_replicas="${MOCK_CR_REPLICAS-3}"
  [[ -n "$mock_replicas" ]] || mock_replicas="${MOCK_STS_REPLICAS-}"
  items=""
  if [[ "$mock_replicas" =~ ^[1-9][0-9]*$ ]]; then
    for ((mock_i = 0; mock_i < mock_replicas; mock_i++)); do
      items+="${items:+,}{\"metadata\":{\"name\":\"${MARIADB_NAME}-${mock_i}\",\"ownerReferences\":[{\"kind\":\"StatefulSet\",\"name\":\"${MARIADB_NAME}\",\"controller\":true}]}}"
    done
  fi
  printf '{"items":[%s]}\n' "$items"
  exit 0
fi
[[ "$args" == *"get pods"* ]] && { printf 'mariadb-0\nmariadb-1\nmariadb-2\nmariadb-metrics\nmariadb-query-exporter\n'; exit 0; }
# MOCK_PRIMARY defaults to mariadb-0 only when UNSET; set it to "" to simulate no primary
[[ "$args" == *"get mariadb"*"currentPrimary"* ]] && { printf '%s' "${MOCK_PRIMARY-mariadb-0}"; exit 0; }
[[ "$args" == *"get mariadb"*"metadata.name"* ]] && { printf 'mariadb'; exit 0; }
if [[ " ${args} " == *" exec "* ]]; then
  [[ "$args" == *"printenv MARIADB_ROOT_PASSWORD"* ]] && { printf 'testpass'; exit 0; }
  pod=""; prev=""; for a in "$@"; do [[ "$prev" == "exec" ]] && { pod="$a"; break; }; prev="$a"; done
  printf '%s\n' "$pod" >> "${MOCK_EXEC_LOG}"
  q=""; prev=""
  for a in "$@"; do [[ "$prev" == "-e" ]] && { q="$a"; break; }; prev="$a"; done
  printf '%s\n' "$q" >> "$MOCK_SQL_LOG"
  case "$q" in
    *information_schema.COLUMNS*) printf '80\t80\t255\t16\n'; exit 0 ;;
    *INSERT\ INTO*)
      [[ "${MOCK_REPORT_FAIL:-}" != insert ]] || exit 1
      printf '2026-01-02 03:04:05\n'; exit 0 ;;
    *UPDATE*)
      [[ "${MOCK_REPORT_FAIL:-}" != update ]] || exit 1
      printf '1\n'; exit 0 ;;
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
    *) printf 'unexpected SQL: %s\n' "$q" >&2; exit 97 ;;
  esac
fi
exit 0
MOCK
  chmod +x "${MOCK_DIR}/kubectl"

  export DB_NAMESPACE="mariadb-1" MARIADB_NAME="mariadb" MARIADB_ROOT_PASSWORD="testpass"
  export MOCK_STATE="$STATE" MOCK_EXEC_LOG="$EXEC_LOG"
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
  if grep -Eq 'mariadb-(metrics|query-exporter)' "$EXEC_LOG"; then return 1; fi
}

@test "set-runtime-param scope=all excludes auxiliary pods sharing the instance label" {
  run_srp DRY_RUN=false CONFIRM=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=500
  [ "$status" -eq 0 ]
  [ "$(field '.results | map(.pod) | sort | join(",")')" = "mariadb-0,mariadb-1,mariadb-2" ]
  if grep -Eq 'mariadb-(metrics|query-exporter)' "$EXEC_LOG"; then return 1; fi
}

@test "set-runtime-param fails closed when exact workload members cannot be resolved" {
  run_srp DRY_RUN=false CONFIRM=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=500 \
    MOCK_CR_REPLICAS= MOCK_STS_REPLICAS=
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = "POD_TARGETS_UNRESOLVED" ]
  [ "$(field '.changed')" = "false" ]
  [ ! -s "$EXEC_LOG" ]
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

@test "max_connections reports verified success on the primary even with all scope" {
  run_srp JOB_REPORT_DATABASE=operations JOB_REPORT_TABLE=job_history \
    DRY_RUN=false CONFIRM=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=500 MOCK_PRIMARY=mariadb-1
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = SRP_APPLIED ]
  grep -q "status='Finish',flag=1" "$MOCK_SQL_LOG"
  # First SQL call (metadata for reporting) must target the actual primary.
  [ "$(head -1 "$EXEC_LOG")" = mariadb-1 ]
  grep -q "CONVERT(X'6d6172696164622d31' USING utf8mb4)" "$MOCK_SQL_LOG"
  [ "$(grep -c 'UPDATE' "$MOCK_SQL_LOG")" -eq 1 ]
}

@test "reporting records BLOCKED as Failed despite zero exit status" {
  run_srp JOB_REPORT_DATABASE=operations JOB_REPORT_TABLE=job_history \
    DRY_RUN=false CONFIRM=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=bad
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = VALUE_INVALID ]
  grep -q "status='Failed',flag=4" "$MOCK_SQL_LOG"
}

@test "reporting records partial apply as Failed and preserves partial result" {
  run_srp JOB_REPORT_DATABASE=operations JOB_REPORT_TABLE=job_history \
    DRY_RUN=false CONFIRM=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=500 MOCK_FAIL_POD=mariadb-2
  [ "$status" -eq 1 ]
  [ "$(field '.reason_code')" = SRP_APPLY_FAILED ]
  [ "$(field '.partial')" = true ]
  grep -q "status='Failed',flag=4" "$MOCK_SQL_LOG"
}

@test "JOB_REPORT_NAME overrides the recorded job_name" {
  # incident-bump -> 696e636964656e742d62756d70
  run_srp JOB_REPORT_DATABASE=operations JOB_REPORT_TABLE=job_history \
    JOB_REPORT_NAME=incident-bump \
    DRY_RUN=false CONFIRM=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=500 MOCK_PRIMARY=mariadb-1
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = SRP_APPLIED ]
  grep -q "CONVERT(X'696e636964656e742d62756d70' USING utf8mb4)" "$MOCK_SQL_LOG"
  # default max_connections hex must NOT appear as job_name identity
  if grep -q "CONVERT(X'6d61785f636f6e6e656374696f6e73' USING utf8mb4)" "$MOCK_SQL_LOG"; then return 1; fi
}

@test "empty JOB_REPORT_NAME falls back to the parameter name" {
  run_srp JOB_REPORT_DATABASE=operations JOB_REPORT_TABLE=job_history \
    JOB_REPORT_NAME= \
    DRY_RUN=false CONFIRM=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=500 MOCK_PRIMARY=mariadb-1
  [ "$status" -eq 0 ]
  grep -q "CONVERT(X'6d61785f636f6e6e656374696f6e73' USING utf8mb4)" "$MOCK_SQL_LOG"
}

@test "dry-run and other params never report even with deployment settings" {
  run_srp JOB_REPORT_DATABASE=operations JOB_REPORT_TABLE=job_history \
    DRY_RUN=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=500
  [ "$status" -eq 0 ]
  if grep -q 'INSERT INTO' "$MOCK_SQL_LOG"; then return 1; fi
  run_srp JOB_REPORT_DATABASE=operations JOB_REPORT_TABLE=job_history \
    DRY_RUN=false CONFIRM=true RUNTIME_PARAM=max_statement_time RUNTIME_VALUE=10
  [ "$status" -eq 0 ]
  if grep -q 'INSERT INTO' "$MOCK_SQL_LOG"; then return 1; fi
}

@test "reporting SQL failures leave parameter changes successful" {
  for stage in insert update; do
    run_srp JOB_REPORT_DATABASE=operations JOB_REPORT_TABLE=job_history \
      DRY_RUN=false CONFIRM=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=500 MOCK_REPORT_FAIL="$stage"
    [ "$status" -eq 0 ]
    [ "$(field '.reason_code')" = SRP_APPLIED ]
    [[ "$output" == *job-report:* ]]
  done
}

@test "unknown multi-pod primary skips reporting without changing the operation scope" {
  run_srp JOB_REPORT_DATABASE=operations JOB_REPORT_TABLE=job_history \
    DRY_RUN=false CONFIRM=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=500 MOCK_PRIMARY=
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = SRP_APPLIED ]
  if grep -q 'INSERT INTO' "$MOCK_SQL_LOG"; then return 1; fi
  [[ "$output" == *job-report:* ]]
}

@test "single member is the report primary when operator status is absent" {
  run_srp JOB_REPORT_DATABASE=operations JOB_REPORT_TABLE=job_history \
    DRY_RUN=false CONFIRM=true RUNTIME_PARAM=max_connections RUNTIME_VALUE=500 MOCK_PRIMARY= MOCK_CR_REPLICAS=1
  [ "$status" -eq 0 ]
  grep -q "status='Finish',flag=1" "$MOCK_SQL_LOG"
}
