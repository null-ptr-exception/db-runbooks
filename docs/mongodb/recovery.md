# MongoDB Data Recovery (aqsh-mongodb)

Automated recovery workflow for corrupted or out-of-sync MongoDB StatefulSet
replicas. Works against any image/layout (Bitnami helm chart, standard
`mongo:N` images, hardened Bitnami images with file-mounted secrets) — the
naming/credential/path convention is resolved automatically from live
cluster state, not declared per call. Works without `kubectl delete pod`,
`kubectl delete pvc`, or node cordon — only ConfigMap and StatefulSet `patch`
permissions are needed.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [How It Works](#how-it-works)
3. [Prerequisites](#prerequisites)
4. [One-Time Setup](#one-time-setup)
5. [API Reference](#api-reference)
6. [Pre-Flight Gates G1–G8](#pre-flight-gates-g1g8)
7. [Scenarios and Runbook](#scenarios-and-runbook)
8. [Exception Scenarios](#exception-scenarios)
9. [RBAC Requirements](#rbac-requirements)
10. [API Examples](#api-examples)
11. [Test Coverage Notes](#test-coverage-notes)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Operator (you / aqsh task)                                     │
│                                                                 │
│  1. POST /tasks/recovery/pre-check  ──→  G1–G8 gates report    │
│  2. POST /tasks/recovery/wipe       ──→  patch CM + patch STS  │
│  3. <pod restarts>                                              │
│     └─ init container checks wipe-targets                       │
│         └─ hostname match → delete data dir contents            │
│         └─ MongoDB starts empty → initial sync from primary     │
│  4. POST /tasks/recovery/reset      ──→  clear CM + partition   │
└─────────────────────────────────────────────────────────────────┘

         StatefulSet (partition controls restart scope)
         ┌─────────┐  ┌─────────┐  ┌─────────┐
         │  pod-0  │  │  pod-1  │  │  pod-2  │
         │ PRIMARY │  │  SEC.   │  │  SEC.   │
         └────┬────┘  └─────────┘  └────┬────┘
              │    replSet sync          │  ← wipe target
              └──────────────────────────┘

         Recovery ConfigMap
         ┌────────────────────────────────┐
         │ wipe-targets: "mongodb-2"      │  ← set by wipe task
         │ recovery-version: "1700000000" │  ← bumped to trigger rollout
         └────────────────────────────────┘
```

### Key Design Decisions

| Constraint | Solution |
|---|---|
| No `kubectl delete pvc` | Init container wipes the data directory (`/data/db` for standard `mongo:N`) from inside the pod |
| Pod in CrashLoopBackOff | Init containers run before the main container regardless of crash state |
| No `kubectl delete pod` | StatefulSet `partition` + annotation bump triggers a targeted rolling restart |
| No node cordon needed | All operations are K8s control-plane only (ConfigMap + StatefulSet patches) |

---

## How It Works

### Init Container as Fake PVC Deletion

The `data-recovery` init container runs on every pod start.  It reads
`/recovery-config/wipe-targets` from the ConfigMap:

- **Hostname matches**: wipe the data directory → MongoDB starts empty → auto initial-sync
- **Hostname not in list**: skip, proceed normally

### Data Paths and Credentials Are Auto-Detected, Not Task Inputs

The gates (`du` for G5, `df` for G6) and the init container must agree on
where the data lives, and the gates must authenticate as a real MongoDB
user. None of `sts_name`, `recovery_configmap`, `credential_secret`,
`credential_user`, `credential_user_key`, `credential_pass_key`,
`data_path`, or `mount_path` are task inputs — there is no per-call way to
pass any of them (see CLAUDE.md "Configuration Layers" for why: these
tasks operate on something close to a destructive action, so the API
surface is deliberately kept to `namespace` + the genuinely per-call
operational decisions). Resolution is a 3-tier chain with no task-input
override:

1. **Internal config** — set once per cluster in
   `/etc/aqsh/config/mongodb.env`'s `*_DEFAULT` keys
   (`RECOVERY_DATA_PATH_DEFAULT`, `MONGO_CRED_SECRET_DEFAULT`, etc.) when a
   deployment's convention can't be (or shouldn't be) discovered live.
2. **Live auto-detect** — query the StatefulSet/mongod directly instead of
   guessing a Bitnami-vs-official-image profile:
   - `sts_name` — from the target pod's `ownerReferences`
   - `recovery_configmap` — from the `data-recovery` init container's own
     volume binding
   - `credential_secret`/`credential_user`/keys — from the StatefulSet's
     container env: `secretKeyRef` for `MONGO_INITDB_ROOT_USERNAME/PASSWORD`
     (official image) or `MONGODB_ROOT_USER/PASSWORD` (Bitnami), or the
     hardened-Bitnami file-mounted-secret convention (a `*_FILE`-suffixed
     env var holding a path into a Secret-backed volume mount)
   - `data_path`/`mount_path` — by asking mongod itself for its real dbPath
     (`db.serverCmdLineOpts().parsed.storage.dbPath`, falling back to
     mongod's own compiled-in default `/data/db` when no `--dbpath`/config-file
     setting was given), reusing the same value for both `du` and `df`
3. **Library hardcoded fallback** — Bitnami helm chart paths
   (`/bitnami/mongodb/data/db` / `/bitnami/mongodb`), `mongodb-credentials`
   secret with keys `MONGO_ROOT_USER`/`MONGO_ROOT_PASS`, StatefulSet name
   `mongodb`, ConfigMap `mongodb-recovery-config`

Detection always fails *soft*: if it can't find a confident signal (no
env-based credential wiring at all, more than one StatefulSet in the
namespace with no target pod to disambiguate), it falls through to tier 3
exactly as before — it never guesses. If a deployment's convention is so
unusual that neither detection nor the hardcoded fallback can resolve it,
internal config remains the only override.

| Deployment | Real `data_path`/`mount_path` | Resolved via |
|---|---|---|
| Bitnami helm chart | `/bitnami/mongodb/data/db` / `/bitnami/mongodb` | live detect (explicit `--dbpath`) or hardcoded fallback |
| Standard `mongo:N` image (this repo's test fixture) | `/data/db` / `/data/db` | live detect (mongod's compiled-in default) |

> If detection or internal config ever resolves the wrong path, `du` returns
> nothing and the size gates **silently degrade**: G5 passes with a warn
> ("size unknown") and G4/G6 are skipped.  A pre-check that passes with
> `warn > 0` may not have actually verified oplog or disk space — read the
> per-gate messages.

### StatefulSet Partition for Targeted Restart

`spec.updateStrategy.rollingUpdate.partition: N` means only pods with
ordinal ≥ N restart when the pod template changes.

| Goal | Set partition to |
|---|---|
| Restart only pod-2 | `2` |
| Restart only pod-1 (pod-2 restarts too but has no wipe-target — safe) | `1` |
| Restart only pod-0 (verify no primary first via G7) | `0` |
| Locked — no auto-restart | replica count (e.g. `3`) |

> **Quorum warning for lower-ordinal targets**: pods above the partition that
> sit on an older controller revision restart **at the same time** as the
> target. Wiping pod-1 in a 3-member RS therefore restarts pod-1 *and* pod-2
> together — 2 of 3 members down means the replica set loses its majority and
> the primary steps down until one of them rejoins. Prefer recovering the
> highest ordinal first, or accept a brief write outage. (The integration
> tests only exercise the highest-ordinal case, mongodb-2.)

### Critical: Clear wipe-targets Immediately After Pod Enters Running

The wipe-targets flag persists in the ConfigMap.  If cleared too late and
the pod restarts again for any reason, the init container will wipe data
a second time mid-sync.

**Always run `recovery/reset` as soon as the target pod enters Running
state** — before the initial sync finishes.

---

## Prerequisites

The recovery system **requires MongoDB to run in Replica Set mode with at least
2 members**.  Standalone deployments are not supported:

| Gate | Standalone behaviour | RS behaviour |
|---|---|---|
| G3 `NO_HEALTHY_SOURCE` | Always fails — the target IS the only pod, so no sync source exists | Passes when at least one other member is healthy |
| G7 `TARGET_IS_PRIMARY` | Always blocks — `db.hello().ismaster` is `true` on standalone; `rs.stepDown()` is not valid | Correctly checks RS role; standalone sets `h.setName=undefined` so the gate skips |

This repo's `mongo-1` test namespace deploys as a single-replica standalone by
default (see `tests/chart/templates/mongodb.yaml`); the `recovery.bats`
integration suite upgrades it to a 3-replica RS (`--replSet rs0`) in its
`setup_file`, initialises the replica set, and creates the root user — see
that file for a working reference of every step below.

**Minimum conditions before calling any recovery task:**

1. StatefulSet has `replicas ≥ 2` and pods are running with `--replSet <name>`
2. Replica set is initiated (`rs.initiate()` has been called and a primary has been elected)
3. `data-recovery` init container is present in the STS spec (G1)
4. `mongodb-recovery-config` ConfigMap exists in the namespace (G2)

---

## One-Time Setup

> **This repo's MongoDB test fixture uses the standard `mongo:N` image.**
> `tests/mongodb/recovery.bats`'s `setup_file` runs the same script below
> (`--profile standard`) against the `mongo-1` namespace before any recovery
> test runs. Run it manually only when setting up a namespace outside that
> test flow.

Apply the recovery ConfigMap (satisfies G2) and patch the StatefulSet to add
the `data-recovery` init container (satisfies G1) using the canonical setup
script — this is the single source of truth for the init-container/wipe
logic; it's not duplicated between this doc and the test fixture.

```bash
CONTEXT=kind-cluster-a          # always target an explicit cluster
NAMESPACE=<YOUR_NAMESPACE>
STS=mongodb

# Standard `mongo:N` image:
aqsh-tasks/scripts/mongodb/recovery/setup-data-recovery.sh \
  --context "$CONTEXT" --namespace "$NAMESPACE" --sts "$STS" --profile standard

# Bitnami helm chart:
aqsh-tasks/scripts/mongodb/recovery/setup-data-recovery.sh \
  --context "$CONTEXT" --namespace "$NAMESPACE" --sts "$STS" --profile bitnami
```

| Profile | volume name | mount path | `runAsUser` |
|---|---|---|---|
| `standard` (this repo's test fixture) | `data` | `/data/db` | 999 |
| `bitnami` | `datadir` | `/bitnami/mongodb` | 1001 |

> **Note**: The StatefulSet patch triggers a rolling update.  With `partition`
> set to the replica count (e.g. `3`) no pods restart automatically — the
> partition is the lock.  The running pods therefore do **not** have the init
> container yet; it materialises on the target pod the first time a wipe lowers
> the partition.

> `data_path`/`mount_path` are not task inputs — recovery tasks detect the
> real path live from mongod (see "Data Paths and Credentials Are
> Auto-Detected" above). Internal config (`RECOVERY_DATA_PATH_DEFAULT`/
> `RECOVERY_MOUNT_PATH_DEFAULT`) remains available only for deployments
> where detection can't resolve it. See CLAUDE.md "Configuration Layers".

---

## API Reference

All tasks are available via `POST /tasks/<name>` on the aqsh-mongodb endpoint.

Task timeouts (from `tasks-mongodb.yaml`): `recover` 12m, `wipe` 10m,
`fix-no-primary` 8m, `pre-check` 5m, `reset` 3m, `status` 2m.

> **`sts_name`, `credential_secret`, `credential_user`, `credential_user_key`,
> `credential_pass_key`, `recovery_configmap`, `data_path`, `mount_path`** are
> **not task inputs** — every call below needs only `namespace` plus the
> genuinely per-call fields shown in each task's Input table (`target_pod`,
> `force_wipe`, `level`, etc.). These naming/credential/path values resolve
> automatically: internal config (`/etc/aqsh/config/mongodb.env`'s
> `*_DEFAULT` keys) → live cluster auto-detect → hardcoded library fallback.
> There is no per-call override; if a deployment's convention is too unusual
> for detection to resolve, internal config is the only escape hatch. See
> CLAUDE.md "Configuration Layers" for the full precedence rule and the
> "Data Paths and Credentials Are Auto-Detected" section above for how
> detection works.

There are two ways to drive recovery:

- **`recovery/recover`** — the recommended **one-call orchestrator** that chains
  gates → wipe → wait → reset automatically. Use this for normal recovery.
- **The individual steps** (`pre-check`, `wipe`, `reset`, `status`,
  `fix-no-primary`) — for manual, step-by-step control or for the no-primary
  repair flow.

```
recovery/recover  ≡  pre-check(gate) ─→ wipe ─→ wait(restart+Running) ─→ reset ─→ set-sync
                          │ blocks       │ patch    │ auto, no human       │ auto     │ best-effort
                          ▼              ▼          ▼                      ▼          ▼
                       G1–G8        CM+STS      poll pod UID change    clear CM   replSetSyncFrom
```

### `recovery/recover`  ⭐ recommended

**Destructive but fully automated.** Runs the entire workflow in a single call
and automatically closes the dangerous "clear wipe-target the instant the pod
is Running" race that you would otherwise have to hit by hand.

Sequence:
1. Capture the target pod's current UID
2. Run G1–G8 gates (aborts here if any blocking gate fails — nothing is changed)
3. `wipe`: patch ConfigMap `wipe-targets` + StatefulSet partition + annotation
4. Poll until the pod is **recreated** (UID changes → init container has run and
   wiped data) **and** reaches `Running`
5. `reset`: clear `wipe-targets` + restore partition the instant the pod is Running
6. Best-effort `replSetSyncFrom` to point the pod at a healthy secondary
   (non-fatal: on a freshly wiped member authentication only works once
   initial sync has cloned `admin.system.users`, so this often fails and
   MongoDB picks its own sync source — `sync_source_set: false` in the result)

Initial sync is **not** awaited (it can take a long time for large data) — the
response tells you to monitor it with `recovery/status`.

> On timeout (pod never restarts or never reaches Running) it **does not** reset
> — it leaves `wipe-targets` in place and returns an error so you can
> investigate, rather than silently skipping the wipe.

**Input**

| Name | Env | Required | Default |
|---|---|---|---|
| `namespace` | `DB_NAMESPACE` | yes | — |
| `target_pod` | `RECOVERY_TARGET_POD` | **yes** | — |
| `force_wipe` | `FORCE_WIPE` | no | `"false"` |
| `wait_timeout` | `RECOVERY_WAIT_TIMEOUT` | no | `"300"` (seconds) |

`sts_name`/`recovery_configmap`/credential secret-and-keys/`data_path`/
`mount_path` are not task inputs — see "Data Paths and Credentials Are
Auto-Detected" above.

> `wait_timeout` only covers the restart-and-reach-Running poll. Keep it well
> under the aqsh task timeout (12m for `recovery/recover`) so the gates and
> reset still fit — otherwise aqsh kills the task mid-flight with
> `wipe-targets` still set.

**Output (success)**

```json
{
  "target_pod": "mongodb-2",
  "old_uid": "a1b2c3...",
  "recreated": true,
  "reached_running": true,
  "sync_source_set": false,
  "partition_restored": 3,
  "elapsed_seconds": 47,
  "next_step": "Monitor initial sync with recovery/status and rs.status() until the pod catches up to the primary (SECONDARY, optime in sync)"
}
```

**Output (gate abort)** — nothing was changed:

```json
{
  "phase": "gates",
  "gates": { "gates": [ ... ], "fail": 1, ... },
  "target_pod": "mongodb-2"
}
```

**Example**

```bash
curl -s -X POST "$URL/tasks/recovery/recover" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"namespace":"mongo-1","target_pod":"mongodb-2"}'
# → returns a task id; poll /executions/<id>; then monitor sync via recovery/status
```

---

### `recovery/status`

Read-only.  Returns current recovery state: ConfigMap wipe-targets, StatefulSet
partition, and pod phases.

> Pod `phase` is Kubernetes-level only — a pod mid-initial-sync still shows
> `Running`.  To see replication progress (`STARTUP2` → `SECONDARY`, optime
> catch-up) use `rs.status()` inside a healthy member, e.g.
> `kubectl --context <ctx> -n <ns> exec <sts>-0 -- mongosh ... --eval "rs.status()"`.

**Input**

| Name | Env | Required | Default |
|---|---|---|---|
| `namespace` | `DB_NAMESPACE` | yes | — |

`sts_name`/`recovery_configmap` are not task inputs — see "Data Paths and
Credentials Are Auto-Detected" above.

**Output**

```json
{
  "sts": "mongodb",
  "configmap_found": true,
  "wipe_targets": "",
  "active_recovery": false,
  "partition": "3",
  "replicas": "3",
  "pods": [
    {"pod": "mongodb-0", "phase": "Running"},
    {"pod": "mongodb-1", "phase": "Running"},
    {"pod": "mongodb-2", "phase": "Running"}
  ]
}
```

---

### `recovery/pre-check`

Read-only.  Runs all G1–G8 pre-flight gates for a target pod and returns a
full report without making any changes.

**Input**

| Name | Env | Required | Default |
|---|---|---|---|
| `namespace` | `DB_NAMESPACE` | yes | — |
| `target_pod` | `RECOVERY_TARGET_POD` | **yes** | — |
| `force_wipe` | `FORCE_WIPE` | no | `"false"` |

`sts_name`/`recovery_configmap`/credential secret-and-keys/`data_path`/
`mount_path` are not task inputs — see "Data Paths and Credentials Are
Auto-Detected" above.

> The detected/configured credentials must resolve to a **real MongoDB
> user** (root role) present in `admin.system.users` — the gates
> authenticate via mongosh even when the deployment runs without `--auth`,
> and MongoDB rejects authentication for nonexistent users regardless of
> the authorization mode.

**Output**

```json
{
  "gates": [
    {"gate": "G1", "pass": true, "message": "Init container data-recovery present"},
    {"gate": "G2", "pass": true, "message": "Recovery ConfigMap mongodb-recovery-config exists"},
    {"gate": "G3", "pass": true, "message": "Primary elected and healthy sync source available: mongodb-0"},
    {"gate": "G4", "pass": true, "message": "Oplog window sufficient: 4096MB (window 24h) >= required 2048MB"},
    {"gate": "G5", "pass": true, "message": "Data size 20480MB (20GB) is within the 100GB limit", "data_mb": 20480},
    {"gate": "G6", "pass": true, "message": "PVC available space 50000MB >= required 24576MB"},
    {"gate": "G7", "pass": true, "message": "Target mongodb-2 is not PRIMARY — safe to wipe"},
    {"gate": "G8", "pass": true, "message": "No members in RECOVERING state"}
  ],
  "pass": 8,
  "fail": 0,
  "warn": 0,
  "target_pod": "mongodb-2"
}
```

**Output (with a blocking gate)** — the aqsh task still finishes as
`completed` in report mode; failure is expressed in the payload, so always
check `fail` (and per-gate `code`) rather than the task status:

```json
{
  "gates": [
    {"gate": "G1", "pass": true,  "message": "..."},
    {"gate": "G7", "pass": false, "code": "TARGET_IS_PRIMARY",
     "message": "Target mongodb-0 is currently PRIMARY — wiping will cause an election and brief write unavailability",
     "suggestion": "Run rs.stepDown(60) inside the pod or wait for automatic step-down, then re-run wipe"}
  ],
  "pass": 7,
  "fail": 1,
  "warn": 0,
  "target_pod": "mongodb-0"
}
```

Failing gates carry a machine-readable `code` (e.g. `STS_NOT_FOUND`,
`INIT_CONTAINER_MISSING`, `CONFIGMAP_MISSING`, `NO_PRIMARY`,
`NO_HEALTHY_SOURCE`, `OPLOG_TOO_SMALL`, `DATA_TOO_LARGE`,
`INSUFFICIENT_PVC_SPACE`, `TARGET_IS_PRIMARY`) plus a `suggestion`; warn-only
results may carry `OPLOG_RESIZE_NEEDED` or size-unknown skip messages.

---

### `recovery/wipe`

**Destructive**.  Runs G1–G8 gates (blocking — the task **fails** on the
first blocking gate, unlike pre-check), then patches the ConfigMap and
StatefulSet to trigger a targeted pod restart where the init container wipes
the data directory.

If the StatefulSet patch fails after the ConfigMap was already updated, the
ConfigMap is rolled back automatically so no stale wipe-target is left behind.

**Input**: same as `recovery/pre-check` (`namespace`, `target_pod`,
`force_wipe`).

**Output**

```json
{
  "target_pod": "mongodb-2",
  "ordinal": 2,
  "partition_set": 2,
  "configmap": "mongodb-recovery-config",
  "next_step": "Monitor pod restart; run recovery/reset once pod is Running and before sync completes"
}
```

**Post-wipe workflow**:

1. Monitor: `kubectl --context <ctx> -n <ns> get pods -w`
2. When target pod enters `Running`: immediately run `recovery/reset`
3. Monitor sync: watch `rs.status()` until target pod's `optimeDate` catches up to primary

---

### `recovery/reset`

Clears `wipe-targets` in the ConfigMap and restores the StatefulSet partition
to the replica count (locked state).  Idempotent — safe to run when no
recovery is active.

The partition value is read live from `spec.replicas`; if the StatefulSet
cannot be read it falls back to `3` — verify with `recovery/status` if your
replica set is not 3 members.

The two steps are deliberately ordered: `wipe-targets` is cleared **first**
(stops any further re-wipe), then the partition is restored — so even a
partial failure cannot leave a wipe armed.

> Run this **immediately after** the target pod enters `Running` state.

**Input**

| Name | Env | Required | Default |
|---|---|---|---|
| `namespace` | `DB_NAMESPACE` | yes | — |

`sts_name`/`recovery_configmap` are not task inputs — see "Data Paths and
Credentials Are Auto-Detected" above.

**Output**

```json
{
  "sts": "mongodb",
  "configmap": "mongodb-recovery-config",
  "partition": 3
}
```

---

### `recovery/fix-no-primary`

Restores a primary when all RS members show `SECONDARY` with no `PRIMARY`
(E1+E5 combined scenario).  Use the four escalation levels in order.

On failure the task is marked **failed** and the result contains an
`{"error": ...}` payload (e.g. `unfreeze` errors only when `rs.freeze(0)`
failed on *every* reachable pod — partial success still counts as success
with per-pod `results`).

**Input**

| Name | Env | Required | Default |
|---|---|---|---|
| `namespace` | `DB_NAMESPACE` | yes | — |
| `level` | `RECOVERY_LEVEL` | **yes** | — |
| `force_primary_pod` | `RECOVERY_FORCE_POD` | no (required if level=force-primary) | `""` |

`sts_name`/credential secret-and-keys are not task inputs — see "Data Paths
and Credentials Are Auto-Detected" above. Without a `target_pod` input,
`sts_name` detection falls back to namespace-listing (only resolves when
exactly one StatefulSet exists in the namespace).

Valid `level` values: `diagnose` | `unfreeze` | `reconfig` | `force-primary`

**Level: `diagnose`** (read-only)
```json
{
  "diagnosis": "ALL_SECONDARY_NO_PRIMARY",
  "recommendation": "E1+E5: run fix-no-primary level=unfreeze first ...",
  "primary_count": 0,
  "secondary_count": 3,
  "members": [
    {"pod": "mongodb-0", "phase": "Running", "state": "SECONDARY", "health": 1, "optime_ts": 1700000000},
    {"pod": "mongodb-1", "phase": "Running", "state": "SECONDARY", "health": 1, "optime_ts": 1699999000},
    {"pod": "mongodb-2", "phase": "Running", "state": "SECONDARY", "health": 1, "optime_ts": 1699998000}
  ]
}
```

**Level: `unfreeze`** — sends `rs.freeze(0)` to all pods
```json
{"success_count": 3, "fail_count": 0, "results": [...]}
```

**Level: `reconfig`** — forces `rs.reconfig({force:true})` with priority=1/votes=1 on all members
```json
{"reconfig_pod": "mongodb-0", "result": {"ok": 1}}
```

**Level: `force-primary`** — shrinks RS to `force_primary_pod` only, waits for election, then re-adds others
```json
{
  "force_pod": "mongodb-0",
  "shrink_result": {"ok": 1},
  "re_add_results": [
    {"pod": "mongodb-1", "host": "mongodb-1.mongodb...:27017", "result": {"ok": 1}},
    {"pod": "mongodb-2", "host": "mongodb-2.mongodb...:27017", "result": {"ok": 1}}
  ],
  "note": "Verify with rs.status() — allow 15-30s for election to finalize"
}
```

---

## Pre-Flight Gates G1–G8

All gates run before any wipe operation.  In `pre-check` they run in *report
mode* (all results collected).  In `wipe` they run in *gate mode* (exit on
first blocking failure).

| Gate | Check | Failure behavior | Suggestion |
|---|---|---|---|
| **G1** | Init container `data-recovery` is in the STS spec | BLOCK | Apply the One-Time Setup patch above |
| **G2** | ConfigMap `mongodb-recovery-config` exists | BLOCK | Apply the One-Time Setup ConfigMap above |
| **G3** | ≥1 healthy sync source (health=1) and a PRIMARY is elected | BLOCK | Run `recovery/fix-no-primary level=diagnose` |
| **G4** | Oplog window ≥ estimated sync time (auto-resize in gate mode only; pre-check stays read-only) | BLOCK if resize fails | `db.adminCommand({replSetResizeOplog:1,size:N})` |
| **G5** | Data size < 100 GB (overridable with `force_wipe=true`) | BLOCK | Use VolumeSnapshot or mongodump for large datasets |
| **G6** | PVC available space ≥ data × 1.2 | BLOCK | Expand PVC or free space |
| **G7** | Target pod must NOT be the current PRIMARY (checked regardless of ordinal — any pod can become primary after `recovery_fix_reconfig`) | BLOCK | Wait for step-down or run `rs.stepDown(60)` |
| **G8** | No other pod is currently RECOVERING | **WARN only** | Wait for prior sync to complete |

### G4: Oplog Window Auto-Calculation

G4 queries the primary's oplog to calculate write rate and required window:

```
write_rate   = current_oplog_MB / window_hours
sync_time    = max(1h, data_MB / (5 × 1024)) hours   [5 GB/hr conservative]
required_win = max(4h, sync_time × 2)                  [2× safety, 4h minimum]
required_MB  = max(2048, data_MB × 5%, write_rate × required_win)
```

If `current_oplog_MB < required_MB`:
1. In `recovery/pre-check` (report mode): **no resize** — pre-check is strictly
   read-only and reports `OPLOG_RESIZE_NEEDED` as a **WARN** (pass)
2. In `recovery/wipe` / `recovery/recover` (gate mode): attempts
   `replSetResizeOplog` on the primary automatically → **WARN** (pass)
3. If the gate-mode resize fails → **BLOCK** with exact manual command

Example output for G4:
```
Current: 4096 MB  |  Window: 12h  |  Write rate: 341 MB/h
Data: 20480 MB    |  Est. sync: 4h  |  Required window: 8h
Required oplog: 2730 MB  →  PASS (4096 >= 2730)
```

---

## Scenarios and Runbook

### Phase 0: Always run pre-check first

```bash
TOKEN=$(kubectl --context kind-cluster-b -n mongo-core create token test-client --duration=30m)
URL="http://aqsh-mongodb.kind-a.test:30080"

curl -s -X POST "$URL/tasks/recovery/pre-check" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"namespace":"mongo-1","target_pod":"mongodb-2"}' | jq .
```

Check that all gates pass (or only G8 warns) before proceeding.

---

### Scenario A: Corrupted Secondary (any non-primary pod)

The simplest and safest scenario.

**`recovery/recover` — one-call automated API (recommended):**

```bash
# Gates, wipe, wait-for-restart, and reset are all handled automatically
POST /tasks/recovery/recover  {"namespace":"mongo-1","target_pod":"mongodb-2"}

# Then monitor initial sync until the pod catches up:
POST /tasks/recovery/status   {"namespace":"mongo-1"}
# or: kubectl --context kind-cluster-a -n mongo-1 exec mongodb-0 -- mongosh ... --eval "rs.status()"
```

**Manual step-by-step (for special cases or debugging):**

```bash
# Step 1: verify pre-check passes
POST /tasks/recovery/pre-check  {"namespace":"mongo-1","target_pod":"mongodb-2"}

# Step 2: initiate wipe
POST /tasks/recovery/wipe       {"namespace":"mongo-1","target_pod":"mongodb-2"}

# Step 3: monitor pod restart
kubectl --context kind-cluster-a -n mongo-1 get pods -w
# When mongodb-2 shows Running (not Terminating/Init):

# Step 4: clear recovery state IMMEDIATELY
POST /tasks/recovery/reset      {"namespace":"mongo-1"}

# Step 5: verify sync (run repeatedly until optimeDate matches primary)
kubectl --context kind-cluster-a -n mongo-1 exec mongodb-0 -- mongosh ... --eval "rs.status()" | grep -E 'name|stateStr|optimeDate'
```

---

### Scenario B: Corrupted Primary (pod-0 or whichever pod holds PRIMARY)

Pod-0 starts with `priority=2` (set during RS init) so it becomes primary by
default, but after `recovery_fix_reconfig` resets member priorities all pods
become equal candidates.  G7 checks `db.hello()`
on the target pod regardless of its ordinal and blocks if it is currently
PRIMARY.  Wait for automatic election after a crash, or trigger stepDown.

```bash
# Step 1: check if election happened
POST /tasks/recovery/fix-no-primary {"namespace":"mongo-1","level":"diagnose"}
# → look for "primary_count": 1 with pod != mongodb-0

# Step 2: run pre-check targeting pod-0
POST /tasks/recovery/pre-check     {"namespace":"mongo-1","target_pod":"mongodb-0"}
# G7 should pass if pod-0 is no longer PRIMARY

# Step 3–5: same as Scenario A
```

---

### Scenario C: Pod in CrashLoopBackOff

The init container approach was designed for this case.  The init container
runs BEFORE the main MongoDB container, so the wipe succeeds even when the
pod is looping.

No special handling needed — follow the same steps as Scenario A or B.
Monitor `kubectl logs <pod> -c data-recovery` to verify wipe ran.

---

## Exception Scenarios

| Code | Scenario | Resolution |
|---|---|---|
| **E1** | Oplog window too small | G4 auto-resizes; if that fails, manually resize |
| **E2** | Pod restarts mid-sync | Ensure `recovery/reset` was run promptly; re-run wipe if needed |
| **E3** | pod-0 re-initiates RS | G7 gate prevents this; do not wipe pod-0 while it is PRIMARY |
| **E4** | Data > 100GB | Use VolumeSnapshot or mongodump; set `force_wipe=true` to override |
| **E5** | Two pods down (quorum lost) | Restore quorum first using `fix-no-primary` |
| **E1+E5** | All three pods show SECONDARY, no PRIMARY | See below |

### E1+E5: All Secondary, No Primary

```bash
# Level 1: diagnose
POST /tasks/recovery/fix-no-primary {"namespace":"mongo-1","level":"diagnose"}
# If diagnosis == ALL_SECONDARY_NO_PRIMARY:

# Level 2: unfreeze (allow elections)
POST /tasks/recovery/fix-no-primary {"namespace":"mongo-1","level":"unfreeze"}
# Wait 15s, then re-run diagnose. If still no primary:

# Level 3: force reconfig
POST /tasks/recovery/fix-no-primary {"namespace":"mongo-1","level":"reconfig"}
# Wait 30s, then re-run diagnose. If still no primary:

# Level 4: force-primary (last resort — pick the pod with the most recent optime)
POST /tasks/recovery/fix-no-primary {
  "namespace":"mongo-1",
  "level":"force-primary",
  "force_primary_pod":"mongodb-0"
}
```

After primary is restored, continue with the normal wipe flow for any pod
with corrupted data.

---

## RBAC Requirements

The `aqsh-mongo-manager` ClusterRole must include (mirrors
`tests/chart/templates/mongodb-rbac.yaml`):

```yaml
rules:
  - apiGroups: ["apps"]
    resources: ["statefulsets"]
    resourceNames: ["mongodb"]   # named get/patch
    verbs: ["get", "patch"]
  - apiGroups: ["apps"]
    resources: ["statefulsets"]
    verbs: ["list", "watch"]      # list ignores resourceNames, so a separate rule
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]            # for mongosh exec inside pods
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["mongodb-credentials"]
    verbs: ["get"]               # for reading MongoDB credentials
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["mongodb-recovery-config"]
    verbs: ["get", "patch"]      # only get/patch — see note below
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list"]       # for G6 PVC space check
```

> **`resourceNames` caveat**: an RBAC `resourceNames` restriction only applies
> to verbs that act on an existing named object (`get`, `patch`, `update`,
> `delete`). It is **ignored by `list`, `watch`, and `create`**. The recovery
> tasks never create the ConfigMap (it is applied once during setup by an
> admin) and never list it by name, so `get`/`patch` is the exact set needed.

> **`resourceNames` are templated from chart values**
> (`tests/chart/templates/mongodb-rbac.yaml`, driven by `.Values.mongodb.stsName`
> / `credentialSecret` / `recoveryConfigmap`), defaulting to today's literals
> (`mongodb`, `mongodb-credentials`, `mongodb-recovery-config`). Set those
> values to match this cluster's *real* naming convention so RBAC permits
> the actual objects detection will discover and operate on — this is a
> deploy-time concern independent of whether the script learns the name via
> internal config or by detecting it live; `sts_name`/`credential_secret`/
> `recovery_configmap` are not task inputs, so there is no caller-supplied
> name that needs separate RBAC consideration. See CLAUDE.md "Configuration
> Layers".

**Not required**: `pods/delete`, `persistentvolumeclaims/delete`, node access,
`configmaps` create/update/list.

---

## API Examples

```bash
TOKEN=$(kubectl --context kind-cluster-b -n mongo-core create token test-client --duration=30m)
URL="http://aqsh-mongodb.kind-a.test:30080"

# 1. Status
curl -s -X POST "$URL/tasks/recovery/status" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"namespace":"mongo-1"}' | jq .

# 2. Pre-check (target pod-2)
curl -s -X POST "$URL/tasks/recovery/pre-check" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"namespace":"mongo-1","target_pod":"mongodb-2"}' | jq .

# 3. Wipe pod-2
TASK=$(curl -s -X POST "$URL/tasks/recovery/wipe" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"namespace":"mongo-1","target_pod":"mongodb-2"}')
TASK_ID=$(echo "$TASK" | jq -r '.id')

# 4. Poll task status
curl -s "$URL/executions/$TASK_ID" -H "Authorization: Bearer $TOKEN" | jq .

# 5. Reset after pod enters Running
curl -s -X POST "$URL/tasks/recovery/reset" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"namespace":"mongo-1"}' | jq .

# 6. Diagnose no-primary scenario
curl -s -X POST "$URL/tasks/recovery/fix-no-primary" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"namespace":"mongo-1","level":"diagnose"}' | jq .
```

---

## Test Coverage Notes

Integration tests (`tests/mongodb/recovery.bats`) exercise the full
`recovery/recover` path against a real 3-member RS — including both
mongodb-1 and mongodb-2 as targets, and the `recovery/wipe` + manual
`recovery/reset` split flow. They also pin down that `setup_file`'s own
RS bootstrap is idempotent — re-running `rs.initiate()` against an
already-initialised set and `createUser` against an existing root user must
not crash.

`tests/mongodb/recovery_autodetect.bats` and
`recovery_autodetect_file_mount.bats` prove live auto-detection end-to-end
against fixtures deliberately shaped to differ from the hardcoded-literal
fallback (non-default credential key names, a literal username, a real
dbPath that mismatches the Bitnami-literal default, and — in the
file-mount variant — the hardened-Bitnami `*_PASSWORD_FILE` convention):
`recovery/pre-check` is called with only `namespace`+`target_pod` and must
still resolve credentials/data_path correctly purely via detection.
`recovery_bitnami_profile.bats` and `recovery_custom_naming.bats` cover the
internal-config override tier the same way. `tests/unit/mongodb/
recovery-detect.bats` covers the `_recovery_detect_*`/`recovery_resolve_*`
functions directly (mocked kubectl), including every fail-soft path
(ambiguous StatefulSet count, no env-based credential wiring, mismatched
username/password secrets).

The following paths are deliberately **not** covered by integration tests
and rely on unit tests + this runbook:

- `fix-no-primary` levels `unfreeze` / `reconfig` / `force-primary`
  (require deliberately breaking the cluster)
- The recover timeout path where `wipe-targets` is intentionally left in
  place for manual investigation
