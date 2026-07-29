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
     │ 1. gate: dry_run/confirm triad (same as ops/kill, sts/orphan-delete)
     │ 2. resolve sts_name (3-tier, no task input)
     │ 3. list member pods: _k8s_sts_owned_pod_names — ownerReferences,
     │      never a label/name guess (a Pod sharing labels but owned by a
     │      different workload is never a candidate)
     │ 4. target_pod not a member? → POD_NOT_MEMBER, failed
     │ 5. target_pod already gone? → POD_ALREADY_DELETED, completed
     │      (idempotent short-circuit; skips the gate entirely)
     │ 6. dry_run? → DRY_RUN_READY preview (would graceful/force?) and stop
     │ 7. kubectl delete pod — graceful if the pod is Ready, else
     │      --grace-period=0 --force (same rationale as recovery_wipe_pod:
     │      a not-Ready pod is usually already stuck and the StatefulSet's
     │      OrderedReady controller will not otherwise progress)
     ▼
result JSON → task .result.data (does NOT wait for the replacement Pod)
```

`pods/list` is steps 2–3 only, formatting every member's live status
(phase, ready, restarts, node, IP, age) instead of deleting one.

Debug visibility: the resolved StatefulSet name, the full member-pod list,
the not-a-member check outcome, and the graceful-vs-forced decision (with
the `Ready` condition it was based on) are logged at DEBUG level — set
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
| `dry_run` | no | `"true"` | Resolve and validate only; nothing is changed |
| `confirm` | no | `"false"` | Must be `"true"` when `dry_run` is `"false"` |

Gate rules (identical to `ops/kill`, `sts/orphan-delete`): `dry_run=true`
(default) previews; `dry_run=true` + `confirm=true` is rejected;
`dry_run=false` without `confirm=true` is rejected. Whether the delete ends
up graceful or forced is decided internally from the pod's own `Ready`
condition — it is never a caller-facing field.

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
| `DRY_RUN_READY` | completed | Validated; preview only, nothing changed |
| `INVALID_INPUT` | failed | Gate violation (`dry_run`/`confirm` conflict, or missing `confirm`) |
| `POD_NOT_MEMBER` | failed | `target_pod` is not an owned member of the resolved StatefulSet |
| `PODS_LIST_FAILED` | failed | Could not list/read pods for the resolved StatefulSet |
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

Returns `DRY_RUN_READY`. Then execute:

```json
POST /tasks/pods%2Fdelete
{"namespace": "mongo-1", "target_pod": "mongodb-1", "dry_run": "false", "confirm": "true"}
```

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
