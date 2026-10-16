#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  MOCK_DIR="$(mktemp -d)"
  export RESULT="${MOCK_DIR}/result.json"
  export MOCK_SQL_LOG="${MOCK_DIR}/sql.log"
  export MOCK_FINGERPRINT
  MOCK_FINGERPRINT="$(printf '%064d' 1)"
  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args=sys.argv[1:]
text=' '.join(args)
def env(key, default=''):
    return os.environ.get(key, default)
def out(value):
    print(json.dumps(value))
def die():
    sys.exit(1)
if 'get mariadb' in text and 'items[*]' in text:
    print(env('MOCK_INSTANCE', 'mariadb')); sys.exit(0)
if 'get mariadb' in text and '.spec.replicas' in text:
    print('2'); sys.exit(0)
if 'get pods -o json' in text:
    out({'items':[{'metadata':{'name':f'mariadb-{i}','ownerReferences':[
        {'kind':'StatefulSet','name':'mariadb','controller':True}]}} for i in range(2)]})
    sys.exit(0)
if 'get pod mariadb-' in text and '-o json' in text:
    if env('MOCK_POD_UNAVAILABLE'): die()
    out({'metadata':{'uid':'pod-uid-1'},'status':{'phase':'Running',
        'containerStatuses':[{'name':'mariadb','restartCount':0,'state':{'running':{}}}]}})
    sys.exit(0)
if 'exec' in args:
    pod=args[args.index('exec')+1]
    if pod != 'mariadb-1':
        raise SystemExit('SQL/credentials sent to wrong pod')
    if 'printenv MARIADB_ROOT_PASSWORD' in text:
        if env('MOCK_NO_PASSWORD'): die()
        print('unit-only-password'); sys.exit(0)
    if '--raw' not in args or '-e' not in args:
        raise SystemExit('unexpected client invocation')
    query=args[args.index('-e')+1]
    with Path(env('MOCK_SQL_LOG')).open('a') as f:
        f.write(query+'\n')
    if query.startswith('KILL '):
        checkpoint=json.loads(Path(env('RESULT')).read_text())
        assert checkpoint['reason_code']=='SESSION_KILL_ATTEMPTING'
        assert checkpoint['changed'] is None
        if env('MOCK_KILL_FAIL'):
            if env('MOCK_KILL_ERROR_CODE'):
                print(f"ERROR {env('MOCK_KILL_ERROR_CODE')} (HY000) at line 1: Unknown id unit-only-password",file=sys.stderr)
            die()
        sys.exit(0)
    if not query.startswith('SET STATEMENT max_statement_time='):
        raise SystemExit('unbounded read')
    sections=('processlist','distribution','connection_status','transactions','lock_waits','inspect','verify')
    matches=[s for s in sections if f'/* sessions:{s} */' in query]
    if len(matches)!=1:
        raise SystemExit('unexpected SQL')
    section=matches[0]
    if env('MOCK_FAIL_SECTION') in (section,'all'): die()
    if env('MOCK_BAD_JSON') == section:
        print('not json'); sys.exit(0)
    if section=='processlist':
        assert "COMMAND <> 'Sleep' AND ID <> CONNECTION_ID()" in query
        for i in range(3):
            out({'connection_id':str(10+i),'query_id':str(20+i),
                 'sql':'select "a\\b"\nfrom example','command':'Query','command_seconds':30-i})
    elif section=='distribution':
        out({'user':'app','database':'example','state':'Updating','thread_count':3})
    elif section=='connection_status':
        out({'server':'mariadb-1','version':'10.11','max_connections':100,
             'threads_running':None if env('MOCK_NULL_STATUS') else 3,'threads_connected':10,'row_lock_current_waits':1})
    elif section=='transactions':
        assert "COMMAND <> 'Sleep'" not in query
        out({'transaction_id':'100','connection_id':'42','command':'Sleep','transaction_seconds':300})
    elif section=='lock_waits':
        out({'waiting_transaction_id':'101','waiting_connection_id':'43',
             'blocking_transaction_id':'100','blocking_connection_id':'42'})
    elif section=='inspect':
        if env('MOCK_NOT_FOUND'): sys.exit(0)
        out({'connection_id':env('MOCK_ROW_ID','42'),'query_id':env('MOCK_QUERY_ID','73'),
             'user':env('MOCK_USER','app'),'host':'client:123','database':'example',
             'command':env('MOCK_COMMAND','Query'),
             'sql':'SELECT SLEEP(60)',
             'transaction_id':int(env('MOCK_TRX_ID','100')) if env('MOCK_NUMERIC_TRX_ID') else env('MOCK_TRX_ID','100'),
             'rows_modified':10,
             'fingerprint':env('MOCK_FINGERPRINT')})
    elif section=='verify':
        checkpoint=json.loads(Path(env('RESULT')).read_text())
        if env('MOCK_KILL_FAIL'):
            assert checkpoint['reason_code']=='SESSION_KILL_ATTEMPTING'
            assert checkpoint['command_accepted'] is None
        else:
            assert checkpoint['reason_code']=='SESSION_KILL_ACCEPTED'
            assert checkpoint['command_accepted'] is True
        pending=bool(env('MOCK_PENDING'))
        if env('MOCK_EMPTY_VERIFY'):
            out({}); sys.exit(0)
        out({'connection_present':int(pending or bool(env('MOCK_QUERY_STOPPED'))),
             'original_query_present':int(pending),
             'original_transaction_present':int(pending or bool(env('MOCK_QUERY_STOPPED'))),
             'original_transaction_waiters':int(bool(env('MOCK_QUERY_STOPPED')))})
    sys.exit(0)
