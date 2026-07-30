# MongoDB Pods Gateway (aqsh-mongodb)

`pods/list` and `pods/delete` give visibility into and control over the
**Kubernetes Pods backing this namespace's MongoDB StatefulSet** — a plain
`kubectl get pods`/`kubectl delete pod`, scoped to exactly that StatefulSet's
own members. Neither task speaks the MongoDB wire protocol: both work even
when the whole replica set is down, and both work unchanged for Bitnami and
official-image deployments, since neither ever inspects the image or reads a
credential.

**This is a different capability from `ops/kill`.** `ops/kill` interrupts a
running mongod *operation* by opid (see [ops.md](ops.md)); `pods/delete`
deletes the *Pod* itself — the StatefulSet controller recreates it
afterward. The two are unrelated and can be used independently.

The StatefulSet name is **not a task input** — it resolves via internal
config → live-cluster auto-detect (exactly one StatefulSet in the namespace)
→ hardcoded fallback, the same resolver and same fallback behavior `ops/*`
already uses (see CLAUDE.md "Configuration Layers").

## Table of Contents

1. [Architecture & Flow](#architecture--flow)
2. [API Reference](#api-reference)
3. [Usage Scenarios](#usage-scenarios)
4. [Deployment Settings (Internal Config)](#deployment-settings-internal-config)
5. [RBAC Requirements](#rbac-requirements)
6. [Related Pod-Deletion Paths](#related-pod-deletion-paths)

---

## Architecture & Flow

```
Operator / test-client (cluster-b)
     │  POST /tasks/pods%2Fdelete   {namespace, target_pod, dry_run, confirm}
     ▼
aqsh (mongo-core, cluster-a) → mongodb/pods/delete.sh
     │ 1. gate: dry_run/confirm triad (same as ops/kill, sts/orphan-delete),
     │      plus pod_uid required whenever dry_run=false
     │ 2. resolve sts_name (3-tier, no task input)
     │ 3. fetch target_pod directly (single kubectl get -o json) — not a
     │      derived membership list, so an already-deleted target_pod is
     │      never mistaken for "not a member" (see below)
     │ 4. target_pod not found? → POD_ALREADY_DELETED, completed
     │      (idempotent short-circuit; skips the gate entirely)
     │ 5. target_pod's ownerReferences don't name this StatefulSet?
     │      → POD_NOT_MEMBER, failed
     │ 6. dry_run? → DRY_RUN_READY preview (would graceful/force?, pod_uid)
     │      and stop
     │ 7. confirmed: pod_uid mismatches the live Pod's UID? → POD_REPLACED,
     │      failed (the StatefulSet already recreated a same-name
     │      replacement since the dry-run that produced this pod_uid)
     │ 8. kubectl delete pod — graceful if the pod is Ready, else
     │      --grace-period=0 --force (same rationale as recovery_wipe_pod:
     │      a not-Ready pod is usually already stuck and the StatefulSet's
     │      OrderedReady controller will not otherwise progress)
     ▼
result JSON → task .result.data (does NOT wait for the replacement Pod)
```

`pods/list` lists every member via `_k8s_sts_owned_pod_names` (steps 2–3 of
its own flow) and formats each one's live status (phase, ready, restarts,
node, IP, age) — a different membership path from `pods/delete`, which
checks one specific Pod's own ownerReferences (step 5 above) rather than a
separately-fetched list, so a target that's already gone doesn't have to
survive being found in that list first.

Debug visibility: the resolved StatefulSet name, the fetched Pod's UID, the
not-a-member check outcome, and the graceful-vs-forced decision (with the
`Ready` condition it was based on) are logged at DEBUG level — set
`LOG_LEVEL=DEBUG` on the call (or the aqsh container) to see them. The
delete itself is always logged at INFO immediately before it's issued.

---

## API Reference

Base URL (sandbox): `http://aqsh-mongodb.kind-a.test:30080`. Slash-named
tasks are URL-encoded: `POST /tasks/pods%2Flist`, `POST /tasks/pods%2Fdelete`.

### `pods/list` — read-only report

| Input | Required | Default | Meaning |
|---|---|---|---|
| `namespace` | yes | — | Namespace of the MongoDB StatefulSet |

Result (`.result.data`):

```json
{
  "namespace": "mongo-1",
  "instance": "mongodb",
  "count": 3,
  "pods": [
    {
      "name": "mongodb-0",
      "ordinal": 0,
      "phase": "Running",
      "ready": "1/1",
      "restarts": 0,
      "node": "cluster-a-worker",
      "podIP": "10.244.1.7",
      "startTime": "2026-07-20T03:14:00Z",
      "ageSeconds": 345600
    }
  ]
}
```

`pods` is sorted by `ordinal`. A member whose live Pod object can't be found
(mid-recreation, an instant-wide race) is silently omitted rather than
erroring — `count` reflects what was actually readable at that moment.

### `pods/delete` — gated mutation (dry_run → confirm)

| Input | Required | Default | Meaning |
|---|---|---|---|
| `namespace` | yes | — | Namespace of the MongoDB StatefulSet |
| `target_pod` | yes | — | Pod to delete; must be an exact member of the auto-detected StatefulSet |
| `dry_run` | no | `"true"` | Resolve and validate only; nothing is changed. Must be exactly `"true"` or `"false"` — schema- and script-enforced, since this is a safety control, not a generic flag: anything else (e.g. a `"flase"` typo) fails closed with `INVALID_INPUT` instead of being silently treated as `false` |
| `confirm` | no | `"false"` | Must be `"true"` when `dry_run` is `"false"` |
| `pod_uid` | no (required when `dry_run` is `"false"`) | `""` | The target Pod's `.metadata.uid`, as returned in the preceding dry-run's response. Compared against the live Pod's current UID immediately before deleting — a mismatch means the StatefulSet already recreated a same-name replacement since the dry-run, and the delete is rejected (`POD_REPLACED`) rather than silently deleting the replacement |

Gate rules (identical to `ops/kill`, `sts/orphan-delete`, plus the
`pod_uid` requirement): `dry_run=true` (default) previews; `dry_run=true` +
`confirm=true` is rejected; `dry_run=false` without `confirm=true` or
without `pod_uid` is rejected. Whether the delete ends up graceful or
forced is decided internally from the pod's own `Ready` condition — it is
never a caller-facing field.

Success result:

```json
{
  "status": "ok",
  "reason_code": "POD_DELETED",
  "summary": "Pod mongodb-1 delete issued (force=false); the StatefulSet will recreate it.",
  "namespace": "mongo-1",
  "instance": "mongodb",
  "target_pod": "mongodb-1",
  "deleted": true,
  "force": false
}
```

### Result codes

| `reason_code` | Task status | Trigger |
|---|---|---|
| `POD_DELETED` | completed | Delete issued; the StatefulSet will recreate the Pod |
| `POD_ALREADY_DELETED` | completed | `target_pod` was already gone — not an error |
| `DRY_RUN_READY` | completed | Validated; preview only, nothing changed. Response includes `pod_uid` for the follow-up confirm call |
| `INVALID_INPUT` | failed | Gate violation: `dry_run` is not exactly `"true"`/`"false"`, a `dry_run`/`confirm` conflict, or missing `confirm`/`pod_uid` when `dry_run=false` |
| `POD_NOT_MEMBER` | failed | `target_pod` is not an owned member of the resolved StatefulSet |
| `POD_REPLACED` | failed | `pod_uid` doesn't match the live Pod's current UID — the StatefulSet already recreated a same-name replacement since the dry-run; re-run `pods/delete` with `dry_run=true` to get the current `pod_uid` |
| `PODS_LIST_FAILED` | failed | `pods/list` could not list/read pods for the resolved StatefulSet |
| `POD_STATUS_UNKNOWN` | failed | Could not confirm `target_pod`'s existence/readiness (e.g. a transient API error) — distinct from a confirmed NotFound, which is `POD_ALREADY_DELETED` |
| `DELETE_FAILED` | failed | The Kubernetes API rejected the delete itself |

---

## Usage Scenarios

### 1. See the current state of every member pod

```json
POST /tasks/pods%2Flist
{"namespace": "mongo-1"}
```

### 2. Recycle a stuck member

```json
POST /tasks/pods%2Fdelete
{"namespace": "mongo-1", "target_pod": "mongodb-1"}
```

Returns `DRY_RUN_READY` with `.result.data.pod_uid` (e.g. `"a1b2c3d4-..."`).
Then execute, carrying that `pod_uid` forward:

```json
POST /tasks/pods%2Fdelete
{"namespace": "mongo-1", "target_pod": "mongodb-1", "dry_run": "false", "confirm": "true", "pod_uid": "a1b2c3d4-..."}
```

If the StatefulSet already recreated `mongodb-1` under a new UID by the
time this call runs (e.g. a slow operator, or a retried call issued long
after the dry-run), the delete is rejected with `POD_REPLACED` instead of
deleting the replacement — re-run the dry-run to get the current `pod_uid`.

Follow up with `pods/list` to confirm the replacement came back Ready —
`pods/delete` does not wait for it.

### 3. Attempted delete of a pod outside this StatefulSet

```json
{
  "status": "ERROR",
  "reason_code": "POD_NOT_MEMBER",
  "summary": "'other-app-0' is not a member pod of StatefulSet mongodb in mongo-1"
}
```

Membership is checked even though the underlying RBAC grant (`delete` on
`pods`, unscoped by name) would technically allow it — this is a
task-level safety boundary, not a Kubernetes-level one.

---

## Deployment Settings (Internal Config)

No new keys. `pods/*` reuses the existing MongoDB StatefulSet-name
resolution default from `/etc/aqsh/config/mongodb.env` (optional —
auto-detect covers a conventional single-StatefulSet namespace with zero
config): `MONGO_STS_NAME_DEFAULT`.

---

## RBAC Requirements

No additions. `pods/*` runs entirely within what the existing
`aqsh-mongo-manager` ClusterRole already grants (see
`tests/chart/templates/mongodb-rbac.yaml`):

- `pods` get/list/delete — reading status and issuing the delete
- `statefulsets` get/list — StatefulSet auto-detection and ownership lookup

---

## Related Pod-Deletion Paths

Other MongoDB tasks in this repo also delete a Pod, for unrelated internal
reasons — none of them are the same capability as `pods/delete`:

- **`recovery/wipe`/`recovery/recover`** force-delete a specific *not-Ready*
  target pod as one step of a larger data-recovery pipeline (see
  [recovery.md](recovery.md)) — driven by recovery state, not a standalone
  caller decision.
- **`restart`** relies on an `OnDelete` update strategy where "an operator
  or human is expected to delete pods" to roll out a change (see
  [restart.md](restart.md)) — a different orchestration model entirely from
  `pods/delete`'s direct, immediate delete.
- **`sts/orphan-delete`** deletes the *StatefulSet*, explicitly leaving Pods
  running (see [sts-orphan-delete.md](sts-orphan-delete.md)) — the opposite
  operation.

`pods/delete` is the only one of these meant to be called directly, for its
own sake, by an operator who just wants a specific Pod recycled.
