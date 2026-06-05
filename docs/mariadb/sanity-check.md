# Task: sanity-check

Read-only health check: MariaDB operator → Kubernetes service/pods → SQL primary
checks → replication → semi-sync.

## Description

The same implementation supports AQSH, Rundeck, and local shell. It does not
patch Kubernetes resources, start/stop replication, or write SQL data.

| Caller | Invocation style | Output |
|--------|------------------|--------|
| AQSH / step automator | `POST /tasks/sanity-check` | JSON result in AQSH task result, human summary in task logs |
| Rundeck | `sanity-check.sh --context ... --namespace ... --strict-exit` | Human log plus optional `--result-file` JSON |
| Local shell | `sanity-check.sh --context ... --namespace ... --json` | Machine-readable JSON on stdout |

The legacy AQSH task name `mariadb_sanity_check` and script
`operator-sanity-check.sh` remain available as compatibility aliases.

## Endpoint

```text
POST /tasks/sanity-check
```

Served by **aqsh-mariadb** on NodePort `30081`.

## Request

### Headers

| Header | Value |
|--------|-------|
| `Authorization` | `Bearer <token>` |
| `Content-Type` | `application/json` |

### Body

```json
{
  "namespace": "mariadb-1",
  "context": "",
  "resource": "mariadb",
  "mdb": "mariadb",
  "container": "mariadb",
  "lag_threshold": "1",
  "conn_warn_pct": "80",
  "long_tx_threshold": "10",
  "expected_version": "",
  "check_operator": "true",
  "check_pods": "true",
  "check_service": "true",
  "check_sql": "true",
  "check_replication": "true",
  "check_semi_sync": "true"
}
```

### Input Fields

| Field | Env Var | Type | Required | Default | Description |
|-------|---------|------|----------|---------|-------------|
| `namespace` | `DB_NAMESPACE` | string | **yes** | - | Target namespace |
| `context` | `K8S_CONTEXT` | string | no | current / in-cluster | Kubernetes context |
| `resource` | `MARIADB_RESOURCE` | string | no | `mariadb` | MariaDB CR kind |
| `mdb` | `MARIADB_NAME` | string | no | `mariadb` | MariaDB CR and StatefulSet name |
| `container` | `MARIADB_CONTAINER` | string | no | `mariadb` | MariaDB container name |
| `lag_threshold` | `LAG_THRESHOLD` | string | no | `1` | Max replica lag in seconds |
| `conn_warn_pct` | `CONN_WARN_PCT` | string | no | `80` | Connection utilization WARN threshold |
| `long_tx_threshold` | `LONG_TX_THRESHOLD` | string | no | `10` | Long transaction WARN threshold |
| `expected_version` | `EXPECTED_VERSION` | string | no | empty | Optional `@@version` substring |
| `check_operator` | `CHECK_OPERATOR` | string | no | `true` | Enable CR readiness and current-primary checks |
| `check_pods` | `CHECK_PODS` | string | no | `true` | Enable pod phase and container readiness checks |
| `check_service` | `CHECK_SERVICE` | string | no | `true` | Enable primary Service selector check |
| `check_sql` | `CHECK_SQL` | string | no | `true` | Enable primary SQL checks |
| `check_replication` | `CHECK_REPLICATION` | string | no | `true` | Enable replica replication checks |
| `check_semi_sync` | `CHECK_SEMI_SYNC` | string | no | `true` | Enable semi-sync checks |

AQSH task inputs are flat env mappings, so the ticket's nested `checks` object is
represented as the flat fields above.

## Response

### 202 Accepted

```json
{
  "id": "d5a00329-7870-482c-89c2-54ab9b8dec08",
  "queue": "mariadb",
  "status": "pending"
}
```

### Task Result (`GET /tasks/{id}`)

Once `status` is `completed`, the `result.data` field contains:

```json
{
  "status": "PASS",
  "reason_code": "SANITY_PASS",
  "summary": "MariaDB operator, service, SQL, replication, and semi-sync sanity checks passed",
  "target": {
    "context": "",
    "namespace": "mariadb-1",
    "resource": "mariadb",
    "mdb": "mariadb"
  },
  "thresholds": {
    "lag_sec": 1,
    "conn_warn_pct": 80,
    "long_tx_sec": 10
  },
  "counts": {
    "pass": 12,
    "warn": 0,
    "block": 0,
    "error": 0,
    "total": 12
  },
  "checks": [
    {
      "name": "cr_ready",
      "status": "PASS",
      "reason_code": "CR_READY",
      "detail": "Ready=True"
    }
  ]
}
```

| Status | Meaning |
|--------|---------|
| `PASS` | All required checks passed |
| `WARN` | Non-blocking risk found; review recommended |
| `BLOCK` | Required check failed; automated step should stop |
| `ERROR` | Invalid target, runtime failure, or check could not run |