raise SystemExit('unexpected kubectl invocation: '+text)
MOCK
  chmod +x "${MOCK_DIR}/kubectl"
}

teardown() { rm -rf "$MOCK_DIR"; }
run_sessions() {
  run env "PATH=${MOCK_DIR}:$PATH" "LIB_DIR=${REPO_ROOT}/aqsh-tasks/lib" \
    "AQSH_RESULT_FILE=$RESULT" DB_NAMESPACE=mariadb-1 TARGET_POD=mariadb-1 \
    SESSION_VERIFY_ATTEMPTS_DEFAULT=1 "$@" bash "${REPO_ROOT}/aqsh-tasks/scripts/mariadb/sessions.sh"
}
field() { jq -r "$1" "$RESULT"; }
assert_no_kill() { ! grep -q '^KILL ' "$MOCK_SQL_LOG" 2>/dev/null; }

@test "sessions default diagnosis preserves details and idle transactions on the selected replica" {
  run_sessions
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = SESSION_DIAGNOSTICS_READY ]
  [ "$(field '.sections | length')" = 5 ]
  [ "$(field '.sections.transactions.rows[0].command')" = Sleep ]
  [ "$(field '.findings[0].connection_id')" = 42 ]
  [ "$(field '.sections.processlist.rows[0].sql')" = $'select "a\\b"\nfrom example' ]
  [[ "$output" != *unit-only-password* ]]
  assert_no_kill
}

@test "sessions marks bounded rows truncated instead of claiming completeness" {
  run_sessions SESSION_ROW_LIMIT_DEFAULT=2
  [ "$status" -eq 0 ]
  [ "$(field '.sections.processlist.rows | length')" = 2 ]
  [ "$(field '.sections.processlist.truncated')" = true ]
}

@test "sessions rejects invalid actions and injected connection identifiers before SQL" {
  run_sessions SESSION_ACTION=arbitrary
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_INVALID_INPUT ]
  run_sessions SESSION_ACTION=kill-connection 'CONNECTION_ID=42;DROP TABLE example'
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_INVALID_INPUT ]
  [ ! -e "$MOCK_SQL_LOG" ]
}

@test "sessions rejects invalid collection policy before SQL" {
  run_sessions SESSION_ROW_LIMIT_DEFAULT=0
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_INVALID_POLICY ]
  assert_no_kill
}

@test "sessions fails closed on unresolved instance and unavailable pod epoch" {
  run_sessions 'MOCK_INSTANCE=mariadb-a
mariadb-b'
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_TARGET_UNRESOLVED ]
  run_sessions MOCK_POD_UNAVAILABLE=1
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_TARGET_UNRESOLVED ]
  assert_no_kill
}

@test "sessions never sends SQL to an unrelated pod" {
  run_sessions TARGET_POD=other-0
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_POD_NOT_MEMBER ]
  [ ! -e "$MOCK_SQL_LOG" ]
}

@test "sessions reports missing credentials without exposing them" {
  run_sessions MOCK_NO_PASSWORD=1
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_CREDENTIALS_UNAVAILABLE ]
  assert_no_kill
}

@test "sessions reports partial collection rather than converting failure into empty results" {
  run_sessions MOCK_FAIL_SECTION=lock_waits
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = SESSION_DIAGNOSTICS_PARTIAL ]
  [ "$(field '.sections.lock_waits.rows')" = null ]
  [ "$(field '.findings')" = null ]
}

@test "sessions reports total collection failure" {
  run_sessions MOCK_FAIL_SECTION=all
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_DIAGNOSTICS_UNAVAILABLE ]
}

@test "sessions malformed section output is unavailable" {
  run_sessions MOCK_BAD_JSON=processlist
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = SESSION_DIAGNOSTICS_PARTIAL ]
}

