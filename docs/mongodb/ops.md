# MongoDB Ops Gateway (aqsh-mongodb)

`ops/list` and `ops/kill` give visibility into and control over
**currently running MongoDB operations** — `db.currentOp()` to see what's
active (with enough detail to actually triage, not just a bare opid list),
and `db.adminCommand({killOp})` to stop one.

**currentOp/killOp are per-node views, not cluster-wide.** Every mongod only
knows about its own in-flight operations, so an `opid` observed via
`ops/list` on one member means nothing on a different member. Both tasks
accept an optional `target_pod`, defaulting to the elected PRIMARY when
omitted — **use the same `target_pod` for the `ops/list` call that found the
opid and the `ops/kill` call that kills it.**

Deployment naming/credential conventions (StatefulSet name, credential
secret and keys) are **not task inputs** — they resolve via internal config
→ live-cluster auto-detect → hardcoded fallback, exactly like `recovery/*`
and `fcv/*` (see CLAUDE.md "Configuration Layers").

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
     │  POST /tasks/ops%2Fkill   {namespace, target_pod, opid, dry_run, confirm}
     ▼
aqsh (mongo-core, cluster-a) → mongodb/ops/kill.sh
     │ 1. gate: dry_run/confirm triad + non-negative-integer opid
     │ 2. resolve (3-tier, no task inputs): sts_name, credentials
     │ 3. resolve target: target_pod given? exec there directly (localhost)
     │      : else kubectl exec probe → mongosh rs.status() → PRIMARY,
     │              exec from probe with directConnection to it
     │ 4. mongosh: db.currentOp({opid}) — does it still exist?          (read)
     │ 5. not found → OP_NOT_FOUND, completed (it may have finished naturally)
     │ 6. dry_run? → DRY_RUN_READY preview (the op's own info) and stop
     │ 7. mongosh: adminCommand({killOp, op: opid})                     (write)
     │ 8. mongosh: db.currentOp({opid}) again — best-effort, reported
     │      honestly as still_visible_immediately_after (killOp only sets
     │      an interrupt flag; it does not guarantee immediate termination)
     ▼
result JSON → task .result.data
```

`ops/list` is steps 2–4 only, against `db.currentOp(filter)` instead of a
single opid, ending in a read-only report.

Debug visibility: the resolved StatefulSet/credentials, the exec target
(explicit pod, or probe + resolved primary), and each raw mongosh sentinel
line are logged at DEBUG level — set `LOG_LEVEL=DEBUG` on the call (or the
aqsh container) to see them.

---

## API Reference

Base URL (sandbox): `http://aqsh-mongodb.kind-a.test:30080`. Slash-named
tasks are URL-encoded: `POST /tasks/ops%2Flist`, `POST /tasks/ops%2Fkill`.

### `ops/list` — read-only report

| Input | Required | Default | Meaning |
|---|---|---|---|
| `namespace` | yes | — | Namespace of the MongoDB StatefulSet |
| `target_pod` | no | `""` (→ elected PRIMARY) | Pod to query; must be an existing member pod |
| `min_secs_running` | no | `"0"` (no filter) | Only report operations running at least this many seconds |

Result (`.result.data`):

```json
{
  "namespace": "mongo-1",
  "target_pod": "mongodb-0",
  "min_secs_running": 5,
  "count": 1,
  "ops": [
    {
      "opid": 4821,
      "secs_running": 42,
      "op": "query",
      "ns": "app.orders",
      "desc": "conn173",
      "client": "10.244.1.7:52344",
      "planSummary": "COLLSCAN",
      "waitingForLock": false,
      "effectiveUsers": ["app_user"],
      "killPending": false
    }
  ]
}
```

Only *active* operations are reported (MongoDB's own idle-connection
filtering) — a connection sitting idle between requests never appears.
MongoDB's own internal housekeeping threads (`NoopWriter`, `JournalFlusher`,
`OplogApplier-*`, `Checkpointer`, etc. — always "active" but never something
a caller would want to see or kill) are also excluded.

### `ops/kill` — gated mutation (dry_run → confirm)

| Input | Required | Default | Meaning |
|---|---|---|---|
| `namespace` | yes | — | Namespace of the MongoDB StatefulSet |
| `target_pod` | no | `""` (→ elected PRIMARY) | **Must match the pod `ops/list` found the opid on** |
| `opid` | yes | — | The operation id to kill |
| `dry_run` | no | `"true"` | Look up the op and preview only; nothing is changed |
| `confirm` | no | `"false"` | Must be `"true"` when `dry_run` is `"false"` |

