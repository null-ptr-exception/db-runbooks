# Task: restart (aqsh-mariadb)

Role-aware restart of a MariaDB cluster (mariadb-operator CR or native StatefulSet).

## Description

Unlike a blind `kubectl rollout restart`, this task understands MariaDB roles
and is conservative by default:

- It discovers the current primary and replicas before touching anything.
- It restarts **replicas first**, one pod at a time (`kubectl delete pod`),
  waiting for each pod to become Ready before moving on — so the cluster is
  never degraded by more than one intentional pod at a time.
- The **primary is excluded by default**. It is restarted last, and only when
  `include_primary=true`.
- It runs in **dry-run by default**: it prints the planned `restart_order` and
  changes nothing. An actual restart requires `dry_run=false` **and**
  `confirm=true`.
- After the operation it compares the primary before and after. An unexpected
  primary move is reported as `ROLE_CHANGED` (status `ERROR`), unless
  `allow_role_change=true`, in which case it is a `WARN`.

This task does **not** promote replicas or patch operator/Service state. Use
[`promote-replica`](./promote-replica.md) for an explicit role change.

## Input

| Name | Env Var | Type | Required | Default | Notes |
|------|---------|------|----------|---------|-------|
| `namespace` | `DB_NAMESPACE` | string | yes | — | Validated `^mariadb-[0-9]+$` |
| `context` | `K8S_CONTEXT` | string | no | `""` | Optional for in-cluster AQSH |
| `resource` | `MARIADB_RESOURCE` | string | no | `mariadb` | MariaDB CR kind |
| `mdb` | `MARIADB_NAME` | string | no | `mariadb` | CR / StatefulSet name |
| `container` | `MARIADB_CONTAINER` | string | no | `mariadb` | MariaDB container name |
| `target_pod` | `TARGET_POD` | string | no | `""` | Restart only this pod |
| `include_primary` | `INCLUDE_PRIMARY` | string | no | `false` | Allow restarting the primary |
| `allow_role_change` | `ALLOW_ROLE_CHANGE` | string | no | `false` | Tolerate a primary move |
| `wait_timeout` | `WAIT_TIMEOUT` | string | no | `300` | Per-pod readiness timeout (s) |
| `dry_run` | `DRY_RUN` | string | no | `true` | Plan only, change nothing |
| `confirm` | `CONFIRM` | string | no | `false` | Required with `dry_run=false` |

Valid namespaces: `mariadb-1`, `mariadb-2`, `mariadb-3`

## Output (written to `$AQSH_RESULT_FILE`)

```json
{
  "status": "READY",
  "reason_code": "RESTART_DRY_RUN",
  "summary": "Dry-run made no changes; restart_order lists the planned per-pod restart sequence",
  "target": {
    "context": "kind-cluster-dbs",
    "namespace": "mariadb-1",
    "resource": "mariadb",
    "mdb": "mariadb",
    "update_strategy": "OnDelete"
  },
  "dry_run": true,
  "confirm": false,
  "include_primary": false,
  "allow_role_change": false,
  "changed": false,
  "primary_before": "mariadb-0",
  "primary_after": null,
  "restart_order": ["mariadb-1"],
  "pods": [
    {"name": "mariadb-0", "role": "primary", "ready_before": true, "restarted": false, "ready_after": null},
    {"name": "mariadb-1", "role": "replica", "ready_before": true, "restarted": false, "ready_after": null}
  ]
}
```

### Status / reason_code matrix

| status | reason_code | Meaning |
|--------|-------------|---------|
| `READY` | `RESTART_DRY_RUN` | Dry-run plan; `restart_order` holds the planned sequence |
| `RESTARTED` | `RESTART_COMPLETED` | All selected pods restarted and Ready; primary unchanged |
| `WARN` | `ROLE_CHANGED` | Restart done but primary moved; tolerated via `allow_role_change` |
| `BLOCKED` | `RESTART_CONFIRM_REQUIRED` | `dry_run=false` without `confirm=true` |
| `BLOCKED` | `MARIADB_NOT_FOUND` | No StatefulSet and no pods found |
| `BLOCKED` | `TARGET_POD_NOT_FOUND` | `target_pod` is not part of the cluster |
| `BLOCKED` | `PRIMARY_RESTART_NOT_ALLOWED` | `target_pod` is the primary and `include_primary=false` |
| `BLOCKED` | `NO_RESTART_TARGETS` | Only the primary exists and it is excluded |
| `BLOCKED` | `PRIMARY_UNKNOWN` | `include_primary=true` but primary cannot be identified |
| `BLOCKED` | `PEER_POD_NOT_READY` | A pod outside the restart set is not Ready (cluster degraded) |
| `ERROR` | `ROLE_CHANGED` | Primary moved unexpectedly (`allow_role_change=false`) |
| `ERROR` | `RESTART_POD_NOT_READY` | A pod did not become Ready within `wait_timeout` |
| `ERROR` | `KUBECTL_UNAVAILABLE` | Kubernetes API not reachable |

All non-`ERROR`-on-infra outcomes are reported with task status `completed` and a
structured result; the script exits `0` so callers branch on `status` /
`reason_code`, not the process exit code.

## Permissions

| Field | Value |
|-------|-------|
| `allowed_groups` | `system:serviceaccounts` |
| Timeout | 8 minutes |

RBAC: the `aqsh-mariadb-manager` ClusterRole must allow `get`/`list` on
`mariadbs`, `statefulsets`, and `pods`, `delete` on `pods`, and `create` on
`pods/exec` (for SQL role probes) in `mariadb-1/2/3`.

## API Example

```bash
TOKEN=$(kubectl --context kind-cluster-apps -n app-a create token test-client --duration=10m)
MARIADB_AQSH_URL="http://<cluster-dbs-ip>:30081"

# 1. Dry-run: see the planned restart order (default; changes nothing)
curl -s -X POST "$MARIADB_AQSH_URL/tasks/restart" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mariadb-1"}'

# 2. Execute: restart replicas, keep the primary
curl -s -X POST "$MARIADB_AQSH_URL/tasks/restart" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mariadb-1", "dry_run": "false", "confirm": "true"}'

# 3. Restart a single pod
curl -s -X POST "$MARIADB_AQSH_URL/tasks/restart" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mariadb-1", "target_pod": "mariadb-1", "dry_run": "false", "confirm": "true"}'
```

## Error Cases

| Scenario | Behaviour |
|----------|-----------|
| Namespace does not match pattern | aqsh rejects with 400 before task runs |
| MariaDB not found | `status=BLOCKED`, `reason_code=MARIADB_NOT_FOUND` |
| Restart requested without confirm | `status=BLOCKED`, `reason_code=RESTART_CONFIRM_REQUIRED` |
| Primary targeted without `include_primary` | `status=BLOCKED`, `reason_code=PRIMARY_RESTART_NOT_ALLOWED` |
| Peer pod already down | `status=BLOCKED`, `reason_code=PEER_POD_NOT_READY` |
| Pod never becomes Ready | `status=ERROR`, `reason_code=RESTART_POD_NOT_READY` |
| Primary moves unexpectedly | `status=ERROR`, `reason_code=ROLE_CHANGED` |
