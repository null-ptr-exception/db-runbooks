# MariaDB connection usage

`connection-usage` is a read-only, point-in-time view of client connections
grouped by MariaDB account. It answers questions such as "which account is using
the most connections right now?" without exposing raw process-list rows or SQL.

## Request

```json
{
  "namespace": "mariadb-1",
  "top": "10"
}
```

| Input | Required | Default | Notes |
|---|---:|---:|---|
| `namespace` | yes | — | MariaDB namespace. |
| `mdb` | no | auto-detect | Required only when the namespace contains multiple MariaDB instances. |
| `context` | no | in-cluster | Kubernetes context override. |
| `resource` | no | `mariadb` | MariaDB CR resource name. |
| `container` | no | `mariadb` | MariaDB container name. |
| `top` | no | `10` | Number of sorted accounts to return, from 1 to 50. |

The root credential is resolved from the managed MariaDB pod environment. It is
not a task input and is never returned.

## Response

```json
{
  "status": "READY",
  "reason_code": "CONNECTION_USAGE_READY",
  "snapshot_type": "point-in-time",
  "partial": false,
  "snapshot_at": "2026-07-15T04:00:00Z",
  "namespace": "mariadb-1",
  "mdb": "mariadb",
  "requested_pods": 3,
  "queried_pods": 3,
  "failed_pods": 0,
  "total_connections": 46,
  "connection_capacity": 450,
  "capacity_scope": "sum-of-queried-pods",
  "utilization_percent": 10.2,
  "account_count": 3,
  "top": 10,
  "accounts": [
    {
      "account": "order_service",
      "current_connections": 31,
      "active_connections": 7,
      "idle_connections": 24,
      "longest_active_seconds": 18,
      "pods": ["mariadb-0"],
      "share_percent": 67.4
    }
  ],
  "pods": [
    {
      "pod": "mariadb-0",
      "collected": true,
      "current_connections": 36,
      "max_connections": 150,
      "utilization_percent": 24
    }
  ],
  "warnings": [
    {
      "code": "ACCOUNT_CONNECTION_SHARE_HIGH",
      "account": "order_service",
      "share_percent": 67.4,
      "threshold_percent": 60
    }
  ]
}
```

`max_connections` is a per-server setting. For a multi-pod MariaDB instance,
`connection_capacity` is therefore the sum of the limits on successfully
queried pods. The response also preserves each pod's utilization so this
cluster-wide total is explainable.

`COMMAND = 'Sleep'` counts as idle. Other client commands count as active. The
task excludes its own SQL session, blank/internal users, `system user`, and the
event scheduler.

## Partial collection

Every selected MariaDB pod is queried. If one pod cannot be queried, the task
returns `status=PARTIAL`, `partial=true`, and a generic per-pod error. Aggregates
then cover only the successfully queried pods. If every pod query fails, the
task returns `status=ERROR` and exits non-zero.

## Security and limitations

The response never contains SQL text, connection IDs, client addresses, or
credentials. Account names are returned because they are the unit being
measured.

This API is an instantaneous snapshot. It cannot answer "which account was
highest during the last hour/day/week." Historical windows require periodic
sampling and a metrics backend; enabling Performance Schema is not part of this
task.
