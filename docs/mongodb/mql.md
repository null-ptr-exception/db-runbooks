# MongoDB MQL Gateway (aqsh-mongodb)

`mql/read` and `mql/write` let a caller run structured MongoDB Query
Language operations — find/aggregate/count/distinct, and
insert/update/delete — against one collection, without ever sending raw
JavaScript to be `eval`'d. Every filter/projection/pipeline/document(s)/
update field is a caller-supplied JSON *value*, validated with a strict
type check before it is embedded into the query; there is no free-text
"query string" input, so there is nothing here shaped like an eval-injection
vector.

Deployment naming/credential conventions (StatefulSet name, credential
secret and keys) are **not task inputs** — they resolve via internal config
→ live-cluster auto-detect → hardcoded fallback, exactly like `recovery/*`,
`ops/*`, and `profiler/*` (see CLAUDE.md "Configuration Layers"). The same
auto-detect also covers both the official and Bitnami MongoDB image
conventions with no special-casing here.

## Table of Contents

1. [Architecture & Flow](#architecture--flow)
2. [API Reference](#api-reference)
3. [Usage Scenarios](#usage-scenarios)
4. [MongoDB Privileges](#mongodb-privileges)
5. [Deployment Settings (Internal Config)](#deployment-settings-internal-config)
6. [RBAC Requirements](#rbac-requirements)
7. [Security Notes](#security-notes)

---

## Architecture & Flow

```text
Operator / test-client (cluster-b)
     │  POST /tasks/mql%2Fread   {namespace, database, collection, operation, ...}
     │  POST /tasks/mql%2Fwrite  {namespace, database, collection, operation, dry_run, confirm, ...}
     ▼
aqsh (mongo-core, cluster-a) → mongodb/mql/read.sh | mongodb/mql/write.sh
     │ 1. validate operation enum + per-operation required fields
     │ 2. mql/write only: dry_run/confirm gate triad (INVALID_INPUT on violation)
     │ 3. validate filter/projection/pipeline/document(s)/update as JSON
     │    (mql_validate_json — rejects anything that isn't exactly one
     │    well-formed JSON value of the expected type)
     │ 4. PROTECTED_DATABASE check: admin/local/config always refused
     │ 5. resolve (3-tier, no task inputs): sts_name, credentials
     │ 6. mql/read: target_pod given? verify it is owned by the resolved
     │             StatefulSet (TARGET_POD_NOT_MEMBER if not), then exec
     │             there directly
     │             : else kubectl exec probe → mongosh rs.status() → PRIMARY
     │    mql/write: always the elected PRIMARY (no target_pod field)
     │ 7. mql/read: run the operation, return the result — find/aggregate/
     │      distinct results are capped at `limit`: find via cursor.limit(),
     │      aggregate via a {$limit} stage appended after the caller's own
     │      pipeline (aggregation cursors have no cursor.limit()), distinct
     │      via a client-side array slice                             (read)
     │    mql/write, dry_run=true: countDocuments (candidate_count) +
     │      capped would_change_count/sample_ids (update/delete) or echo
     │      the validated payload (insert) — nothing changes, DRY_RUN_READY
     │    mql/write, confirm=true: run the operation, return the
     │      driver's own result document                               (write)
     ▼
result JSON → task .result.data
```

Debug visibility: the resolved StatefulSet/credentials, the exec target,
and the operation+database+collection+filter/update/pipeline are logged at
DEBUG level — set `LOG_LEVEL=DEBUG` on the call (or the aqsh container) to
see them. Values and full result documents are not specially redacted at
DEBUG (this data is the caller's own query, not a credential), but are
never logged at INFO or above.

---

## API Reference

Base URL (sandbox): `http://aqsh-mongodb.kind-a.test:30080`. Slash-named
tasks are URL-encoded: `POST /tasks/mql%2Fread`, `POST /tasks/mql%2Fwrite`.

### `mql/read` — read-only

| Input | Required | Default | Meaning |
|---|---|---|---|
| `namespace` | yes | — | Namespace of the MongoDB StatefulSet |
| `target_pod` | no | `""` (→ elected PRIMARY) | Pod to query; must be a member pod of the resolved StatefulSet (verified via the pod's own `ownerReferences` — `TARGET_POD_NOT_MEMBER` otherwise) |
| `database` | yes | — | Database name |
| `collection` | yes | — | Collection name (`system.*` is refused) |
| `operation` | yes | — | `find` \| `aggregate` \| `count` \| `distinct` |
| `filter` | no | `"{}"` | JSON object — `find`/`count`/`distinct` |
| `projection` | no | `"{}"` | JSON object — `find` only |
| `pipeline` | no | `"[]"` | JSON array — `aggregate` only |
| `distinct_field` | required for `distinct` | `""` | Field name to distinct on |
| `limit` | no | `"50"` (max `1000`) | Result cap for `find`/`aggregate`/`distinct`: `find` uses `cursor.limit()`, `aggregate` appends a `{$limit}` stage after the caller's own pipeline, `distinct` slices the returned array — a pipeline's own `$limit` cannot raise or remove the gateway's cap |

Result (`.result.data`):

```json
{
  "status": "ok",
  "reason_code": "QUERY_OK",
  "namespace": "mongo-1",
  "target_pod": "mongodb-0",
  "database": "app",
  "collection": "orders",
  "operation": "find",
  "result": [{"_id": "...", "status": "pending", "...": "..."}]
}
```

`count` returns `{"count": N}`; `distinct` returns `{"values": [...]}` (also
capped at `limit`, like `find`/`aggregate`).

### `mql/write` — gated mutation (dry_run → confirm)

| Input | Required | Default | Meaning |
|---|---|---|---|
| `namespace` | yes | — | Namespace of the MongoDB StatefulSet |
| `database` | yes | — | Database name |
| `collection` | yes | — | Collection name (`system.*` is refused) |
| `operation` | yes | — | `insert_one` \| `insert_many` \| `update_one` \| `update_many` \| `delete_one` \| `delete_many` |
| `filter` | no | `"{}"` | JSON object — `update_*`/`delete_*` only |
| `update` | required for `update_one`/`update_many` | `""` | JSON object |
| `document` | required for `insert_one` | `""` | JSON object |
| `documents` | required for `insert_many` | `""` | JSON array, non-empty |
| `upsert` | no | `"false"` | `update_one`/`update_many` only |
| `dry_run` | no | `"true"` | Preview only; nothing changed |
| `confirm` | no | `"false"` | Must be `"true"` when `dry_run` is `"false"` |

Gate rules (identical to `ops/kill`/`profiler/set`): `dry_run=true`
(default) previews; `dry_run=true` + `confirm=true` is rejected;
`dry_run=false` without `confirm=true` is rejected. There is no
`target_pod` field — writes always resolve and target the elected PRIMARY.

Dry-run preview (`update_one` example — `candidate_count` is every document the
filter matches; `would_change_count`/`sample_ids` are capped at 1 for
`update_one`/`delete_one` since those operations can change at most one
document even when the filter matches more. `update_many`/`delete_many`
leave `would_change_count` equal to `candidate_count` and cap `sample_ids`
at 5):

```json
{
  "status": "DRY_RUN_READY",
  "reason_code": "DRY_RUN_READY",
  "summary": "Dry-run only. Would apply the operation shown below.",
  "namespace": "mongo-1", "database": "app", "collection": "orders",
  "operation": "update_one",
  "preview": {"candidate_count": 3, "would_change_count": 1, "sample_ids": ["..."]},
  "changed": false, "would_change": true
}
```

Confirmed write:

```json
{
  "status": "ok",
  "reason_code": "WRITE_OK",
  "summary": "Write applied.",
  "namespace": "mongo-1", "database": "app", "collection": "orders",
  "operation": "update_one",
  "result": {"matchedCount": 1, "modifiedCount": 1, "upsertedId": null},
  "changed": true
}
```

`insert_one`/`insert_many` dry-run preview echoes the validated payload
back (`{"would_insert": {...}}` / `{"would_insert_count": N,
"would_insert": [...]}`) — there is nothing live to check against for an
insert.

### Result codes

| `reason_code` | Task status | Trigger |
|---|---|---|
| `QUERY_OK` | completed | `mql/read` operation succeeded |
| `WRITE_OK` | completed | `mql/write` confirmed operation succeeded |
| `DRY_RUN_READY` | completed | `mql/write` preview; nothing changed |
| `INVALID_INPUT` | failed | Gate violation, bad operation enum, or malformed/missing JSON field |
| `PROTECTED_DATABASE` | failed | Target database is `admin`/`local`/`config` or internal-config-protected |
| `TARGET_POD_NOT_MEMBER` | failed | `mql/read`'s `target_pod` is not an owned member of the resolved StatefulSet |
| `NO_PRIMARY` | failed | No `target_pod` given (read) or no reachable PRIMARY at all |
| `QUERY_FAILED` | failed | `mql/read`'s operation errored against the server |
| `PREVIEW_FAILED` | failed | `mql/write`'s dry-run preview query errored against the server |
| `WRITE_FAILED` | failed | `mql/write`'s confirmed operation errored against the server |

---

## Usage Scenarios

### 1. Query with a filter and projection

```json
POST /tasks/mql%2Fread
{"namespace": "mongo-1", "database": "app", "collection": "orders",
 "operation": "find", "filter": "{\"status\":\"pending\"}",
 "projection": "{\"_id\":1,\"total\":1}", "limit": "20"}
```

### 2. Aggregate

```json
POST /tasks/mql%2Fread
{"namespace": "mongo-1", "database": "app", "collection": "orders",
 "operation": "aggregate",
 "pipeline": "[{\"$match\":{\"status\":\"paid\"}},{\"$group\":{\"_id\":\"$customer\",\"total\":{\"$sum\":\"$amount\"}}}]"}
```

### 3. Preview a bulk update, then confirm

```json
POST /tasks/mql%2Fwrite
{"namespace": "mongo-1", "database": "app", "collection": "orders",
 "operation": "update_many", "filter": "{\"status\":\"pending\"}",
 "update": "{\"$set\":{\"status\":\"cancelled\"}}"}
```

Review `preview.candidate_count`, `preview.would_change_count`, and
`preview.sample_ids`, then:

```json
POST /tasks/mql%2Fwrite
{"namespace": "mongo-1", "database": "app", "collection": "orders",
 "operation": "update_many", "filter": "{\"status\":\"pending\"}",
 "update": "{\"$set\":{\"status\":\"cancelled\"}}",
 "dry_run": "false", "confirm": "true"}
```

### 4. Protected database refused

```json
POST /tasks/mql%2Fread
{"namespace": "mongo-1", "database": "admin", "collection": "system.users",
 "operation": "find"}
```

```json
{"status": "ERROR", "reason_code": "PROTECTED_DATABASE",
 "summary": "refusing to read database 'admin' (MongoDB system database or internal-config-protected)"}
```

---

## MongoDB Privileges

This repo's tasks always resolve a root-equivalent credential (see
`docs/mongodb/recovery.md`), so `find`/`insert`/`update`/`remove` on any
non-protected database already work with no extra grant. If you provision a
scoped-down MongoDB user for aqsh instead, it needs `find` for `mql/read`
and `insert`/`update`/`remove` (as applicable per operation) on every
database `mql/write` is expected to touch — `admin`/`local`/`config`
require no grant here since this gateway refuses them outright regardless
of the credential's own privileges.

---

## Deployment Settings (Internal Config)

`/etc/aqsh/config/mongodb.env`:

| Key | Default | Meaning |
|---|---|---|
| `MQL_PROTECTED_DATABASES_DEFAULT` | *(empty)* | Extra protected database names, on top of the always-refused `admin`/`local`/`config` |

All other resolution reuses the existing MongoDB defaults (all optional —
auto-detect covers a conventional deployment with zero config):
`MONGO_STS_NAME_DEFAULT`, `MONGO_CRED_SECRET_DEFAULT`,
`MONGO_CRED_USER_DEFAULT`, `MONGO_CRED_USER_KEY_DEFAULT` /
`MONGO_CRED_PASS_KEY_DEFAULT`.

---

## RBAC Requirements

No additions. The MQL tasks run entirely within what the existing
`aqsh-mongo-manager` ClusterRole already grants (see
`tests/chart/templates/mongodb-rbac.yaml`) — the same grants `ops/*` and
`profiler/*` already use:

- `pods` get/list — probe-pod selection and (when no `target_pod` is given)
  primary discovery
- `pods/exec` create — running mongosh inside a member pod
- `statefulsets` get/list — StatefulSet + credential auto-detection
- `secrets` get (named credential secret) — loading root credentials

All actual query/write execution happens through `pods/exec` running
mongosh inside a member pod, not a Kubernetes API mutation.

---

## Security Notes

- **No raw eval**: `filter`/`projection`/`pipeline`/`document`/`documents`/
  `update` are validated as exactly one well-formed JSON value of the
  expected type (`mql_validate_json`) before being embedded into the
  generated query — the same validate-then-interpolate technique
  `lib/mongodb.sh`'s existing `mongo_find`/`mongo_update_one`/etc. already
  use. There is no field that accepts arbitrary JavaScript.
- **Protected databases are hardcoded, not configurable away**: `admin`,
  `local`, and `config` are always refused for both `mql/read` and
  `mql/write`, regardless of internal config — this blocks credential
  dumps via `admin.system.users`, raw oplog/replset-config access via
  `local`, and this repo's own `admin.run_account_policies`
  account-lifecycle state (see `docs/mongodb/account-lifecycle.md`).
  `MQL_PROTECTED_DATABASES_DEFAULT` can only add more names on top.
- **`system.*` collections are refused** even inside a non-system
  database.
- **`target_pod` is ownership-checked**: `mql/read`'s optional `target_pod`
  is verified against its own `ownerReferences` before it is trusted as the
  exec target (`TARGET_POD_NOT_MEMBER` otherwise). Without this check, a
  caller could point the resolved deployment's credentials at an arbitrary
  pod in the namespace rather than a genuine member of that StatefulSet.
- **`find`/`aggregate`/`distinct` results are capped**: `limit` (default
  50, max 1000) bounds mongosh/task memory regardless of collection size.
  `find` uses `cursor.limit()`; MongoDB aggregation cursors don't support
  `cursor.limit()` at all, so `aggregate` appends a `{$limit: limit}` stage
  after whatever pipeline the caller supplied — always the last stage, so
  it can't be raised or removed by the caller's own pipeline content;
  `distinct` has no cursor (one command, one response), so its result
  array is sliced instead.
- **No `plan_hash` compare-and-swap**: unlike `secrets/apply`,
  `mql/write`'s dry-run preview reflects the matched document set *at
  preview time* — a confirm sent well after the preview could act on a
  document set that has since drifted. This is the same accepted-risk
  posture as `ops/kill`, `profiler/set`, and the `account/*` family, not
  `secrets/apply`'s stronger resourceVersion-backed guarantee (that
  guarantee exists there because it patches a single Kubernetes object with
  a native optimistic-concurrency token available for free; there is no
  equivalent for an arbitrary multi-document MongoDB filter).
- **Weak/broad filters are accepted**: this API stores and executes what
  the caller sends — a `delete_many` with `filter: "{}"` is syntactically
  valid and will match every document in the collection. The dry-run
  preview's `candidate_count`/`would_change_count` is the intended safety
  net; review it before confirming.