@test "sessions requires consistent dry-run and confirm gates" {
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 DRY_RUN=false
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_CONFIRM_REQUIRED ]
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 CONFIRM=true
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_CONFIRM_REQUIRED ]
  assert_no_kill
}

@test "sessions requires a matching preview token before mutation" {
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 DRY_RUN=false CONFIRM=true
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_EXPECTED_SESSION_REQUIRED ]
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 DRY_RUN=false CONFIRM=true \
    EXPECTED_SESSION=malformed
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_INVALID_INPUT ]
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 DRY_RUN=false CONFIRM=true \
    "EXPECTED_SESSION=$(printf '%064d' 2)"
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_TARGET_CHANGED ]
  assert_no_kill
}

@test "sessions fails closed when inspection fails or is malformed" {
  run_sessions SESSION_ACTION=kill-query CONNECTION_ID=42 MOCK_FAIL_SECTION=inspect
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_INSPECTION_FAILED ]
  run_sessions SESSION_ACTION=kill-query CONNECTION_ID=42 MOCK_BAD_JSON=inspect
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_INSPECTION_FAILED ]
  assert_no_kill
}

@test "sessions reports an absent target without mutation" {
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 MOCK_NOT_FOUND=1
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = SESSION_NOT_FOUND ]
  assert_no_kill
}

@test "sessions protects root replication and extra deployment accounts" {
  for setting in MOCK_USER=root 'MOCK_COMMAND=Binlog Dump' MOCK_USER=platform; do
    run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 \
      SESSION_PROTECTED_USERS_DEFAULT=platform "$setting"
    [ "$status" -ne 0 ]
    [ "$(field '.reason_code')" = SESSION_PROTECTED_TARGET ]
    assert_no_kill
  done
}

@test "sessions refuses query termination for idle or non-running statements" {
  run_sessions SESSION_ACTION=kill-query CONNECTION_ID=42 MOCK_COMMAND=Sleep
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_QUERY_NOT_RUNNING ]
  run_sessions SESSION_ACTION=kill-query CONNECTION_ID=42 MOCK_QUERY_ID=0
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_QUERY_NOT_RUNNING ]
  assert_no_kill
}

@test "sessions dry-run returns a target token without issuing KILL" {
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = SESSION_DRY_RUN_READY ]
  [ "$(field '.before.fingerprint')" = "$MOCK_FINGERPRINT" ]
  [ "$(field '.kill_issued')" = false ]
  assert_no_kill
}

@test "sessions kills only the inspected statement and preserves remaining transaction evidence" {
  run_sessions SESSION_ACTION=kill-query CONNECTION_ID=42 DRY_RUN=false CONFIRM=true \
    "EXPECTED_SESSION=$MOCK_FINGERPRINT" MOCK_QUERY_STOPPED=1
  [ "$status" -eq 0 ]
  [[ "$output" == *SESSION_KILL_ATTEMPTING* ]]
  [[ "$output" == *SESSION_KILL_ACCEPTED* ]]
  [ "$(field '.reason_code')" = SESSION_TERMINATION_VERIFIED ]
  [ "$(field '.verification.original_transaction_present')" = 1 ]
  [ "$(field '.verification.original_transaction_waiters')" = 1 ]
  grep -qx 'KILL QUERY ID 73;' "$MOCK_SQL_LOG"
}

@test "sessions verifies terminated connection and rolled-back transaction" {
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 DRY_RUN=false CONFIRM=true \
    "EXPECTED_SESSION=$MOCK_FINGERPRINT"
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = SESSION_TERMINATION_VERIFIED ]
  [ "$(field '.verification.original_transaction_present')" = 0 ]
  grep -qx 'KILL CONNECTION 42;' "$MOCK_SQL_LOG"
}

@test "sessions reports accepted but still pending termination" {
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 DRY_RUN=false CONFIRM=true \
    "EXPECTED_SESSION=$MOCK_FINGERPRINT" MOCK_PENDING=1
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = SESSION_TERMINATION_PENDING ]
  [ "$(field '.command_accepted')" = true ]
}

@test "sessions does not call a failed verification successful" {
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 DRY_RUN=false CONFIRM=true \
    "EXPECTED_SESSION=$MOCK_FINGERPRINT" MOCK_FAIL_SECTION=verify
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = SESSION_VERIFICATION_UNAVAILABLE ]
  [ "$(field '.changed')" = true ]
}

@test "sessions reports uncertain execution after KILL transport failure" {
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 DRY_RUN=false CONFIRM=true \
    "EXPECTED_SESSION=$MOCK_FINGERPRINT" MOCK_KILL_FAIL=1 MOCK_PENDING=1
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_KILL_FAILED ]
  [ "$(field '.changed')" = null ]
  [ "$(field '.command_accepted')" = null ]
}

