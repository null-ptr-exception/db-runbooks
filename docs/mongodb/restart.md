# Task: restart (aqsh-mongodb)

Rolling restart of a MongoDB StatefulSet.

## Description

Triggers `kubectl rollout restart statefulset/mongodb` in the target namespace, then waits up to 5 minutes for the rollout to complete.

## Input

| Name | Env Var | Type | Required | Validation |
|------|---------|------|----------|-----------|
| `namespace` | `DB_NAMESPACE` | string | yes | `^mongo-[0-9]+$` |

Valid namespaces: `mongo-1`, `mongo-2`, `mongo-3`

## Output (written to `$AQSH_RESULT_FILE`)

```json
{
  "namespace":   "mongo-1",
  "statefulset": "mongodb",
  "replicas":    1
}
```

## Permissions

| Field | Value |
|-------|-------|
| `allowed_groups` | `system:serviceaccounts` |
| Timeout | 5 minutes |

RBAC: `aqsh-mongo-manager` ClusterRole grants `get` and `patch` on `statefulsets/mongodb` in `mongo-1/2/3`.

## API Example

```bash
TOKEN=$(kubectl --context kind-cluster-apps -n app-a create token test-client --duration=10m)
MONGODB_AQSH_URL="http://<cluster-dbs-ip>:30082"

# Submit
RESPONSE=$(curl -s -X POST "$MONGODB_AQSH_URL/tasks/restart" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mongo-1"}')

TASK_ID=$(echo "$RESPONSE" | jq -r '.id')
echo "Task ID: $TASK_ID"

# Poll
curl -s "$MONGODB_AQSH_URL/tasks/$TASK_ID" \
  -H "Authorization: Bearer $TOKEN" | jq .
```
