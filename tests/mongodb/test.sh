#!/usr/bin/env bash
# =============================================================================
# tests/mongodb/test.sh
# MongoDB task tests:
#   - sanity-check task submit + poll
#   - restart task submit + poll
#   - verify MongoDB StatefulSet restarted
#
# Expects the following to be defined by the caller (scripts/test.sh):
#   MONGODB_AQSH_URL, TOKEN, CLUSTER_DBS_IP, pass(), fail(), run_cmd()
# =============================================================================

echo ""
echo "=== Test 10: MongoDB sanity-check task (mongo-1) ==="

RESPONSE=$(curl -s -w '\n%{http_code}' \
  -X POST "${MONGODB_AQSH_URL}/tasks/sanity-check" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mongo-1"}')

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')
echo "  > HTTP $HTTP_CODE"
echo "  > $BODY"

if [ "$HTTP_CODE" = "202" ]; then
  pass "mongo sanity-check task submission returned 202"
else
  fail "mongo sanity-check task submission returned $HTTP_CODE (expected 202)"
fi

SANITY_TASK_ID=$(echo "$BODY" | jq -r '.id' 2>/dev/null || true)

if [ -n "$SANITY_TASK_ID" ]; then
  MAX_WAIT=300
  for i in $(seq 1 $MAX_WAIT); do
    SANITY_RESP=$(curl -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${MONGODB_AQSH_URL}/tasks/${SANITY_TASK_ID}")
    STATUS=$(echo "$SANITY_RESP" | jq -r '.status' 2>/dev/null || true)

    if [ "$((i % 15))" = "0" ] || [ "$STATUS" = "completed" ] || [ "$STATUS" = "failed" ]; then
      echo "  > status=$STATUS"
    fi

    if [ "$STATUS" = "completed" ]; then
      RESULT_STATUS=$(echo "$SANITY_RESP" | jq -r '.result.status // "unknown"' 2>/dev/null || true)
      PASS_COUNT=$(echo "$SANITY_RESP"    | jq -r '.result.pass  // 0'          2>/dev/null || true)
      WARN_COUNT=$(echo "$SANITY_RESP"    | jq -r '.result.warn  // 0'          2>/dev/null || true)
      FAIL_COUNT=$(echo "$SANITY_RESP"    | jq -r '.result.fail  // 0'          2>/dev/null || true)
      echo "  > sanity result: status=$RESULT_STATUS pass=$PASS_COUNT warn=$WARN_COUNT fail=$FAIL_COUNT"
      if [ "$RESULT_STATUS" = "critical" ]; then
        fail "mongo sanity-check reported critical issues (fail=$FAIL_COUNT)"
      else
        pass "mongo sanity-check completed (status=$RESULT_STATUS)"
      fi
      break
    elif [ "$STATUS" = "failed" ]; then
      fail "mongo sanity-check task execution failed"
      break
    fi

    if [ "$i" = "$MAX_WAIT" ]; then
      fail "mongo sanity-check did not complete within ${MAX_WAIT}s (status: $STATUS)"
    fi

    sleep 1
  done
fi

echo ""
echo "=== Test 11: MongoDB restart task (mongo-1) ==="

BEFORE_GENERATION=$(kubectl --context kind-cluster-dbs -n mongo-1 get statefulset mongodb -o jsonpath='{.status.observedGeneration}')
echo "  > observedGeneration=$BEFORE_GENERATION"

RESPONSE=$(curl -s -w '\n%{http_code}' \
  -X POST "${MONGODB_AQSH_URL}/tasks/restart" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mongo-1"}')

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')
echo "  > HTTP $HTTP_CODE"
echo "  > $BODY"

if [ "$HTTP_CODE" = "202" ]; then
  pass "mongo restart task submission returned 202"
else
  fail "mongo restart task submission returned $HTTP_CODE (expected 202)"
fi

MONGO_RESTART_TASK_ID=$(echo "$BODY" | jq -r '.id' 2>/dev/null || true)

if [ -n "$MONGO_RESTART_TASK_ID" ]; then
  MAX_WAIT=300
  for i in $(seq 1 $MAX_WAIT); do
    STATUS=$(curl -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${MONGODB_AQSH_URL}/tasks/${MONGO_RESTART_TASK_ID}" | jq -r '.status' 2>/dev/null || true)

    if [ "$((i % 10))" = "0" ] || [ "$STATUS" = "completed" ] || [ "$STATUS" = "failed" ]; then
      echo "  > status=$STATUS"
    fi

    if [ "$STATUS" = "completed" ]; then
      pass "mongo restart task completed"
      break
    elif [ "$STATUS" = "failed" ]; then
      fail "mongo restart task failed"
      break
    fi

    if [ "$i" = "$MAX_WAIT" ]; then
      fail "mongo restart task did not complete within ${MAX_WAIT}s (status: $STATUS)"
    fi

    sleep 1
  done
fi

echo ""
echo "=== Test 12: Verify MongoDB StatefulSet restarted ==="

kubectl --context kind-cluster-dbs -n mongo-1 wait pod -l app=mongodb \
  --for=condition=Ready --timeout=120s >/dev/null

AFTER_GENERATION=$(kubectl --context kind-cluster-dbs -n mongo-1 get statefulset mongodb -o jsonpath='{.status.observedGeneration}')
READY=$(kubectl --context kind-cluster-dbs -n mongo-1 get statefulset mongodb -o jsonpath='{.status.readyReplicas}')
REPLICAS=$(kubectl --context kind-cluster-dbs -n mongo-1 get statefulset mongodb -o jsonpath='{.status.replicas}')
echo "  > observedGeneration=$AFTER_GENERATION (was $BEFORE_GENERATION)"
echo "  > replicas=$REPLICAS ready=$READY"

if [ "$AFTER_GENERATION" -gt "$BEFORE_GENERATION" ] 2>/dev/null; then
  pass "MongoDB StatefulSet generation advanced ($BEFORE_GENERATION → $AFTER_GENERATION)"
else
  fail "MongoDB StatefulSet generation did not advance (still $AFTER_GENERATION)"
fi

if [ "$READY" = "$REPLICAS" ] && [ "$READY" != "0" ]; then
  pass "all MongoDB replicas ready ($READY/$REPLICAS)"
else
  fail "MongoDB replicas not ready ($READY/$REPLICAS)"
fi