The AQSH script exits `0` after writing structured `PASS`, `WARN`, or `BLOCK`
results so the step automator can branch on the JSON status. Use
`--strict-exit` for local/Rundeck jobs that should fail the process on `BLOCK`.

## Checks

### Operator / Kubernetes

- CR exists.
- CR `Ready=True`.
- `.status.currentPrimary` exists.
- `.status.currentPrimaryPodIndex` exists.
- Primary Service `<mdb>-primary` exists.
- Primary Service selector points to `.status.currentPrimary`.
- All MariaDB pods are `Running`.
- MariaDB container is ready.
- Pod restart count is included in output.

For single-replica standalone MariaDB resources, `<mdb>-primary` is treated as
not applicable because mariadb-operator may only create the regular and
headless Services.

### SQL / Primary

- `SELECT 1` succeeds on current primary.
- Primary `@@read_only=0`.
- `@@gtid_binlog_pos` can be read.
- Connection headroom is above threshold.
- Long transactions are reported as `WARN`.
- Optional `@@version` check when `expected_version` is provided.

### Replica / Replication

- Each replica returns `SHOW ALL SLAVES STATUS`.
- `Slave_IO_Running=Yes`.
- `Slave_SQL_Running=Yes`.
- `Last_IO_Error` empty.
- `Last_SQL_Error` empty.
- `Seconds_Behind_Master <= lag_threshold`.
- `Gtid_IO_Pos == Gtid_Slave_Pos` when available.
- Replica `@@read_only=1`.

### Semi-sync

- Primary `Rpl_semi_sync_master_status=ON`.
- Primary `Rpl_semi_sync_master_clients >= replica count`.
- Each replica `Rpl_semi_sync_slave_status=ON`.

Single-pod MariaDB deployments return `PASS` for replication and semi-sync as
not applicable.

## Permissions

| Resource | Verbs | Purpose |
|----------|-------|---------|
| `statefulsets` | `get`, `list`, `watch` | StatefulSet status and optional fallback replica discovery |
| `pods` | `get`, `list`, `watch` | Pod readiness and restart count checks |
| `pods/exec` | `create` | Read `MARIADB_ROOT_PASSWORD` and run SQL checks inside MariaDB containers |
| `services` | `get`, `list`, `watch` | Primary Service selector check |
| `mariadbs.k8s.mariadb.com` / `mariadbs.mariadb.mmontes.io` | `get`, `list`, `watch`, existing `patch` for restart task | MariaDB CR status checks and restart annotation patch |

The sanity-check task itself does not patch, update, delete, start replication,
stop replication, or write SQL data.

## Example

See [examples/mariadb/sanity-check.sh](../../examples/mariadb/sanity-check.sh)
for a runnable end-to-end script.

### CLI

Local JSON-only:

```bash
LIB_DIR="$PWD/aqsh-tasks/lib" \
  aqsh-tasks/scripts/mariadb/sanity-check.sh \
  --context kind-cluster-dbs \
  --namespace mariadb-1 \
  --resource mariadb \
  --mdb mariadb \
  --json | jq .
```

Rundeck-style strict exit with result file:

```bash
aqsh-tasks/scripts/mariadb/sanity-check.sh \
  --context kind-cluster-dbs \
  --namespace mariadb-1 \
  --resource mariadb \
  --mdb mariadb \
  --result-file /tmp/mariadb-sanity.json \
  --strict-exit
```

AQSH:

```bash
curl -s -X POST "$MARIADB_AQSH_URL/tasks/sanity-check" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "mariadb-1",
    "resource": "mariadb",
    "mdb": "mariadb",
    "lag_threshold": "1"
  }'
```

## Stable Reason Codes

Common reason codes include:

```text
SANITY_PASS
CR_NOT_FOUND
CR_NOT_READY
CURRENT_PRIMARY_EMPTY
CURRENT_PRIMARY_POD_INDEX_EMPTY
PRIMARY_SERVICE_MISSING
PRIMARY_SERVICE_SELECTOR_DRIFT
POD_NOT_READY
ROOT_PASSWORD_UNAVAILABLE
PRIMARY_SQL_UNREACHABLE
PRIMARY_READ_ONLY_UNEXPECTED
PRIMARY_GTID_EMPTY
REPLICA_STATUS_EMPTY
REPLICA_IO_NOT_RUNNING
REPLICA_SQL_NOT_RUNNING
REPLICA_IO_ERROR
REPLICA_SQL_ERROR
REPLICA_LAG_HIGH
REPLICA_RELAY_PENDING
REPLICA_NOT_READ_ONLY
SEMI_SYNC_MASTER_OFF
SEMI_SYNC_CLIENTS_LOW
SEMI_SYNC_SLAVE_OFF
CONN_HEADROOM_LOW
LONG_TRX_PRESENT
LONG_TRX_UNKNOWN
VERSION_MISMATCH
```