@test "sessions fails KILL preparation before recording or issuing a mutation" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${MOCK_DIR}/mktemp"
  chmod +x "${MOCK_DIR}/mktemp"
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 DRY_RUN=false CONFIRM=true \
    "EXPECTED_SESSION=$MOCK_FINGERPRINT"
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_KILL_PREPARATION_FAILED ]
  [ "$(field '.changed')" = false ]
  assert_no_kill
}

@test "sessions reconciles an already-ended target after a definite missing-ID error" {
  for pair in kill-query:1957 kill-connection:1094; do
    run_sessions "SESSION_ACTION=${pair%:*}" CONNECTION_ID=42 DRY_RUN=false CONFIRM=true \
      "EXPECTED_SESSION=$MOCK_FINGERPRINT" MOCK_KILL_FAIL=1 "MOCK_KILL_ERROR_CODE=${pair#*:}"
    [ "$status" -eq 0 ]
    [ "$(field '.reason_code')" = SESSION_TARGET_ALREADY_GONE ]
    [ "$(field '.changed')" = false ]
    [ "$(field '.command_accepted')" = false ]
    [ "$(field '.verification.state')" = verified ]
    [ "$(grep -c '^KILL ' "$MOCK_SQL_LOG")" -eq 1 ]
    [[ "$output" != *unit-only-password* ]]
    : > "$MOCK_SQL_LOG"
  done
}

@test "sessions keeps uncertainty about mutation when a lost KILL reply is followed by verified absence" {
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 DRY_RUN=false CONFIRM=true \
    "EXPECTED_SESSION=$MOCK_FINGERPRINT" MOCK_KILL_FAIL=1
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = SESSION_TERMINATION_VERIFIED ]
  [ "$(field '.changed')" = null ]
  [ "$(field '.command_accepted')" = null ]
  [ "$(field '.verification.state')" = verified ]
  [ "$(grep -c '^KILL ' "$MOCK_SQL_LOG")" -eq 1 ]
}

@test "sessions cannot reconcile a failed KILL when verification is unavailable or the target remains" {
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 DRY_RUN=false CONFIRM=true \
    "EXPECTED_SESSION=$MOCK_FINGERPRINT" MOCK_KILL_FAIL=1 MOCK_FAIL_SECTION=verify
  [ "$(field '.reason_code')" = SESSION_VERIFICATION_UNAVAILABLE ]
  [ "$(field '.changed')" = null ]
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 DRY_RUN=false CONFIRM=true \
    "EXPECTED_SESSION=$MOCK_FINGERPRINT" MOCK_KILL_FAIL=1 MOCK_KILL_ERROR_CODE=1094 MOCK_PENDING=1
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_KILL_FAILED ]
  [ "$(field '.verification.connection_present')" = 1 ]
}

@test "sessions preserves large transaction IDs exactly and rejects numeric identity fields" {
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 DRY_RUN=false CONFIRM=true \
    "EXPECTED_SESSION=$MOCK_FINGERPRINT" MOCK_TRX_ID=9007199254740993
  [ "$status" -eq 0 ]
  [ "$(field '.before.transaction_id')" = 9007199254740993 ]
  grep -q "WHERE TRX_ID='9007199254740993'" "$MOCK_SQL_LOG"
  : > "$MOCK_SQL_LOG"
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 MOCK_TRX_ID=9007199254740993 MOCK_NUMERIC_TRX_ID=1
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_INSPECTION_FAILED ]
  assert_no_kill
}

@test "sessions treats missing global counters as unavailable rather than zero" {
  run_sessions MOCK_NULL_STATUS=1
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = SESSION_DIAGNOSTICS_PARTIAL ]
  [ "$(field '.sections.connection_status.rows')" = null ]
}

@test "sessions refuses an inspection row for a different connection or invalid query identity" {
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 MOCK_ROW_ID=43
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_INSPECTION_FAILED ]
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 'MOCK_QUERY_ID=1;DROP TABLE example'
  [ "$status" -ne 0 ]
  [ "$(field '.reason_code')" = SESSION_INSPECTION_FAILED ]
  assert_no_kill
}

@test "sessions treats missing verification fields as unknown" {
  run_sessions SESSION_ACTION=kill-connection CONNECTION_ID=42 DRY_RUN=false CONFIRM=true \
    "EXPECTED_SESSION=$MOCK_FINGERPRINT" MOCK_EMPTY_VERIFY=1
  [ "$status" -eq 0 ]
  [ "$(field '.reason_code')" = SESSION_VERIFICATION_UNAVAILABLE ]
}
