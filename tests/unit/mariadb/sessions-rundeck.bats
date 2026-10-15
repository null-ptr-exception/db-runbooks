#!/usr/bin/env bats
setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  MOCK_DIR="$(mktemp -d)"
  export MOCK_HTTP_LOG="${MOCK_DIR}/requests.jsonl"
  cat > "${MOCK_DIR}/curl" <<'MOCK'
#!/usr/bin/env python3
import json, os, sys
args=sys.argv[1:]
url=args[-1]
if url.endswith('/tasks/sessions') and '--data' in args:
    body=json.loads(args[args.index('--data')+1])
    with open(os.environ['MOCK_HTTP_LOG'],'a') as f:
        f.write(json.dumps(body)+'\n')
    print(json.dumps({'id':os.environ.get('MOCK_EXECUTION_ID','execution-1')}))
elif url.endswith('/executions/execution-1') and '--data' not in args:
    if os.environ.get('MOCK_HTTP_FAIL'): sys.exit(22)
    result={'status':os.environ.get('MOCK_RESULT_STATUS','READY'),
            'reason_code':'UNIT_RESULT','changed':False}
    if os.environ.get('MOCK_STRING_RESULT'): result=json.dumps(result)
    print(json.dumps({'status':os.environ.get('MOCK_EXECUTION_STATUS','completed'),
                      'result':{'data':result}}))
else:
    raise SystemExit('unexpected HTTP request')
MOCK
  chmod +x "${MOCK_DIR}/curl"
}
teardown() { rm -rf "$MOCK_DIR"; }
run_client() {
  run env "PATH=${MOCK_DIR}:$PATH" AQSH_URL=https://aqsh.example AQSH_TOKEN=unit-only-token \
    RD_OPTION_NAMESPACE=mariadb-1 RD_OPTION_TARGET_POD=mariadb-1 "$@" \
    bash "${REPO_ROOT}/examples/rundeck/run-mariadb-sessions.sh"
}
@test "Rundeck client submits only the sessions route with safe diagnosis defaults" {
  run_client
  [ "$status" -eq 0 ]
  [ "$(jq -r .action "$MOCK_HTTP_LOG")" = diagnose ]
  [ "$(jq -r .dry_run "$MOCK_HTTP_LOG")" = true ]
  [ "$(jq -r .confirm "$MOCK_HTTP_LOG")" = false ]
  [[ "$output" != *unit-only-token* ]]
}
@test "Rundeck client preserves option text as data rather than executing shell" {
  run_client 'RD_OPTION_CONNECTION_ID=$(touch /tmp/session-should-not-exist)'
  [ "$status" -eq 0 ]
  [ "$(jq -r .connection_id "$MOCK_HTTP_LOG")" = '$(touch /tmp/session-should-not-exist)' ]
}
@test "Rundeck client decodes string task results and exposes pending verification" {
  run_client MOCK_STRING_RESULT=1 MOCK_RESULT_STATUS=PENDING
  [ "$status" -eq 0 ]
  [[ "$output" == *PENDING* ]]
}
@test "Rundeck client reports failed executions and blocked task results as failures" {
  run_client MOCK_EXECUTION_STATUS=failed
  [ "$status" -ne 0 ]
  run_client MOCK_RESULT_STATUS=BLOCKED
  [ "$status" -ne 0 ]
}
@test "Rundeck client rejects untrusted execution IDs without another request" {
  run_client 'MOCK_EXECUTION_ID=../../other-task'
  [ "$status" -ne 0 ]
  [[ "$output" == *'Invalid execution ID'* ]]
}
@test "Rundeck client does not resubmit a mutation when polling fails" {
  run_client RD_OPTION_ACTION=kill-connection RD_OPTION_DRY_RUN=false \
    RD_OPTION_CONFIRM=true RD_OPTION_CONNECTION_ID=42 MOCK_HTTP_FAIL=1
  [ "$status" -ne 0 ]
  [ "$(wc -l < "$MOCK_HTTP_LOG" | tr -d ' ')" = 1 ]
}
@test "Rundeck definition has one job and an enforced fixed action selector" {
  run python3 - "${REPO_ROOT}" <<'CHECK'
import sys
from pathlib import Path
# Structural validation uses the repo's documented YAML spelling without a
# production/test dependency on PyYAML (it is not required by preflight.sh).
p=Path(sys.argv[1])/'examples/rundeck/mariadb-sessions.yaml'
s=p.read_text()
assert s.count('- name: mariadb_sessions\n')==1
assert 'values: [diagnose, kill-query, kill-connection]' in s
assert 'value: diagnose' in s
assert 'enforced: true' in s
assert '- exec: /opt/db-runbooks/bin/run-mariadb-sessions.sh' in s
assert '@option.' not in s
CHECK
  [ "$status" -eq 0 ]
}
