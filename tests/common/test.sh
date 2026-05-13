#!/usr/bin/env bash
# =============================================================================
# tests/common/test.sh
# Common infrastructure tests:
#   - kube-federated-auth health
#   - unauthenticated 401
#   - common/hello task submit + poll + log streaming (aqsh-mariadb)
#   - common/hello smoke test (aqsh-mongodb)
#   - in-pod requests from cluster-apps
#
# Expects the following to be defined by the caller (scripts/test.sh):
#   MARIADB_AQSH_URL, MONGODB_AQSH_URL, FEDAUTH_URL, TOKEN, pass(), fail(), run_cmd()
# =============================================================================

echo "=== Test 1: kube-federated-auth health check ==="

run_cmd BODY curl -s "${FEDAUTH_URL}/health"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${FEDAUTH_URL}/health")
echo "  > HTTP $HTTP_CODE"
if [ "$HTTP_CODE" = "200" ]; then
  pass "kube-federated-auth /health returned 200"
else
  fail "kube-federated-auth /health returned $HTTP_CODE (expected 200)"
fi

echo ""
echo "=== Test 2a: Unauthenticated request to aqsh-mariadb ==="

run_cmd BODY curl -s "${MARIADB_AQSH_URL}/health"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${MARIADB_AQSH_URL}/health")
echo "  > HTTP $HTTP_CODE"
if [ "$HTTP_CODE" = "401" ]; then
  pass "unauthenticated request to aqsh-mariadb returned 401"
else
  fail "unauthenticated request to aqsh-mariadb returned $HTTP_CODE (expected 401)"
fi

echo ""
echo "=== Test 2b: Unauthenticated request to aqsh-mongodb ==="

run_cmd BODY curl -s "${MONGODB_AQSH_URL}/health"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${MONGODB_AQSH_URL}/health")
echo "  > HTTP $HTTP_CODE"
if [ "$HTTP_CODE" = "401" ]; then
  pass "unauthenticated request to aqsh-mongodb returned 401"
else
  fail "unauthenticated request to aqsh-mongodb returned $HTTP_CODE (expected 401)"
fi

echo ""
echo "=== Test 3: Authenticated task submission (common/hello via aqsh-mariadb) ==="

echo "  \$ kubectl --context kind-cluster-apps -n app-a create token test-client --duration=10m"
TOKEN=$(kubectl --context kind-cluster-apps -n app-a create token test-client --duration=10m)
echo "  > ${TOKEN:0:32}...${TOKEN: -16} (${#TOKEN} chars)"

RESPONSE=$(curl -s -w '\n%{http_code}' \
  -X POST "${MARIADB_AQSH_URL}/tasks/common%2Fhello" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name": "World"}')

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')
echo "  > HTTP $HTTP_CODE"
echo "  > $BODY"

if [ "$HTTP_CODE" = "202" ]; then
  pass "task submission to aqsh-mariadb returned 202"
else
  fail "task submission to aqsh-mariadb returned $HTTP_CODE (expected 202)"
fi

HELLO_TASK_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)

if [ -z "$HELLO_TASK_ID" ]; then
  fail "could not extract task ID from response"
  return
fi

echo ""
echo "=== Test 4: Task completion (polling) ==="

MAX_WAIT=30
for i in $(seq 1 $MAX_WAIT); do
  RESPONSE=$(curl -s \
    -H "Authorization: Bearer ${TOKEN}" \
    "${MARIADB_AQSH_URL}/tasks/${HELLO_TASK_ID}")

  STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)

  echo "  \$ curl -s ${MARIADB_AQSH_URL}/tasks/${HELLO_TASK_ID} -H 'Authorization: Bearer <token>'"
  echo "  > status=$STATUS"

  if [ "$STATUS" = "completed" ]; then
    echo "  > $RESPONSE" | python3 -c "import sys,json; json.dump(json.load(sys.stdin),sys.stdout,indent=2)" 2>/dev/null | sed 's/^/  > /' || echo "  > $RESPONSE"
    pass "task completed successfully"
    break
  elif [ "$STATUS" = "failed" ]; then
    echo "  > $RESPONSE"
    fail "task failed"
    break
  fi

  if [ "$i" = "$MAX_WAIT" ]; then
    fail "task did not complete within ${MAX_WAIT}s (status: $STATUS)"
  fi

  sleep 1
done

echo ""
echo "=== Test 5: Log streaming ==="

LOGS=$(curl -s -m 5 \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: text/event-stream" \
  "${MARIADB_AQSH_URL}/tasks/${HELLO_TASK_ID}/logs?follow=false" 2>/dev/null || true)
echo "$LOGS" | sed 's/^/  > /'

if echo "$LOGS" | grep -q "Hello, World!"; then
  pass "logs contain expected output"
else
  fail "logs missing expected output"
fi

echo ""
echo "=== Test 5b: common/hello smoke test via aqsh-mongodb ==="

RESPONSE=$(curl -s -w '\n%{http_code}' \
  -X POST "${MONGODB_AQSH_URL}/tasks/common%2Fhello" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name": "World"}')

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')
echo "  > HTTP $HTTP_CODE"
echo "  > $BODY"

if [ "$HTTP_CODE" = "202" ]; then
  pass "task submission to aqsh-mongodb returned 202"
else
  fail "task submission to aqsh-mongodb returned $HTTP_CODE (expected 202)"
fi

echo ""
echo "=== Test 6: In-pod test from cluster-apps (app-a) ==="

kubectl --context kind-cluster-apps -n app-a wait --for=condition=Ready pod -l app=test-client --timeout=120s >/dev/null
TEST_POD=$(kubectl --context kind-cluster-apps -n app-a get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')

IN_POD_RESPONSE=$(kubectl --context kind-cluster-apps -n app-a exec "$TEST_POD" -- \
  sh -c 'curl -s -w "\n%{http_code}" \
    -X POST "http://'"${CLUSTER_DBS_IP}"':30081/tasks/common%2Fhello" \
    -H "Authorization: Bearer $(cat /var/run/secrets/tokens/token)" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"from-pod\"}"' 2>/dev/null || echo -e "\n000")

IN_POD_CODE=$(echo "$IN_POD_RESPONSE" | tail -1)
IN_POD_BODY=$(echo "$IN_POD_RESPONSE" | sed '$d')
echo "  > HTTP $IN_POD_CODE (aqsh-mariadb :30081)"
echo "  > $IN_POD_BODY"

if [ "$IN_POD_CODE" = "202" ]; then
  pass "in-pod request to aqsh-mariadb returned 202"
else
  fail "in-pod request to aqsh-mariadb returned $IN_POD_CODE (expected 202)"
fi

IN_POD_RESPONSE=$(kubectl --context kind-cluster-apps -n app-a exec "$TEST_POD" -- \
  sh -c 'curl -s -w "\n%{http_code}" \
    -X POST "http://'"${CLUSTER_DBS_IP}"':30082/tasks/common%2Fhello" \
    -H "Authorization: Bearer $(cat /var/run/secrets/tokens/token)" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"from-pod\"}"' 2>/dev/null || echo -e "\n000")

IN_POD_CODE=$(echo "$IN_POD_RESPONSE" | tail -1)
IN_POD_BODY=$(echo "$IN_POD_RESPONSE" | sed '$d')
echo "  > HTTP $IN_POD_CODE (aqsh-mongodb :30082)"
echo "  > $IN_POD_BODY"

if [ "$IN_POD_CODE" = "202" ]; then
  pass "in-pod request to aqsh-mongodb returned 202"
else
  fail "in-pod request to aqsh-mongodb returned $IN_POD_CODE (expected 202)"
fi
