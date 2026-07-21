# MongoDB Oplog Gateway (aqsh-mongodb)

`oplog/status` and `oplog/resize` manage the replica set's **oplog** —
`local.oplog.rs`, the capped collection every member replays writes from.
Its size caps how far a secondary can fall behind before it needs a full
resync (the "replication window"). `oplog/resize` runs MongoDB's documented
`replSetResizeOplog` admin command to grow or shrink it live, with no
restart.

**Oplog size is per-node state, not cluster-wide.** `replSetResizeOplog`
only resizes the oplog of the member you run it against — it does not
propagate to the rest of the replica set. `oplog/status` therefore always
reports every current member individually, and `oplog/resize` always
applies the change to every current member itself; there is no `target_pod`
input on either task, because "resize just the primary" would silently
leave secondaries at their old size.

Deployment naming/credential conventions (StatefulSet name, credential
secret and keys) are **not task inputs** — they resolve via internal config
→ live-cluster auto-detect → hardcoded fallback, exactly like `recovery/*`
and `fcv/*` (see CLAUDE.md "Configuration Layers"). Both official
(`MONGO_INITDB_ROOT_*`) and Bitnami (`MONGODB_ROOT_*`, including
file-mounted `*_FILE` secrets) credential conventions are detected from the
live StatefulSet spec.

## Table of Contents