Gate rules (identical to `fcv/set`): `dry_run=true` (default) previews;
`dry_run=true` + `confirm=true` is rejected; `dry_run=false` without
`confirm=true` is rejected. If the opid doesn't exist at all — on either
`dry_run=true` or `dry_run=false` — the result is `OP_NOT_FOUND`
(`status: "ok"`, not an error): it may simply have finished on its own.

Success result:

```json
{
  "status": "ok",
  "reason_code": "OP_KILLED",
  "summary": "killOp(4821) issued on mongodb-0.",
  "namespace": "mongo-1",
  "target_pod": "mongodb-0",
  "opid": 4821,
  "op_before": {"opid": 4821, "secs_running": 42, "op": "query", "ns": "app.orders", "...": "..."},
  "killed": true,
  "still_visible_immediately_after": false
}
```

`still_visible_immediately_after: true` is not a failure — `killOp` sets an
interrupt flag and returns immediately; the operation actually unwinds at
its next interrupt point, which can be a moment later.

### Result codes

| `reason_code` | Task status | Trigger |
|---|---|---|
| `OP_KILLED` | completed | `killOp` command accepted (`ok: 1`) |
| `OP_NOT_FOUND` | completed | No active operation with that opid on the target node — not an error |
| `DRY_RUN_READY` | completed | The op was found; preview only, nothing changed |
| `INVALID_INPUT` | failed | Gate violation, or `opid`/`min_secs_running` isn't a non-negative integer |
| `OPS_READ_FAILED` | failed | Could not read `currentOp` from the target node (auth, connectivity) |
| `KILL_FAILED` | failed | The server rejected the `killOp` command itself |
| `NO_PRIMARY` | failed | No `target_pod` given and no reachable PRIMARY |

---

## Usage Scenarios

### 1. Find long-running operations on the primary

```json
POST /tasks/ops%2Flist
{"namespace": "mongo-1", "min_secs_running": 10}
```

### 2. Kill a runaway query found above

```json
POST /tasks/ops%2Fkill
{"namespace": "mongo-1", "opid": 4821}
```

Returns `DRY_RUN_READY` with the op's own info for a final look. Then execute:

```json
POST /tasks/ops%2Fkill
{"namespace": "mongo-1", "opid": 4821, "dry_run": "false", "confirm": "true"}
```

### 3. Check a specific secondary instead of the primary

```json
POST /tasks/ops%2Flist
{"namespace": "mongo-1", "target_pod": "mongodb-2"}
```

```json
POST /tasks/ops%2Fkill
{"namespace": "mongo-1", "target_pod": "mongodb-2", "opid": 91, "dry_run": "false", "confirm": "true"}
```

(`target_pod` must match between the two calls — `opid` 91 on `mongodb-2`
is unrelated to any `opid` 91 on the primary.)

### 4. The op already finished on its own

```json
{
  "status": "ok",
  "reason_code": "OP_NOT_FOUND",
  "summary": "No active operation with opid 4821 on mongodb-0.",
  "namespace": "mongo-1", "target_pod": "mongodb-0", "opid": 4821, "killed": false
}
```

---

## MongoDB Privileges

`db.currentOp()` requires the `inprog` privilege action (built-in
`clusterMonitor`/`clusterAdmin`/`root` roles); `killOp` requires the
`killop` action (built-in `hostManager`/`clusterAdmin`/`root` roles). This
repo's tasks always resolve a root-equivalent credential (see
`docs/mongodb/recovery.md`), so no extra grant is needed for the sandbox or
any deployment using the same credential convention. If you provision a
scoped-down MongoDB user for aqsh, it needs both actions for `ops/kill`
(`ops/list` alone only needs `inprog`).

---

## Deployment Settings (Internal Config)

No new keys. The ops tasks reuse the existing MongoDB resolution defaults
from `/etc/aqsh/config/mongodb.env` (all optional — auto-detect covers a
conventional deployment with zero config): `MONGO_STS_NAME_DEFAULT`,
`MONGO_CRED_SECRET_DEFAULT`, `MONGO_CRED_USER_DEFAULT`,
`MONGO_CRED_USER_KEY_DEFAULT` / `MONGO_CRED_PASS_KEY_DEFAULT`.

---

## RBAC Requirements

No additions. The ops tasks run entirely within what the existing
`aqsh-mongo-manager` ClusterRole already grants (see
`tests/chart/templates/mongodb-rbac.yaml`):

- `pods` get/list — probe-pod selection and (when no `target_pod` is given)
  primary discovery
- `pods/exec` create — running mongosh inside a member pod
- `statefulsets` get/list — StatefulSet + credential auto-detection
- `secrets` get (named credential secret) — loading root credentials

`currentOp`/`killOp` themselves are mongod admin operations executed
through `pods/exec`, not a Kubernetes API mutation.
