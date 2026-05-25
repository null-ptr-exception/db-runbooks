#!/usr/bin/env bash
# =============================================================================
# examples/mariadb/sanity-check.sh
#
# End-to-end curl example for the sanity-check task (aqsh-mariadb).
# Corresponds to: docs/mariadb/sanity-check.md
#
# Prerequisites:
#   - kubectl configured with kind-cluster-apps context
#   - jq installed
#   - .env sourced (or CLUSTER_DBS_IP set manually)
#
# Usage:
#   source .env && bash examples/mariadb/sanity-check.sh
# =============================================================================
set -euo pipefail

MARIADB_AQSH_URL="http://${CLUSTER_DBS_IP:?set CLUSTER_DBS_IP or source .env}:30081"
NAMESPACE="${1:-mariadb-1}"
POLL_INTERVAL=3
POLL_MAX=30

echo ">>> Obtaining token from kind-cluster-apps / app-a / test-client ..."
TOKEN=$(kubectl --context kind-cluster-apps -n app-a \
  create token test-client --duration=10m)

echo ""
echo ">>> Submitting sanity-check for namespace=${NAMESPACE} ..."
SUBMIT=$(curl -s -w "\n%{http_code}" \
  -X POST "${MARIADB_AQSH_URL}/tasks/sanity-check" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"namespace\": \"${NAMESPACE}\", \"resource\": \"mariadb\", \"mdb\": \"mariadb\"}")

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

echo ""
echo ">>> Polling task status ..."
for i in $(seq 1 "$POLL_MAX"); do
  RESULT=$(curl -s "${MARIADB_AQSH_URL}/tasks/${TASK_ID}" \
    -H "Authorization: Bearer ${TOKEN}")
  STATUS=$(echo "$RESULT" | jq -r '.status')
  echo "  [${i}] status=${STATUS}"
  if [[ "$STATUS" == "completed" || "$STATUS" == "failed" ]]; then
    break
  fi
  sleep "$POLL_INTERVAL"
done

if [[ "${STATUS:-}" != "completed" && "${STATUS:-}" != "failed" ]]; then
  echo "ERROR: task ${TASK_ID} did not finish after $((POLL_MAX * POLL_INTERVAL))s (last status=${STATUS:-unknown})" >&2
  echo "$RESULT" | jq . >&2
  exit 1
fi

echo ""
echo ">>> Task result:"
echo "$RESULT" | jq .

echo ""
echo ">>> Task logs (SSE):"
curl -s "${MARIADB_AQSH_URL}/tasks/${TASK_ID}/logs?follow=false" \
  -H "Authorization: Bearer ${TOKEN}"
