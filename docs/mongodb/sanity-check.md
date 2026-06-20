# Task: sanity-check

3-layer health check: Kubernetes infrastructure → MongoDB connectivity → MongoDB internals.

## Description

Reads MongoDB credentials at runtime from a Kubernetes Secret in the target namespace — no credentials pass through the task API.

Primary discovery is automatic: the task seeds from `<sts>-0.<sts>.<namespace>.svc.cluster.local` via the headless Service, calls `isMaster` to locate the current primary, then runs all checks against that primary. Works on standalone instances too.

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
  "namespace":          "mongo-1",
  "sts_name":           "mongodb",
  "credential_secret":  "mongodb-credentials",
  "credential_user_key":"MONGO_ROOT_USER",
  "credential_pass_key":"MONGO_ROOT_PASS"
}
```

### Input Fields

| Field | Env Var | Type | Required | Default | Description |
|-------|---------|------|----------|---------|-------------|
| `namespace` | `DB_NAMESPACE` | string | **yes** | — | Target namespace. Pattern: `^mongo-[0-9]+$` |
| `sts_name` | `MONGO_STS_NAME` | string | no | `mongodb` | StatefulSet name; also used as headless Service name |
| `credential_secret` | `MONGO_CRED_SECRET` | string | no | `mongodb-credentials` | Secret containing DB credentials |
| `credential_user_key` | `MONGO_CRED_USER_KEY` | string | no | `MONGO_ROOT_USER` | Key in Secret for username |
| `credential_pass_key` | `MONGO_CRED_PASS_KEY` | string | no | `MONGO_ROOT_PASS` | Key in Secret for password |

> `sts_name`/`credential_secret`/`credential_user_key`/`credential_pass_key` are
> deployment conventions sourced from internal config
> (`/etc/aqsh/config/mongodb.env`'s `*_DEFAULT` keys) by default — the
> "Default" column above is the library's last-resort fallback, used only
> when neither the caller nor internal config sets a value. See
> `docs/mongodb/recovery.md` "API Reference" and CLAUDE.md "Configuration
> Layers".

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
| Replication lag | ≥ 10 s | ≥ 60 s |
| Oplog window | < 3 days | < 1 day |
| WiredTiger cache dirty pages | ≥ 80% | ≥ 95% |
| Connection utilisation | ≥ 80% | ≥ 90% |
| Global lock queue | ≥ 3 | ≥ 10 |
| Long-running operations | ops > 60 s | — |

Thresholds follow MongoDB Atlas default alert levels. Standalone instances skip RS-only checks automatically.

## Permissions

| Field | Value |
|-------|-------|
| `allowed_groups` | `system:serviceaccounts` |
| Timeout | 5 minutes |

RBAC: `aqsh-mongo-manager` ClusterRole grants `get` on `secrets`, `get`/`list` on `pods`, and `create` on `pods/exec` in `mongo-1/2/3`.

## Example

See [examples/mongodb/sanity-check.sh](../../examples/mongodb/sanity-check.sh) for a runnable end-to-end script.

For run account lifecycle, expiry reconciliation, and account mutation operations, see [docs/mongodb/create-account.md](create-account.md).

```bash
MONGODB_AQSH_URL="http://<cluster-dbs-ip>:30082"

# Minimal — check mongo-1 with all defaults
curl -s -X POST "$MONGODB_AQSH_URL/tasks/sanity-check" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mongo-1"}'

# Override StatefulSet name and credential secret
curl -s -X POST "$MONGODB_AQSH_URL/tasks/sanity-check" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace":         "mongo-2",
    "sts_name":          "mongodb",
    "credential_secret": "my-custom-secret"
  }'
```

## Sample Log Output

```
══ MongoDB Sanity Check ══════════════════════════════════════════
Namespace       : mongo-1
STS             : mongodb
PVC path        : /data/db  (warn: 80%  crit: 90%)
Lag thresholds  : warn ≥ 10s  crit ≥ 60s
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
