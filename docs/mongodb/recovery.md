# MongoDB Data Recovery (aqsh-mongodb)

Automated recovery workflow for corrupted or out-of-sync Bitnami MongoDB
StatefulSet replicas.  Works without `kubectl delete pod`, `kubectl delete pvc`,
or node cordon — only ConfigMap and StatefulSet `patch` permissions are needed.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [How It Works](#how-it-works)
3. [One-Time Setup](#one-time-setup)
4. [API Reference](#api-reference)
5. [Pre-Flight Gates G1–G8](#pre-flight-gates-g1g8)
6. [Scenarios and Runbook](#scenarios-and-runbook)
7. [Exception Scenarios](#exception-scenarios)
8. [RBAC Requirements](#rbac-requirements)
9. [API Examples](#api-examples)

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
│         └─ hostname match → rm -rf /bitnami/mongodb/data/db     │
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
| No `kubectl delete pvc` | Init container wipes `/bitnami/mongodb/data/db` from inside the pod |
| Pod in CrashLoopBackOff | Init containers run before the main container regardless of crash state |
| No `kubectl delete pod` | StatefulSet `partition` + annotation bump triggers a targeted rolling restart |
| No node cordon needed | All operations are K8s control-plane only (ConfigMap + StatefulSet patches) |

---

## How It Works

### Init Container as Fake PVC Deletion

The `data-recovery` init container runs on every pod start.  It reads
`/recovery-config/wipe-targets` from the ConfigMap:

- **Hostname matches**: wipe `/bitnami/mongodb/data/db` → MongoDB starts empty → auto initial-sync
- **Hostname not in list**: skip, proceed normally

### StatefulSet Partition for Targeted Restart

`spec.updateStrategy.rollingUpdate.partition: N` means only pods with
ordinal ≥ N restart when the pod template changes.

| Goal | Set partition to |
|---|---|
| Restart only pod-2 | `2` |
| Restart only pod-1 (pod-2 restarts too but has no wipe-target — safe) | `1` |
| Restart only pod-0 (verify no primary first via G7) | `0` |
| Locked — no auto-restart | replica count (e.g. `3`) |

### Critical: Clear wipe-targets Immediately After Pod Enters Running

The wipe-targets flag persists in the ConfigMap.  If cleared too late and
the pod restarts again for any reason, the init container will wipe data
a second time mid-sync.

**Always run `recovery/reset` as soon as the target pod enters Running
state** — before the initial sync finishes.

---

## One-Time Setup

Apply two Kubernetes resources to the target namespace:

```yaml
# 01-recovery-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mongodb-recovery-config
  namespace: <YOUR_NAMESPACE>
data:
  wipe-targets: ""
  recovery-version: "0"
```

```bash
# Patch the StatefulSet to add the init container and set partition=3 (locked)
NAMESPACE=<YOUR_NAMESPACE>
STS=mongodb
IMAGE=$(kubectl -n $NAMESPACE get sts $STS -o jsonpath='{.spec.template.spec.containers[0].image}')

kubectl -n $NAMESPACE apply -f 01-recovery-configmap.yaml

kubectl -n $NAMESPACE patch statefulset $STS --type=strategic -p "$(cat <<EOF
{
  "spec": {
    "updateStrategy": {"rollingUpdate": {"partition": 3}},
    "template": {
      "spec": {
        "initContainers": [{
          "name": "data-recovery",
          "image": "${IMAGE}",
          "command": ["/bin/bash", "-c"],
          "args": ["WIPE_TARGETS=\$(cat /recovery-config/wipe-targets 2>/dev/null || echo ''); MY_NAME=\$(hostname); if [ -n \"\$WIPE_TARGETS\" ] && echo \"\$WIPE_TARGETS\" | grep -qw \"\$MY_NAME\"; then echo '[RECOVERY] Wiping data for '\$MY_NAME; find /bitnami/mongodb/data/db -mindepth 1 -delete 2>/dev/null || true; echo '[RECOVERY] Wipe complete.'; else echo '[RECOVERY] '\$MY_NAME' not in wipe targets, skip.'; fi"],
          "volumeMounts": [
            {"name": "datadir", "mountPath": "/bitnami/mongodb"},
            {"name": "recovery-config-vol", "mountPath": "/recovery-config", "readOnly": true}
          ],
          "securityContext": {"runAsUser": 1001, "runAsNonRoot": true}
        }],
        "volumes": [{"name": "recovery-config-vol", "configMap": {"name": "mongodb-recovery-config"}}]
      }
    }
  }
}
EOF
)"
```

> **Note**: The StatefulSet patch triggers a rolling update.  With `partition=3`
> (for a 3-replica cluster) no pods restart automatically — the partition is
> the lock.

---

## API Reference

All tasks are available via `POST /tasks/<name>` on the aqsh-mongodb endpoint.

There are two ways to drive recovery:

- **`recovery/recover`** — the recommended **one-call orchestrator** that chains
  gates → wipe → wait → reset automatically. Use this for normal recovery.
- **The individual steps** (`pre-check`, `wipe`, `reset`, `status`,
  `fix-no-primary`) — for manual, step-by-step control or for the no-primary
  repair flow.

```
recovery/recover  ≡  pre-check(gate) ─→ wipe ─→ wait(restart+Running) ─→ reset
                          │ blocks       │ patch    │ auto, no human       │ auto
                          ▼              ▼          ▼                      ▼
                       G1–G8        CM+STS      poll pod UID change    clear CM
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

Initial sync is **not** awaited (it can take a long time for large data) — the
response tells you to monitor it with `recovery/status`.

> On timeout (pod never restarts or never reaches Running) it **does not** reset
> — it leaves `wipe-targets` in place and returns an error so you can
> investigate, rather than silently skipping the wipe.

**Input**

| Name | Env | Required | Default |
|---|---|---|---|
| `namespace` | `DB_NAMESPACE` | yes | — |
| `sts_name` | `MONGO_STS_NAME` | no | `mongodb` |
| `target_pod` | `RECOVERY_TARGET_POD` | **yes** | — |
| `recovery_configmap` | `RECOVERY_CONFIGMAP` | no | `mongodb-recovery-config` |
| `credential_secret` | `MONGO_CRED_SECRET` | no | `mongodb-credentials` |
| `credential_user_key` | `MONGO_CRED_USER_KEY` | no | `MONGO_ROOT_USER` |
| `credential_pass_key` | `MONGO_CRED_PASS_KEY` | no | `MONGO_ROOT_PASS` |
| `force_wipe` | `FORCE_WIPE` | no | `"false"` |
| `wait_timeout` | `RECOVERY_WAIT_TIMEOUT` | no | `"300"` (seconds) |

**Output (success)**

```json
{
  "target_pod": "mongodb-2",
  "old_uid": "a1b2c3...",
  "recreated": true,
  "reached_running": true,
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

**Input**

| Name | Env | Required | Default |
|---|---|---|---|
| `namespace` | `DB_NAMESPACE` | yes | — |
| `sts_name` | `MONGO_STS_NAME` | no | `mongodb` |
| `recovery_configmap` | `RECOVERY_CONFIGMAP` | no | `mongodb-recovery-config` |

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
| `sts_name` | `MONGO_STS_NAME` | no | `mongodb` |
| `target_pod` | `RECOVERY_TARGET_POD` | **yes** | — |
| `recovery_configmap` | `RECOVERY_CONFIGMAP` | no | `mongodb-recovery-config` |
| `credential_secret` | `MONGO_CRED_SECRET` | no | `mongodb-credentials` |
| `credential_user_key` | `MONGO_CRED_USER_KEY` | no | `MONGO_ROOT_USER` |
| `credential_pass_key` | `MONGO_CRED_PASS_KEY` | no | `MONGO_ROOT_PASS` |
| `force_wipe` | `FORCE_WIPE` | no | `"false"` |

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
    {"gate": "G7", "pass": true, "message": "Target pod-0 is not pod-0 — primary safety check skipped"},
    {"gate": "G8", "pass": true, "message": "No members in RECOVERING state"}
  ],
  "pass": 8,
  "fail": 0,
  "warn": 0,
  "target_pod": "mongodb-2"
}
```

---

### `recovery/wipe`

**Destructive**.  Runs G1–G8 gates (blocking), then patches the ConfigMap and
StatefulSet to trigger a targeted pod restart where the init container wipes
the data directory.

**Input**: same as `recovery/pre-check` plus `force_wipe`.

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

1. Monitor: `kubectl -n <ns> get pods -w`
2. When target pod enters `Running`: immediately run `recovery/reset`
3. Monitor sync: watch `rs.status()` until target pod's `optimeDate` catches up to primary

---

### `recovery/reset`

Clears `wipe-targets` in the ConfigMap and restores the StatefulSet partition
to the replica count (locked state).

> Run this **immediately after** the target pod enters `Running` state.

**Input**

| Name | Env | Required | Default |
|---|---|---|---|
| `namespace` | `DB_NAMESPACE` | yes | — |
| `sts_name` | `MONGO_STS_NAME` | no | `mongodb` |
| `recovery_configmap` | `RECOVERY_CONFIGMAP` | no | `mongodb-recovery-config` |

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

**Input**

| Name | Env | Required | Default |
|---|---|---|---|
| `namespace` | `DB_NAMESPACE` | yes | — |
| `sts_name` | `MONGO_STS_NAME` | no | `mongodb` |
| `credential_secret` | `MONGO_CRED_SECRET` | no | `mongodb-credentials` |
| `credential_user_key` | `MONGO_CRED_USER_KEY` | no | `MONGO_ROOT_USER` |
| `credential_pass_key` | `MONGO_CRED_PASS_KEY` | no | `MONGO_ROOT_PASS` |
| `level` | `RECOVERY_LEVEL` | **yes** | — |
| `force_primary_pod` | `RECOVERY_FORCE_POD` | no (required if level=force-primary) | `""` |

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
| **G1** | Init container `data-recovery` is in the STS spec | BLOCK | Apply `02-sts-patch.yaml` |
| **G2** | ConfigMap `mongodb-recovery-config` exists | BLOCK | Apply `01-recovery-configmap.yaml` |
| **G3** | ≥1 healthy sync source (health=1) and a PRIMARY is elected | BLOCK | Run `recovery/fix-no-primary level=diagnose` |
| **G4** | Oplog window ≥ estimated sync time (auto-resize attempted first) | BLOCK if resize fails | `db.adminCommand({replSetResizeOplog:1,size:N})` |
| **G5** | Data size < 100 GB (overridable with `force_wipe=true`) | BLOCK | Use VolumeSnapshot or mongodump for large datasets |
| **G6** | PVC available space ≥ data × 1.2 | BLOCK | Expand PVC or free space |
| **G7** | If target is pod-0, it must NOT be the current PRIMARY | BLOCK | Wait for step-down or run `rs.stepDown(60)` |
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
1. Attempts `replSetResizeOplog` on the primary automatically → **WARN** (pass)
2. If resize fails → **BLOCK** with exact manual command

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
TOKEN=$(kubectl --context kind-cluster-apps -n app-a create token test-client --duration=30m)
URL="http://<cluster-dbs-ip>:30082"

curl -s -X POST "$URL/tasks/recovery/pre-check" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"namespace":"mongo-1","target_pod":"mongodb-2"}' | jq .
```

Check that all gates pass (or only G8 warns) before proceeding.

---

### Scenario A: Corrupted Secondary (pod-1 or pod-2)

The simplest and safest scenario.

**Option 1 — one call (recommended):**

```bash
# Gates, wipe, wait-for-restart, and reset are all handled automatically
POST /tasks/recovery/recover  {"namespace":"mongo-1","target_pod":"mongodb-2"}

# Then monitor initial sync until the pod catches up:
POST /tasks/recovery/status   {"namespace":"mongo-1"}
# or: kubectl -n mongo-1 exec mongodb-0 -- mongosh ... --eval "rs.status()"
```

**Option 2 — manual step-by-step (full control):**

```bash
# Step 1: verify pre-check passes
POST /tasks/recovery/pre-check  {"namespace":"mongo-1","target_pod":"mongodb-2"}

# Step 2: initiate wipe
POST /tasks/recovery/wipe       {"namespace":"mongo-1","target_pod":"mongodb-2"}

# Step 3: monitor pod restart
kubectl -n mongo-1 get pods -w
# When mongodb-2 shows Running (not Terminating/Init):

# Step 4: clear recovery state IMMEDIATELY
POST /tasks/recovery/reset      {"namespace":"mongo-1"}

# Step 5: verify sync (run repeatedly until optimeDate matches primary)
kubectl -n mongo-1 exec mongodb-0 -- mongosh ... --eval "rs.status()" | grep -E 'name|stateStr|optimeDate'
```

---

### Scenario B: Corrupted Primary (pod-0)

Pod-0 is the Bitnami default primary.  G7 gate blocks if pod-0 is still
PRIMARY.  Wait for automatic election after pod-0 crash, or trigger stepDown.

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

The `aqsh-mongo-manager` ClusterRole must include:

```yaml
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "patch", "update", "create"]
  - apiGroups: ["apps"]
    resources: ["statefulsets"]
    verbs: ["get", "list", "patch", "update"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]            # for mongosh exec inside pods
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]               # for reading MongoDB credentials
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list"]       # for G6 PVC space check
```

**Not required**: `pods/delete`, `persistentvolumeclaims/delete`, node access.

---

## API Examples

```bash
TOKEN=$(kubectl --context kind-cluster-apps -n app-a create token test-client --duration=30m)
URL="http://$(kubectl --context kind-cluster-dbs -n db-ops get svc aqsh-mongodb -o jsonpath='{.spec.clusterIP}'):4180"
# or via NodePort: http://<cluster-dbs-ip>:30082

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
