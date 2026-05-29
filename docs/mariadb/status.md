# Task: status

Read-only MariaDB status summary for operator-managed and native StatefulSet
targets.

## Endpoint

```text
POST /tasks/status
```

Served by **aqsh-mariadb** on NodePort `30081`.

## Request

```json
{
  "namespace": "mariadb-1",
  "context": "",
  "resource": "mariadb",
  "mdb": "mariadb",
  "container": "mariadb",
  "include_sql": "true"
}
```

| Field | Env Var | Required | Default | Description |
|-------|---------|----------|---------|-------------|
| `namespace` | `DB_NAMESPACE` | yes | - | Target namespace |
| `context` | `K8S_CONTEXT` | no | current / in-cluster | Kubernetes context |
| `resource` | `MARIADB_RESOURCE` | no | `mariadb` | MariaDB CR kind |
| `mdb` | `MARIADB_NAME` | no | `mariadb` | MariaDB CR and StatefulSet name |
| `container` | `MARIADB_CONTAINER` | no | `mariadb` | MariaDB container name |
| `include_sql` | `INCLUDE_SQL` | no | `true` | Exec into pods to infer SQL role/readiness |

## Task Result

```json
{
  "status": "OK",
  "reason_code": "MARIADB_STATUS_OK",
  "summary": "MariaDB status is healthy",
  "target": {
    "context": "",
    "namespace": "mariadb-1",
    "resource": "mariadb",
    "mdb": "mariadb"
  },
  "operator": {
    "present": true,
    "ready": "True",
    "current_primary": "mariadb-0",
    "current_primary_pod_index": "0",
    "replicas": 3
  },
  "statefulset": {
    "present": true,
    "replicas": 3,
    "ready_replicas": 3,
    "observed_generation": 4,
    "update_strategy": "RollingUpdate"
  },
  "sql": {
    "checked": true,
    "root_password_available": true
  },
  "pods": [
    {
      "name": "mariadb-0",
      "phase": "Running",
      "ready": true,
      "restarts": 0,
      "role": "primary",
      "read_only": "0",
      "sql_ready": true
    }
  ]
}
```

`status` is `OK`, `WARN`, or `CRITICAL`. SQL collection is best effort; if
Kubernetes status is available but SQL credentials cannot be read, the task
returns `WARN` instead of failing the task process.
