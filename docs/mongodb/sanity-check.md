# Task: sanity-check

3-layer health check: Kubernetes infrastructure → MongoDB connectivity → MongoDB internals.

## Description

Reads MongoDB credentials at runtime from a Kubernetes Secret in the target namespace — no credentials pass through the task API.

`sts_name`/credential secret+keys are never task inputs (see CLAUDE.md
"Configuration Layers" → "Auto-detect tier") — this task only takes
`namespace`. StatefulSet name, credentials, and the StatefulSet's headless
Service are all resolved from live cluster state: `sts_name` from
auto-detection (or internal config if set), credentials from the
StatefulSet's own container env, and the headless Service from the
StatefulSet's `spec.serviceName` (not assumed to equal the StatefulSet's own
name — e.g. Bitnami's chart commonly names it `<release>-headless`). Primary
discovery then seeds from `<sts>-0.<headless-service>.<namespace>.svc.cluster.local`,
calls `isMaster` to locate the current primary, and runs all checks against
that primary. Works on standalone instances too.

The Layer 1 PVC disk-usage check's mount path is likewise never a task input:
it asks mongod itself for its real dbPath (`db.serverCmdLineOpts().parsed.storage.dbPath`,
the same live detection `recovery/*` uses — see CLAUDE.md "Configuration
Layers" → "Auto-detect tier") so the check works unchanged whether the
deployment is a Bitnami chart (`/bitnami/mongodb/data/db`) or an official
image (`/data/db`), falling back to the Bitnami path only if no pod in the
StatefulSet answers the probe.

## Endpoint

```
POST /tasks/sanity-check
```

Served by **aqsh-mongodb** on NodePort `30082`.

## Request

### Headers

| Header | Value |
|--------|-------|
| `Authorization` | `Bearer <token>` |
| `Content-Type` | `application/json` |

### Body

```json
{
  "namespace": "mongo-1"
}
```

### Input Fields

| Field | Env Var | Type | Required | Default | Description |
|-------|---------|------|----------|---------|-------------|
| `namespace` | `DB_NAMESPACE` | string | **yes** | — | Target namespace. Pattern: `^mongo-[0-9]+$` |

> StatefulSet name, credential secret/keys, and headless Service name are
> never task inputs for this task — they resolve internal config → live
> auto-detect → hardcoded literal, with no caller override (CLAUDE.md
> "Configuration Layers" → "Auto-detect tier"). See `docs/mongodb/recovery.md`
> "API Reference" for the full resolution chain.

## Response

### 202 Accepted

```json
{
  "id":     "d5a00329-7870-482c-89c2-54ab9b8dec08",
  "queue":  "mongodb",
  "status": "pending"
}
```

### Task Result (`GET /executions/{id}`)

Once `status` is `completed`, the `result.data` field contains:

```json
{
  "status":    "ok",
  "namespace": "mongo-1",
  "pass":      13,
  "warn":      1,
  "fail":      0,
  "total":     14
}
```

| `status` | Condition |
|----------|-----------|
| `ok` | All checks passed |
| `warning` | At least 1 WARN, no FAILs |
| `critical` | At least 1 FAIL |

## Check Layers

### Layer 1 — Kubernetes Infrastructure

| Check | WARN threshold | FAIL threshold |
|-------|---------------|----------------|
| kubectl connectivity | — | cannot reach cluster |
| Node readiness | resource pressure active | node NotReady |
| StatefulSet all pods ready | — | readyReplicas < desired |
| Pod restart count | ≥ 5 restarts | — |
| PVC disk usage | ≥ 80% | ≥ 90% |
| K8s Warning events | any events | — |

### Layer 2 — MongoDB Connectivity

| Check | FAIL condition |
|-------|---------------|
| `mongosh` ping to primary | cannot connect |

### Layer 3 — MongoDB Internals

| Check | WARN threshold | FAIL threshold |
|-------|---------------|----------------|
| Replica set member health | transitional states | error states |
| Replication lag | ≥ 15 s | ≥ 60 s |
| Oplog window | < 3 days | < 1 day |
| WiredTiger cache dirty pages | ≥ 80% | ≥ 95% |
| Connection utilisation | ≥ 80% | ≥ 90% |
| Global lock queue | ≥ 3 | ≥ 10 |
| Long-running operations | ops > 60 s | — |

Thresholds follow MongoDB Atlas default alert levels, except replication lag
WARN, which is widened from Atlas' 10 s to 15 s — mongod writes a periodic
no-op to the oplog roughly every 10 s to advance the majority commit point
when idle, and at 1-second timestamp granularity that cadence alone can read
as ~10 s of lag on a quiet or freshly started replica set, flapping the
alert right at the boundary. Standalone instances skip RS-only checks
automatically.

Both the replication-lag and oplog-window checks read live/near-instant
signals, so both can misfire immediately after a member starts (or is
freshly wiped/recovered): oplog window in particular is bounded by mongod's
own uptime, not by how the oplog is sized. When `uptime` (from
`serverStatus`) is below the relevant threshold, an oplog-window WARN/FAIL
that would otherwise fire is downgraded to an informational WARN noting the
node hasn't been up long enough to evaluate — the startup downgrade ends
once uptime passes the threshold. If the window is still actually too small
at that point, the normal WARN/FAIL classification resumes; the downgrade
only defers judgment, it doesn't clear the underlying condition.

## Permissions

| Field | Value |
|-------|-------|
| `allowed_groups` | `system:serviceaccounts` |
| Timeout | 5 minutes |

RBAC: `aqsh-mongo-manager` ClusterRole grants `get` on `secrets`, `get`/`list` on `pods`, and `create` on `pods/exec` in `mongo-1/2/3`.

## Example

See [examples/mongodb/sanity-check.sh](../../examples/mongodb/sanity-check.sh) for a runnable end-to-end script.

For run account lifecycle, expiry reconciliation, and account mutation operations, see [docs/mongodb/create-account.md](create-account.md).

Run from the `test-client` pod (`*.kind-a.test` only resolves inside the
clusters' own CoreDNS):

```bash
TOKEN=$(kubectl --context kind-cluster-b -n mongo-core create token test-client --duration=10m)
AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"

# Check mongo-1 — namespace is the only input; everything else auto-detects
kubectl --context kind-cluster-b -n mongo-core exec deploy/test-client -- \
  curl -s -X POST "$AQSH_URL/tasks/sanity-check" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mongo-1"}'
```

A non-default StatefulSet name, credential secret, or headless Service
convention is not overridable per-call — set `MONGO_STS_NAME_DEFAULT` /
`MONGO_CRED_SECRET_DEFAULT` / `MONGO_HEADLESS_SVC_DEFAULT` / etc. in
`/etc/aqsh/config/mongodb.env` instead
(see `docs/mongodb/recovery.md` "API Reference"), or rely on auto-detect,
which now also resolves the headless Service from the StatefulSet's own
`spec.serviceName` rather than assuming it matches the StatefulSet's name.

## Sample Log Output

Header block below is `cli.sh`'s local-debug format (its own `--pvc-path`
flag, default `/data/db`); the AQSH task doesn't print this banner and
resolves `PVC path` live per the auto-detect above, so it will read
`/bitnami/mongodb` instead against a Bitnami-chart deployment.

```
══ MongoDB Sanity Check ══════════════════════════════════════════
Namespace       : mongo-1
STS             : mongodb
PVC path        : /data/db  (warn: 80%  crit: 90%)
Lag thresholds  : warn ≥ 15s  crit ≥ 60s
Oplog thresholds: warn < 3d  crit < 1d
Connections     : warn ≥ 80%  crit ≥ 90%
WT cache dirty  : warn ≥ 80%  crit ≥ 95%
═══════════════════════════════════════════════════════════════════

── Layer 1: Kubernetes Infrastructure ──────────────────────────────────────────
  [PASS]  kubectl: cluster is reachable
  [PASS]  Nodes: all 1 node(s) Ready, no resource pressure
  [PASS]  STS 'mongodb': all pods ready (1/1)
  [PASS]  Pod 'mongodb-0': restart count OK (0)
  [PASS]  Pod 'mongodb-0' PVC /data/db: 12% used
  [PASS]  K8s Warning events: none in namespace 'mongo-1'

── Layer 2: MongoDB Connectivity ───────────────────────────────────────────────
  [PASS]  MongoDB: connection successful (mongodb-0.mongodb.mongo-1.svc.cluster.local:27017)

── Layer 3: MongoDB Internals ──────────────────────────────────────────────────
  [WARN]  Replica set: standalone instance detected (no RS configured)

═══ Sanity Check Summary ═══════════════════════════════════════
  PASS : 7
  WARN : 1
  FAIL : 0
  TOTAL: 8 checks

  Result: WARNING (1 warning(s))
```
