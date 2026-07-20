# MongoDB StatefulSet Orphan-Delete (aqsh-mongodb)

## Table of Contents

- [What This Is](#what-this-is)
- [Architecture & Flow](#architecture--flow)
- [API Reference](#api-reference)
- [Usage Scenario: Enlarging a PVC](#usage-scenario-enlarging-a-pvc)
- [Deployment Settings (Internal Config)](#deployment-settings-internal-config)
- [RBAC Requirements](#rbac-requirements)
- [Test Coverage Notes](#test-coverage-notes)

## What This Is

`sts/orphan-delete` runs `kubectl delete statefulset <name> --cascade=orphan`
against the target StatefulSet. This is a Kubernetes-native deletion mode,
not a garbage-collection or ownerReference concept: it removes only the
StatefulSet controller object. The Pods and PersistentVolumeClaims it was
managing keep running, untouched and now ownerless ("orphaned").

This task exists for **step 1 of the standard PVC-enlarge workaround**, used
when a StatefulSet's `volumeClaimTemplates` are bound to PVCs that need more
capacity but the cluster's StorageClass doesn't support (or the operator
doesn't want to rely on) in-place PVC resize on a live StatefulSet:

1. **`sts/orphan-delete` (this task)** — detach the StatefulSet, leaving
   Pods and PVCs running.
2. Patch each PVC's `spec.resources.requests.storage` to the new size
   (requires `allowVolumeExpansion: true` on the StorageClass) — manual,
   outside aqsh.
3. Recreate the StatefulSet with the enlarged `volumeClaimTemplates` — it
   adopts the existing PVCs by naming convention instead of provisioning
   new ones — manual, outside aqsh.
4. The rolling update restarts pods against the resized volumes — manual,
   outside aqsh.

Only step 1 is implemented here. Steps 2–4 remain manual for now; see
[Usage Scenario](#usage-scenario-enlarging-a-pvc) below for the full
workaround this task participates in.

## Architecture & Flow

```text
caller
  │ POST /tasks/sts%2Forphan-delete
  ▼
aqsh-tasks/scripts/mongodb/sts/orphan-delete.sh
  │
  ├─ resolve STS name (recovery_resolve_sts_name)
  │    internal config -> single-STS-in-namespace auto-detect -> "mongodb"
  │
  ├─ dry_run=true
  │    └─ k8s_get_sts_pods(sts)     — replicas + pod names (ownerReferences)
  │         → write preview JSON, exit (no cluster mutation)
  │
  └─ dry_run=false + confirm=true
       └─ k8s_delete_sts_cascade_orphan(sts)
            takes its own pre-delete snapshot (same k8s_get_sts_pods),
            kubectl delete statefulset <sts> --cascade=orphan
            → StatefulSet object gone; Pods + PVCs keep running
```

`k8s_get_sts_pods` / `k8s_delete_sts_cascade_orphan` live in
`aqsh-tasks/lib/k8s.sh` — generic, DB-agnostic Kubernetes helpers (no
MongoDB-specific logic), since `--cascade=orphan` is a Kubernetes concept,
not a database one. Only STS-name resolution
(`recovery_resolve_sts_name`, from `aqsh-tasks/lib/mongodb-recovery.sh`) is
MongoDB-specific, and it's the same resolver `reconfig/apply` already
reuses.

## API Reference

### `sts/orphan-delete` — gated mutation (dry_run → confirm)

| Field | Required | Default | Notes |
|---|---|---|---|
| `namespace` | yes | — | Target namespace |
| `dry_run` | no | `"true"` | Preview only; no cluster mutation |
| `confirm` | no | `"false"` | Must be `"true"` when `dry_run="false"` |
| `log_level` | no | — | `DEBUG`/`INFO`/`WARN`/`ERROR` |

`sts_name` is **not** a task input — see CLAUDE.md "Configuration Layers" /
"Auto-detect tier". This task detaches a StatefulSet from control of its
own Pods, so the API surface is kept to just `namespace` plus the
dry_run/confirm gate, matching the `recovery/*`/`reconfig/*`/`fcv/*`/`pbm/*`
convention.

Gate rules (`INVALID_INPUT` on violation):
- `dry_run=true` + `confirm=true` together — rejected (ambiguous intent)
- `dry_run=false` without `confirm=true` — rejected (no accidental deletes)

**Dry-run response** (`dry_run=true`, default):

```json
{
  "dry_run": true,
  "namespace": "mongo-1",
  "sts": "mongodb",
  "replicas": 3,
  "would_orphan_pods": ["mongodb-0", "mongodb-1", "mongodb-2"],
  "note": "pods and PVCs stay running and untouched; only the StatefulSet controller object is removed. Resizing PVCs and recreating the StatefulSet are separate, manual steps not performed by this task."
}
```

**Confirmed response** (`dry_run=false`, `confirm=true`):

```json
{
  "sts": "mongodb",
  "namespace": "mongo-1",
  "replicas": 3,
  "orphaned_pods": ["mongodb-0", "mongodb-1", "mongodb-2"]
}
```

## Usage Scenario: Enlarging a PVC

```bash
# 1. Preview — confirm which STS/pods would be affected
curl -s -X POST "$AQSH_URL/tasks/sts%2Forphan-delete" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"namespace": "mongo-1"}'
# → poll /executions/<id>, inspect would_orphan_pods

# 2. Confirmed delete — detach the StatefulSet
curl -s -X POST "$AQSH_URL/tasks/sts%2Forphan-delete" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"namespace": "mongo-1", "dry_run": "false", "confirm": "true"}'
# → StatefulSet "mongodb" is gone; mongodb-0/1/2 pods keep Running

# 3. (manual, outside aqsh) patch each PVC to the new size
kubectl --context kind-cluster-a -n mongo-1 patch pvc data-mongodb-0 \
  -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
# ... repeat per PVC

# 4. (manual, outside aqsh) recreate the StatefulSet with the enlarged
#    volumeClaimTemplates — it adopts the existing PVCs (same names), pods
#    roll onto the resized volumes.
```

## Deployment Settings (Internal Config)

No new keys. Reuses the existing MongoDB resolution defaults from
`/etc/aqsh/config/mongodb.env` (optional — auto-detect covers a
conventional single-StatefulSet deployment with zero config):

| Key | Meaning | Touch it? |
|---|---|---|
| `MONGO_STS_NAME_DEFAULT` | StatefulSet name when detection shouldn't run | Not recommended — leave unset |

## RBAC Requirements

One addition to the existing `aqsh-mongo-manager` ClusterRole (see
`tests/chart/templates/mongodb-rbac.yaml`):

```yaml
- apiGroups: ["apps"]
  resources: ["statefulsets"]
  resourceNames: ["mongodb"]   # named get/patch/delete
  verbs: ["get", "patch", "delete"]
```

`delete` is new — every other `recovery/*`/`reconfig/*`/`fcv/*` task only
ever `get`/`patch`es the StatefulSet; `sts/orphan-delete` is the only task
that deletes it (as `--cascade=orphan`, so Pods/PVCs are unaffected). `get`
+ `list` on `pods` (already granted, used by `recovery_wipe_pod`) covers the
pre-delete pod-name preview.

## Test Coverage Notes

`tests/mongodb/sts_orphan_delete.bats` uses a dedicated throwaway namespace
with a single bare `mongo:7` StatefulSet — no replica-set init, no
credentials, since this task never speaks the MongoDB wire protocol or
reads a credential secret. No Bitnami-variant test file (unlike
`fcv.bats`/`fcv_bitnami.bats`) is needed: STS-name resolution here only
exercises the "exactly one StatefulSet in namespace" auto-detect path and
never branches on image/credential convention.
