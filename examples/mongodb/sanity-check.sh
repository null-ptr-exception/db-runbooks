#!/usr/bin/env bash
# =============================================================================
# examples/mongodb/sanity-check.sh
#
# End-to-end curl examples for the sanity-check task (aqsh-mongodb).
# Corresponds to: docs/mongodb/sanity-check.md
#
# Prerequisites:
#   - tests/mongodb/ suite already deployed (bats tests/mongodb/ or its
#     setup_suite.bash), since this reuses the live test-client pod and the
#     Istio gateway's *.kind-a.test routing (only resolvable from inside the
#     clusters' own CoreDNS — calls run via `kubectl exec` into test-client).
#   - jq installed
#
# Usage:
#   bash examples/mongodb/sanity-check.sh [namespace]
# =============================================================================
set -euo pipefail

CTX_B="kind-cluster-b"
NS="mongo-core"
AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"
NAMESPACE="${1:-mongo-1}"
POLL_INTERVAL=3
POLL_MAX=30

kexec() {
  kubectl --context "$CTX_B" -n "$NS" exec deploy/test-client -- sh -c "$1"
}

# ── 1. Obtain a short-lived token ────────────────────────────────────────────
echo ">>> Obtaining token from ${CTX_B} / ${NS} / test-client ..."
TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=10m)

# ── 2. Submit task (minimal — all defaults) ──────────────────────────────────
echo ""
echo ">>> Submitting sanity-check for namespace=${NAMESPACE} ..."
SUBMIT=$(kexec "curl -s -w '\\n%{http_code}' \
  -X POST '${AQSH_URL}/tasks/sanity-check' \
  -H 'Authorization: Bearer ${TOKEN}' \
  -H 'Content-Type: application/json' \
  -d '{\"namespace\": \"${NAMESPACE}\"}'")

HTTP_CODE=$(echo "$SUBMIT" | tail -1)
BODY=$(echo "$SUBMIT" | sed '$d')

echo "HTTP ${HTTP_CODE}"
echo "$BODY" | jq .

if [[ "$HTTP_CODE" != "202" ]]; then
  echo "ERROR: expected 202, got ${HTTP_CODE}" >&2
  exit 1
fi

TASK_ID=$(echo "$BODY" | jq -r '.id')
echo ""
echo "Task ID: ${TASK_ID}"

# ── 3. Poll until completed ──────────────────────────────────────────────────
echo ""
echo ">>> Polling task status ..."
for i in $(seq 1 "$POLL_MAX"); do
  RESULT=$(kexec "curl -s '${AQSH_URL}/executions/${TASK_ID}' \
    -H 'Authorization: Bearer ${TOKEN}'")
  STATUS=$(echo "$RESULT" | jq -r '.status')
  echo "  [${i}] status=${STATUS}"
  if [[ "$STATUS" == "completed" || "$STATUS" == "failed" ]]; then
    break
  fi
  sleep "$POLL_INTERVAL"
done

# ── 4. Print task result ─────────────────────────────────────────────────────
echo ""
echo ">>> Task result:"
echo "$RESULT" | jq '{status, result: (.result.data // empty)}'

# ── 5. Override example — custom STS name + credential secret ───────────────
echo ""
echo ">>> Override example (custom sts_name + credential_secret, not run):"
echo "    curl -s -X POST \"${AQSH_URL}/tasks/sanity-check\" \\"
echo "      -H \"Authorization: Bearer \$TOKEN\" \\"
echo "      -H \"Content-Type: application/json\" \\"
echo "      -d '{"
echo "        \"namespace\":          \"mongo-1\","
echo "        \"sts_name\":           \"mongodb\","
echo "        \"credential_secret\":  \"my-custom-secret\","
echo "        \"credential_user_key\":\"DB_USER\","
echo "        \"credential_pass_key\":\"DB_PASS\""
echo "      }'"
