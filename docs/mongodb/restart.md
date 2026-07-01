# Task: restart (aqsh-mongodb)

Rolling restart of a MongoDB StatefulSet.

## Description

Triggers `kubectl rollout restart statefulset` in the target namespace against
the resolved StatefulSet name (see "Input" below), then waits for the rollout
to complete. Behavior automatically adapts to the StatefulSet's
`updateStrategy`, detected live from the cluster — no caller input needed:

- `RollingUpdate` (default): waits via `kubectl rollout status`.
- `OnDelete`: an operator or human is expected to delete pods to pick up the
  new template; the task instead waits for pods matching a label selector
  (`app.kubernetes.io/name=<sts_name>` by default) to cycle through
  NotReady → Ready.

## Input

| Name | Env Var | Type | Required | Validation | Default |
|------|---------|------|----------|-----------|---------|
| `namespace` | `DB_NAMESPACE` | string | yes | `^[a-z0-9][a-z0-9-]*$` | — |
| `sts_name` | `MONGO_STS_NAME` | string | no | `^([a-z0-9][a-z0-9-]*)?$` | `""` (falls through to deployment convention) |

Valid namespace in this sandbox: `mongo-1`.

`sts_name` is an escape hatch for a caller who genuinely needs a different
StatefulSet name on a single call. When omitted (the normal case), the
StatefulSet name is resolved via the deployment's configuration layers (see
CLAUDE.md "Configuration Layers"):

1. Task input `sts_name`, if the caller explicitly passed one.
2. Internal config `MONGO_STS_NAME_DEFAULT` (`aqsh-tasks/config/mongodb.env`,
   commented out by default) — set once per deployment when its naming
   convention differs from the hardcoded fallback.
3. Hardcoded literal `mongodb`.

## Output (written to `$AQSH_RESULT_FILE`)

```json
{
  "namespace":   "mongo-1",
  "statefulset": "mongodb",
  "strategy":    "RollingUpdate",
  "ready":       1,
  "replicas":    1
}
```

`strategy` reflects the `updateStrategy` actually detected on the live
StatefulSet (`RollingUpdate` or `OnDelete`), not a caller input.

## Permissions

| Field | Value |
|-------|-------|
| `allowed_groups` | `system:serviceaccounts` |
| Task timeout | 8 minutes (`tasks-mongodb.yaml`) |
| Internal rollout-wait timeout | 300 seconds (5 minutes) — a separate, inner timeout inside `k8s_sts_restart`'s `kubectl rollout status` / `kubectl wait` calls; not currently configurable from this task |

RBAC: `aqsh-mongo-manager` ClusterRole (`tests/chart/templates/mongodb-rbac.yaml`)
grants, scoped to `mongo-1`/the target namespace:

- `statefulsets`: `get`, `patch` (resourceName pinned to the deployment's
  configured StatefulSet name) — drives `kubectl rollout restart`.
- `statefulsets`: `list`, `watch` (namespace-wide) — strategy/status detection.
- `pods`: `get`, `list`, `delete` — `restart` uses `get`/`list` to poll
  readiness; `delete` is used by other MongoDB tasks sharing this ClusterRole,
  not by `restart`.
- `pods/exec`: `create` — used by other MongoDB tasks sharing this
  ClusterRole, not by `restart`.
- `secrets`: `get` (pinned to the credential secret) — used by other MongoDB
  tasks, not by `restart`.
- `configmaps`: `get`, `patch` (pinned) and `create` (namespace-wide) — used
  by recovery tasks, not by `restart`.
- `persistentvolumeclaims`: `get` — used by sanity-check, not by `restart`.
- `events`: `get`, `list` — used by sanity-check, not by `restart`.

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
