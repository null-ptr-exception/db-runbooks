# MariaDB connection usage

`connection-usage` is a read-only, point-in-time view of client connections
grouped by MariaDB account. It answers questions such as "which account is using
the most connections right now?" without exposing raw process-list rows or SQL.

## Request

```json
{
  "namespace": "mariadb-1",
  "account_limit": "10"
}
```

| Input | Required | Default | Notes |
|---|---:|---:|---|
| `namespace` | yes | — | Namespace containing exactly one MariaDB instance. |
| `account_limit` | no | `10` | Maximum number of accounts to return, from 1 to 50. |

The task auto-detects the MariaDB instance from `namespace`. If the namespace
contains no instance or more than one instance, it fails closed instead of
asking callers to identify Kubernetes resources or containers.

The root credential is resolved from the managed MariaDB pod environment. It is
not a task input and is never returned.

## Response

```json
{
  "status": "READY",
  "reason_code": "CONNECTION_USAGE_READY",
  "snapshot_type": "point-in-time",
  "partial": false,
  "snapshot_at": "2026-07-16T01:30:00Z",
  "namespace": "mariadb-1",
  "requested_pods": 2,
  "queried_pods": 2,
  "failed_pods": 0,
  "total_connections": 120,
  "connection_capacity": 300,
  "capacity_scope": "sum-of-queried-pods",
  "utilization_percent": 40,
  "total_account_count": 2,
  "returned_account_count": 2,
  "account_limit": 10,
  "truncated": false,
  "accounts": [
    {
      "account": "order_service",
      "current_connections": 100,
      "active_connections": 12,
      "idle_connections": 88,
      "longest_active_seconds": 18,
      "pods": ["mariadb-0", "mariadb-1"],
      "share_percent": 83.3
    },
    {
      "account": "report_service",
      "current_connections": 20,
      "active_connections": 3,
      "idle_connections": 17,
      "longest_active_seconds": 5,
      "pods": ["mariadb-1"],
      "share_percent": 16.7
    }
  ],
  "pods": [
    {
      "pod": "mariadb-0",
      "collected": true,
      "current_connections": 70,
      "max_connections": 150,
      "utilization_percent": 46.7
    },
    {
      "pod": "mariadb-1",
      "collected": true,
      "current_connections": 50,
      "max_connections": 150,
      "utilization_percent": 33.3
    }
  ],
  "warnings": [
    {
      "code": "ACCOUNT_CONNECTION_SHARE_HIGH",
      "account": "order_service",
      "share_percent": 83.3,
      "threshold_percent": 60
    }
  ]
}
```

`accounts` is sorted by `current_connections` from highest to lowest. Ties are
sorted by account name so repeated snapshots are deterministic.
`account_limit` only limits the returned `accounts` array; totals, utilization,
warnings, and pod collection still use every observed account.

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
