#!/usr/bin/env bash
# =============================================================================
# examples/mongodb/sanity-check.sh
#
# End-to-end curl examples for the sanity-check task (aqsh-mongodb).
# Corresponds to: docs/mongodb/sanity-check.md
#
# Prerequisites:
#   - kubectl configured with kind-cluster-apps context
#   - jq installed
#   - .env sourced (or CLUSTER_DBS_IP set manually)
#
# Usage:
#   source .env && bash examples/mongodb/sanity-check.sh
# =============================================================================
set -euo pipefail

MONGODB_AQSH_URL="http://${CLUSTER_DBS_IP:?set CLUSTER_DBS_IP or source .env}:30082"
NAMESPACE="${1:-mongo-1}"
POLL_INTERVAL=3
POLL_MAX=30

# ── 1. Obtain a short-lived token ────────────────────────────────────────────
echo ">>> Obtaining token from kind-cluster-apps / app-a / test-client ..."
TOKEN=$(kubectl --context kind-cluster-apps -n app-a \
  create token test-client --duration=10m)

# ── 2. Submit task (minimal — all defaults) ──────────────────────────────────
echo ""
echo ">>> Submitting sanity-check for namespace=${NAMESPACE} ..."
SUBMIT=$(curl -s -w "\n%{http_code}" \
  -X POST "${MONGODB_AQSH_URL}/tasks/sanity-check" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"namespace\": \"${NAMESPACE}\"}")

HTTP_CODE=$(echo "$SUBMIT" | tail -1)
BODY=$(echo "$SUBMIT" | head -1)

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
  RESULT=$(curl -s "${MONGODB_AQSH_URL}/tasks/${TASK_ID}" \
    -H "Authorization: Bearer ${TOKEN}")
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
echo "$RESULT" | jq '{status, result: (.result.data | try fromjson catch .result)}'

# ── 5. Stream logs ───────────────────────────────────────────────────────────
echo ""
echo ">>> Task logs (SSE):"
curl -s "${MONGODB_AQSH_URL}/tasks/${TASK_ID}/logs?follow=false" \
  -H "Authorization: Bearer ${TOKEN}"

# ── 6. Override example — custom STS name + credential secret ────────────────
echo ""
echo ">>> Override example (custom sts_name + credential_secret, dry-run only):"
echo "    curl -s -X POST \"${MONGODB_AQSH_URL}/tasks/sanity-check\" \\"
echo "      -H \"Authorization: Bearer \$TOKEN\" \\"
echo "      -H \"Content-Type: application/json\" \\"
echo "      -d '{"
echo "        \"namespace\":          \"mongo-2\","
echo "        \"sts_name\":           \"mongodb\","
echo "        \"credential_secret\":  \"my-custom-secret\","
echo "        \"credential_user_key\":\"DB_USER\","
echo "        \"credential_pass_key\":\"DB_PASS\""
echo "      }'"
