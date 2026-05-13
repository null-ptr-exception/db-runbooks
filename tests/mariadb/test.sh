#!/usr/bin/env bash
# =============================================================================
# tests/mariadb/test.sh
# MariaDB task tests:
#   - restart task submit + poll
#   - verify StatefulSet restarted
#
# Expects the following to be defined by the caller (scripts/test.sh):
#   MARIADB_AQSH_URL, TOKEN, CLUSTER_DBS_IP, pass(), fail(), run_cmd()
# =============================================================================

echo ""
echo "=== Test 7: MariaDB restart task (mariadb-1) ==="

echo "  \$ kubectl --context kind-cluster-dbs -n mariadb-1 get statefulset mariadb (before restart)"
BEFORE_GENERATION=$(kubectl --context kind-cluster-dbs -n mariadb-1 get statefulset mariadb -o jsonpath='{.status.observedGeneration}')
echo "  > observedGeneration=$BEFORE_GENERATION"

RESPONSE=$(curl -s -w '\n%{http_code}' \
  -X POST "${MARIADB_AQSH_URL}/tasks/restart" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mariadb-1"}')

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')
echo "  > HTTP $HTTP_CODE"
echo "  > $BODY"

if [ "$HTTP_CODE" = "202" ]; then
  pass "mariadb restart task submission returned 202"
else
  fail "mariadb restart task submission returned $HTTP_CODE (expected 202)"
fi

echo ""
echo "=== Test 8: MariaDB restart task completion (polling) ==="

RESTART_TASK_ID=$(echo "$BODY" | jq -r '.id' 2>/dev/null || true)

if [ -z "$RESTART_TASK_ID" ]; then
  fail "could not extract restart task ID from response"
else
  MAX_WAIT=300
  for i in $(seq 1 $MAX_WAIT); do
    STATUS=$(curl -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${MARIADB_AQSH_URL}/tasks/${RESTART_TASK_ID}" | jq -r '.status' 2>/dev/null || true)

    if [ "$((i % 10))" = "0" ] || [ "$STATUS" = "completed" ] || [ "$STATUS" = "failed" ]; then
      echo "  > status=$STATUS"
    fi

    if [ "$STATUS" = "completed" ]; then
      pass "mariadb restart task completed"
      break
    elif [ "$STATUS" = "failed" ]; then
      fail "mariadb restart task failed"
      break
    fi

    if [ "$i" = "$MAX_WAIT" ]; then
      fail "mariadb restart task did not complete within ${MAX_WAIT}s (status: $STATUS)"
    fi

    sleep 1
  done
fi

echo ""
echo "=== Test 9: Verify MariaDB StatefulSet restarted ==="

kubectl --context kind-cluster-dbs -n mariadb-1 wait pod -l app.kubernetes.io/name=mariadb \
  --for=condition=Ready --timeout=120s >/dev/null

AFTER_GENERATION=$(kubectl --context kind-cluster-dbs -n mariadb-1 get statefulset mariadb -o jsonpath='{.status.observedGeneration}')
READY=$(kubectl --context kind-cluster-dbs -n mariadb-1 get statefulset mariadb -o jsonpath='{.status.readyReplicas}')
REPLICAS=$(kubectl --context kind-cluster-dbs -n mariadb-1 get statefulset mariadb -o jsonpath='{.status.replicas}')
echo "  > observedGeneration=$AFTER_GENERATION (was $BEFORE_GENERATION)"
echo "  > replicas=$REPLICAS ready=$READY"

if [ "$AFTER_GENERATION" -gt "$BEFORE_GENERATION" ] 2>/dev/null; then
  pass "StatefulSet generation advanced ($BEFORE_GENERATION → $AFTER_GENERATION)"
else
  fail "StatefulSet generation did not advance (still $AFTER_GENERATION)"
fi

if [ "$READY" = "$REPLICAS" ] && [ "$READY" != "0" ]; then
  pass "all replicas ready ($READY/$REPLICAS)"
else
  fail "replicas not ready ($READY/$REPLICAS)"
fi
