# Task: restart (aqsh-mongodb)

Rolling restart of a MongoDB StatefulSet.

## Description

Triggers `kubectl rollout restart statefulset/mongodb` in the target namespace, then waits up to 5 minutes for the rollout to complete.

## Input

| Name | Env Var | Type | Required | Validation |
|------|---------|------|----------|-----------|
| `namespace` | `DB_NAMESPACE` | string | yes | `^mongo-[0-9]+$` |

Valid namespace in this sandbox: `mongo-1`.

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

RBAC: `aqsh-mongo-manager` ClusterRole grants `get` and `patch` on `statefulsets/mongodb` in `mongo-1`.

## API Example

Run from the `test-client` pod (`*.kind-a.test` only resolves inside the
clusters' own CoreDNS):

```bash
TOKEN=$(kubectl --context kind-cluster-b -n mongo-core create token test-client --duration=10m)

# Submit
RESPONSE=$(kubectl --context kind-cluster-b -n mongo-core exec deploy/test-client -- \
  curl -s -X POST "http://aqsh-mongodb.kind-a.test:30080/tasks/restart" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mongo-1"}')

TASK_ID=$(echo "$RESPONSE" | jq -r '.id')
echo "Task ID: $TASK_ID"

# Poll
kubectl --context kind-cluster-b -n mongo-core exec deploy/test-client -- \
  curl -s "http://aqsh-mongodb.kind-a.test:30080/executions/$TASK_ID" \
  -H "Authorization: Bearer $TOKEN" | jq .
```
