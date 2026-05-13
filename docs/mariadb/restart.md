# Task: restart (aqsh-mariadb)

Rolling restart of a MariaDB StatefulSet managed by mariadb-operator.

## Description

Triggers `kubectl rollout restart statefulset/mariadb` in the target namespace, then waits up to 5 minutes for the rollout to complete.

## Input

| Name | Env Var | Type | Required | Validation |
|------|---------|------|----------|-----------|
| `namespace` | `DB_NAMESPACE` | string | yes | `^mariadb-[0-9]+$` |

Valid namespaces: `mariadb-1`, `mariadb-2`, `mariadb-3`

## Output (written to `$AQSH_RESULT_FILE`)

```json
{
  "namespace":   "mariadb-1",
  "statefulset": "mariadb",
  "replicas":    1
}
```

## Permissions

| Field | Value |
|-------|-------|
| `allowed_groups` | `system:serviceaccounts` |
| Timeout | 5 minutes |

RBAC: `aqsh-mariadb-manager` ClusterRole grants `get` and `patch` on `statefulsets/mariadb` in `mariadb-1/2/3`.

## API Example

```bash
TOKEN=$(kubectl --context kind-cluster-apps -n app-a create token test-client --duration=10m)
MARIADB_AQSH_URL="http://<cluster-dbs-ip>:30081"

# Submit
RESPONSE=$(curl -s -X POST "$MARIADB_AQSH_URL/tasks/restart" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mariadb-1"}')

TASK_ID=$(echo "$RESPONSE" | jq -r '.id')
echo "Task ID: $TASK_ID"

# Poll for completion
curl -s "$MARIADB_AQSH_URL/tasks/$TASK_ID" \
  -H "Authorization: Bearer $TOKEN" | jq .

# Stream logs
curl -s "$MARIADB_AQSH_URL/tasks/$TASK_ID/logs?follow=false" \
  -H "Authorization: Bearer $TOKEN"
```

## Error Cases

| Scenario | Behaviour |
|----------|-----------|
| Namespace does not match pattern | aqsh rejects with 400 before task runs |
| StatefulSet not found | `kubectl` exits non-zero; task status becomes `failed` |
| Rollout does not complete within 5 min | `kubectl rollout status --timeout=300s` exits non-zero; task fails |
