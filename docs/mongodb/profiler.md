# MongoDB Profiler Gateway (aqsh-mongodb)

`profiler/status` and `profiler/set` manage MongoDB's **query profiler** —
the mechanism that records slow (or all) operations into
`system.profile` for later inspection. `profiler/set` runs the documented
`db.setProfilingLevel(level, {slowms, sampleRate})` shell helper.

**The profiler level is per-node state, not cluster-wide.** Each mongod
tracks its own setting. Both tasks accept an optional `target_pod`,
defaulting to the elected PRIMARY when omitted, exactly like `ops/list` /
`ops/kill` — to change the profiler on every member, call `profiler/set`
once per `target_pod`.

Deployment naming/credential conventions (StatefulSet name, credential
secret and keys) are **not task inputs** — they resolve via internal config
→ live-cluster auto-detect → hardcoded fallback, exactly like `recovery/*`
and `fcv/*` (see CLAUDE.md "Configuration Layers").

## Table of Contents

1. [Architecture & Flow](#architecture--flow)
2. [API Reference](#api-reference)
3. [Usage Scenarios](#usage-scenarios)
4. [Performance Impact of level=2](#performance-impact-of-level2)
5. [MongoDB Privileges](#mongodb-privileges)
6. [Deployment Settings (Internal Config)](#deployment-settings-internal-config)
7. [RBAC Requirements](#rbac-requirements)

---

## Architecture & Flow

```
Operator / test-client (cluster-b)
     │  POST /tasks/profiler%2Fset   {namespace, target_pod, level, slowms, sample_rate, dry_run, confirm}
     ▼
aqsh (mongo-core, cluster-a) → mongodb/profiler/set.sh
     │ 1. gate: dry_run/confirm triad + level in {0,1,2}, slowms >= 0,
     │      sample_rate in [0,1]
     │ 2. resolve (3-tier, no task inputs): sts_name, credentials
     │ 3. resolve target: target_pod given? exec there directly (localhost)
     │      : else kubectl exec probe → mongosh rs.status() → PRIMARY,
     │              exec from probe with directConnection to it
     │ 4. mongosh: db.getProfilingStatus()                          (read)
     │ 5. already at requested level/slowms/sampleRate? → ALREADY_AT_TARGET
     │ 6. dry_run? → DRY_RUN_READY preview (+ high_impact_warning when
     │      level=2) and stop
     │ 7. mongosh: db.setProfilingLevel(level, {slowms, sampleRate})   (write)
     │ 8. mongosh: db.getProfilingStatus() again — report the new state,
     │      never the set command's own (differently-shaped) response
     ▼
result JSON → task .result.data
```

`profiler/status` is steps 2–4 only, ending in a read-only report.

Debug visibility: the resolved StatefulSet/credentials, the exec target
(explicit pod, or probe + resolved primary), and each raw mongosh sentinel
line are logged at DEBUG level — set `LOG_LEVEL=DEBUG` on the call (or the
aqsh container) to see them.

---

## API Reference

Base URL (sandbox): `http://aqsh-mongodb.kind-a.test:30080`. Slash-named
tasks are URL-encoded: `POST /tasks/profiler%2Fstatus`, `POST /tasks/profiler%2Fset`.

### `profiler/status` — read-only report

| Input | Required | Default | Meaning |
|---|---|---|---|
| `namespace` | yes | — | Namespace of the MongoDB StatefulSet |
| `target_pod` | no | `""` (→ elected PRIMARY) | Pod to query; must be an existing member pod |

Result (`.result.data`):

```json
{
  "namespace": "mongo-1",
  "target_pod": "mongodb-0",
  "level": 1,
  "slowms": 100,
  "sampleRate": 1
}
```

### `profiler/set` — gated mutation (dry_run → confirm)

| Input | Required | Default | Meaning |
|---|---|---|---|
| `namespace` | yes | — | Namespace of the MongoDB StatefulSet |
| `target_pod` | no | `""` (→ elected PRIMARY) | Pod to change; profiler state is per-node |
| `level` | yes | — | `0` (off), `1` (slow ops only), or `2` (all ops) |
| `slowms` | no | `"100"` | Threshold in ms; meaningful at `level=1` |
| `sample_rate` | no | `"1"` | Fraction (0–1) of matching ops actually profiled |
| `dry_run` | no | `"true"` | Preview current vs requested only; nothing is changed |
| `confirm` | no | `"false"` | Must be `"true"` when `dry_run` is `"false"` |

Gate rules (identical to `fcv/set`): `dry_run=true` (default) previews;
`dry_run=true` + `confirm=true` is rejected; `dry_run=false` without
`confirm=true` is rejected.

Success result:

```json
{
  "status": "ok",
  "reason_code": "PROFILER_SET",
  "summary": "Profiler settings changed.",
  "namespace": "mongo-1",
  "target_pod": "mongodb-0",
  "previous": {"level": 0, "slowms": 100, "sampleRate": 1},
  "current": {"level": 1, "slowms": 50, "sampleRate": 1},
  "changed": true
}
```

Requesting `level: 2` adds a top-level `high_impact_warning` string to both
the dry-run and the success result — informational only, it never blocks
the change.

### Result codes

| `reason_code` | Task status | Trigger |
|---|---|---|
| `PROFILER_SET` | completed | `setProfilingLevel` succeeded; result carries the freshly-read new state |
| `DRY_RUN_READY` | completed | Preview only, nothing changed |
| `ALREADY_AT_TARGET` | completed | level/slowms/sample_rate already match the request — explicit no-op |
| `INVALID_INPUT` | failed | Gate violation, or `level`/`slowms`/`sample_rate` out of range |
| `PROFILER_READ_FAILED` | failed | Could not read profiling status from the target node |
| `PROFILER_SET_FAILED` | failed | The server rejected the `setProfilingLevel` command |
| `NO_PRIMARY` | failed | No `target_pod` given and no reachable PRIMARY |

---

## Usage Scenarios

### 1. Check the current setting

```json
POST /tasks/profiler%2Fstatus
{"namespace": "mongo-1"}
```

### 2. Turn on slow-query logging at 50ms while diagnosing a latency issue

```json
POST /tasks/profiler%2Fset
{"namespace": "mongo-1", "level": 1, "slowms": 50}
```

Returns `DRY_RUN_READY` with current vs requested. Then execute:

```json
POST /tasks/profiler%2Fset
{"namespace": "mongo-1", "level": 1, "slowms": 50, "dry_run": "false", "confirm": "true"}
```

### 3. Turn it back off once done

```json
POST /tasks/profiler%2Fset
{"namespace": "mongo-1", "level": 0, "dry_run": "false", "confirm": "true"}
```

### 4. What the level=2 warning looks like

```json
{
  "status": "DRY_RUN_READY",
  "reason_code": "DRY_RUN_READY",
  "summary": "Dry-run only. Would change the profiler settings shown below.",
  "previous": {"level": 0, "slowms": 100, "sampleRate": 1},
  "requested": {"level": 2, "slowms": 100, "sampleRate": 1},
  "changed": false, "would_change": true,
  "high_impact_warning": "level=2 profiles every operation and has a real performance cost; consider reverting to level=0/1 once diagnosis is done"
}
```

---

## Performance Impact of level=2

`level: 2` profiles **every** operation, not just slow ones — real
production workloads see measurable overhead from the extra writes to
`system.profile`. There is no automatic revert: `profiler/set` does not
schedule anything, so treat `level=2` as something you turn on, use
briefly, and explicitly turn back off with a follow-up `profiler/set`
call (`level: 0` or `1`) — the task surfaces `high_impact_warning` as a
reminder, not a safeguard.

---

## MongoDB Privileges

`getProfilingStatus`/`setProfilingLevel` require the `enableProfiler`
privilege action (built-in `dbAdmin`/`clusterAdmin`/`root` roles). This
repo's tasks always resolve a root-equivalent credential (see
`docs/mongodb/recovery.md`), so no extra grant is needed for the sandbox or
any deployment using the same credential convention. If you provision a
scoped-down MongoDB user for aqsh, it needs `enableProfiler` on the target
database for `profiler/set` (`profiler/status` needs the same action to
read the setting at all).

---

## Deployment Settings (Internal Config)

No new keys. The profiler tasks reuse the existing MongoDB resolution
defaults from `/etc/aqsh/config/mongodb.env` (all optional — auto-detect
covers a conventional deployment with zero config): `MONGO_STS_NAME_DEFAULT`,
`MONGO_CRED_SECRET_DEFAULT`, `MONGO_CRED_USER_DEFAULT`,
`MONGO_CRED_USER_KEY_DEFAULT` / `MONGO_CRED_PASS_KEY_DEFAULT`.

---

## RBAC Requirements

No additions. The profiler tasks run entirely within what the existing
`aqsh-mongo-manager` ClusterRole already grants (see
`tests/chart/templates/mongodb-rbac.yaml`):

- `pods` get/list — probe-pod selection and (when no `target_pod` is given)
  primary discovery
- `pods/exec` create — running mongosh inside a member pod
- `statefulsets` get/list — StatefulSet + credential auto-detection
- `secrets` get (named credential secret) — loading root credentials

`getProfilingStatus`/`setProfilingLevel` themselves are mongod admin
operations executed through `pods/exec`, not a Kubernetes API mutation.