1. [Architecture & Flow](#architecture--flow)
2. [API Reference](#api-reference)
3. [Usage Scenarios](#usage-scenarios)
4. [MongoDB Privileges](#mongodb-privileges)
5. [Deployment Settings (Internal Config)](#deployment-settings-internal-config)
6. [RBAC Requirements](#rbac-requirements)

---

## Architecture & Flow

```
Operator / test-client (cluster-b)
     │  POST /tasks/oplog%2Fresize   {namespace, target_size_mb, dry_run, confirm}
     ▼
aqsh (mongo-core, cluster-a) → mongodb/oplog/resize.sh
     │ 1. gate: dry_run/confirm triad + positive-integer target_size_mb
     │ 2. resolve (3-tier, no task inputs): sts_name, credentials
     │ 3. kubectl get pods → probe pod (first Ready, fallback Running)
     │ 4. kubectl exec probe → mongosh rs.status() → every member's host:port
     │ 5. for EACH member: kubectl exec probe → mongosh directConnection
     │      db.getReplicationInfo()                              (read, preview)
     │ 6. dry_run? → DRY_RUN_READY per-member preview and stop
     │ 7. for EACH member: kubectl exec probe → mongosh directConnection
     │      adminCommand({replSetResizeOplog, size})              (write)
     │ 8. any member failed? → OPLOG_RESIZE_PARTIAL_FAILURE, listing exactly
     │      which hosts succeeded/failed so the caller can retry precisely
     ▼
result JSON → task .result.data
```

`oplog/status` is steps 2–5 only, ending in a read-only per-member report
(no `target_size_mb`/gate).

Debug visibility: the resolved StatefulSet/credentials, probe pod, the
member host list, and each raw mongosh sentinel line are logged at DEBUG
level — set `LOG_LEVEL=DEBUG` on the call (or the aqsh container) to see
them.

---

## API Reference

Base URL (sandbox): `http://aqsh-mongodb.kind-a.test:30080`. Slash-named
tasks are URL-encoded: `POST /tasks/oplog%2Fstatus`, `POST /tasks/oplog%2Fresize`.

### `oplog/status` — read-only report

| Input | Required | Meaning |
|---|---|---|
| `namespace` | yes | Namespace of the MongoDB StatefulSet |

Result (`.result.data`):

```json
{
  "namespace": "mongo-1",
  "sts": "mongodb",
  "members": [
    {"host": "mongodb-0.mongodb.mongo-1.svc.cluster.local:27017", "size_mb": 990, "used_mb": 512, "window_hours": 36.2},
    {"host": "mongodb-1.mongodb.mongo-1.svc.cluster.local:27017", "size_mb": 990, "used_mb": 498, "window_hours": 35.9},
    {"host": "mongodb-2.mongodb.mongo-1.svc.cluster.local:27017", "size_mb": 990, "used_mb": 505, "window_hours": 36.0}
  ],
  "min_window_hours": 35.9
}
```

`min_window_hours` is the binding constraint across the set — the member
with the smallest window is the one that determines how long a secondary
can be offline before it needs a full resync. A member that doesn't answer
is silently omitted from `members` rather than failing the whole call; the
task only fails outright when **no** member answers at all.

### `oplog/resize` — gated mutation (dry_run → confirm), applies to every member

| Input | Required | Default | Meaning |
|---|---|---|---|
| `namespace` | yes | — | Namespace of the MongoDB StatefulSet |
| `target_size_mb` | yes | — | Requested oplog size in MB, applied to every member |
| `dry_run` | no | `"true"` | Preview per-member current size only; nothing is changed |
| `confirm` | no | `"false"` | Must be `"true"` when `dry_run` is `"false"` |

Gate rules (identical to `fcv/set`): `dry_run=true` (default) previews;
`dry_run=true` + `confirm=true` is rejected; `dry_run=false` without
`confirm=true` is rejected. No minimum `target_size_mb` is enforced by this
task — MongoDB's own floor (which has moved across server versions) is the
source of truth, surfaced verbatim in `OPLOG_RESIZE_PARTIAL_FAILURE` when a
member rejects too-small a value.

Success result:

```json
{
  "status": "ok",
  "reason_code": "OPLOG_RESIZED",
  "summary": "Oplog resized to 2048MB on all members.",
  "namespace": "mongo-1",
  "target_size_mb": 2048,
  "members": [
    {"host": "mongodb-0.mongodb.mongo-1.svc.cluster.local:27017", "ok": true},
    {"host": "mongodb-1.mongodb.mongo-1.svc.cluster.local:27017", "ok": true},
    {"host": "mongodb-2.mongodb.mongo-1.svc.cluster.local:27017", "ok": true}
  ],
  "changed": true
}
```

Partial-failure result (`OPLOG_RESIZE_PARTIAL_FAILURE`) lists every member
with its own `ok`/`error` so the caller knows exactly which hosts still
need the resize retried — it never rolls back the members that already
succeeded.

### Result codes

| `reason_code` | Task status | Trigger |
|---|---|---|
| `OPLOG_RESIZED` | completed | `replSetResizeOplog` succeeded on every current member |
| `DRY_RUN_READY` | completed | Preview only; nothing changed |
| `OPLOG_RESIZE_PARTIAL_FAILURE` | failed | At least one member rejected the resize — `details.members` lists which |
| `INVALID_INPUT` | failed | Gate violation, or `target_size_mb` isn't a positive integer |
| `NO_PRIMARY` | failed | No Ready/Running pod, or no member answered `rs.status()`/an oplog status query |

---

## Usage Scenarios

### 1. Check the current window before deciding whether to resize

```json
POST /tasks/oplog%2Fstatus
{"namespace": "mongo-1"}
```

### 2. Extend the oplog ahead of a long-running batch job or maintenance window

```json
POST /tasks/oplog%2Fresize
{"namespace": "mongo-1", "target_size_mb": 4096}
```

Returns `DRY_RUN_READY` with each member's current size. Then execute:

```json
POST /tasks/oplog%2Fresize
{"namespace": "mongo-1", "target_size_mb": 4096, "dry_run": "false", "confirm": "true"}
```

### 3. One member rejected the resize

```json
{
  "status": "ERROR",
  "reason_code": "OPLOG_RESIZE_PARTIAL_FAILURE",
  "summary": "resize to 200MB failed on one or more members",
  "details": {
    "members": [
      {"host": "mongodb-0.mongodb.mongo-1.svc.cluster.local:27017", "ok": true},
      {"host": "mongodb-1.mongodb.mongo-1.svc.cluster.local:27017", "ok": false, "error": "InvalidOptions:oplog size must be at least 990MB"}
    ]
  }
}
```

Retry with a valid size — members already resized are left as-is.

---

## MongoDB Privileges

`replSetResizeOplog` requires the `replSetConfigure` privilege action
(covered by the built-in `clusterManager`/`clusterAdmin`/`root` roles). This
repo's tasks always resolve a root-equivalent credential (see
`docs/mongodb/recovery.md`), so no extra grant is needed for the sandbox or
any deployment using the same credential convention. If you provision a
scoped-down MongoDB user for aqsh, it needs `replSetConfigure` for
`oplog/resize` (`oplog/status` only needs ordinary read access via
`getReplicationInfo`).

---

## Deployment Settings (Internal Config)

No new keys. The oplog tasks reuse the existing MongoDB resolution defaults
from `/etc/aqsh/config/mongodb.env` (all optional — auto-detect covers a
conventional deployment with zero config): `MONGO_STS_NAME_DEFAULT`,
`MONGO_CRED_SECRET_DEFAULT`, `MONGO_CRED_USER_DEFAULT`,
`MONGO_CRED_USER_KEY_DEFAULT` / `MONGO_CRED_PASS_KEY_DEFAULT`.

---

## RBAC Requirements

No additions. The oplog tasks run entirely within what the existing
`aqsh-mongo-manager` ClusterRole already grants (see
`tests/chart/templates/mongodb-rbac.yaml`):

- `pods` get/list — probe-pod selection
- `pods/exec` create — running mongosh inside a member pod
- `statefulsets` get/list — StatefulSet + credential auto-detection
- `secrets` get (named credential secret) — loading root credentials

`replSetResizeOplog` itself is a mongod admin command executed through
`pods/exec`, not a Kubernetes API mutation.
