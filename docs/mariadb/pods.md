# Pods Gateway (pods/*) — aqsh-mariadb

`pods/list` and `pods/delete` give visibility into and control over the
**Kubernetes Pods backing this namespace's MariaDB instance** — a plain
`kubectl get pods`/`kubectl delete pod`, scoped to exactly that instance's
own members. Unlike `secrets/*`, this is **not the same script** the
MongoDB gateway serves — each side resolves its instance and membership
using its own DB-specific library (`mongodb-recovery.sh` vs. `mariadb.sh`)
— but the API shape, gating, and result-code contract are the same. The
full design, architecture diagram and usage scenarios live in
[docs/mongodb/pods.md](../mongodb/pods.md); this page covers what differs
on the MariaDB deployment.

## Table of Contents

- [What Differs on MariaDB](#what-differs-on-mariadb)
- [Usage Scenario: recycle a replica in mariadb-1](#usage-scenario-recycle-a-replica-in-mariadb-1)
- [Deployment Settings (Internal Config)](#deployment-settings-internal-config)
- [RBAC Requirements](#rbac-requirements)

## What Differs on MariaDB

| Aspect | MongoDB gateway | MariaDB gateway |
|---|---|---|
| Gateway host (sandbox) | `aqsh-mongodb.kind-a.test:30080` | `aqsh-mariadb.kind-a.test:30080` |
| Instance resolution | `recovery_resolve_sts_name` — internal config → exactly-one-StatefulSet auto-detect → hardcoded `mongodb` fallback | `mariadb_autodetect_target` — MariaDB CR first, same-named StatefulSet fallback for operator-less deployments; ambiguous/none fails closed (`DATABASE_CONFIGURATION_AMBIGUOUS` / `DATABASE_NOT_FOUND`), no hardcoded-name fallback |
| Member-pod membership (`pods/list`) | `_k8s_sts_owned_pod_names` — **live** ownerReference check against currently-existing Pods | `mariadb_list_member_pods` — ordinal names (`<instance>-0..N-1`) generated from the resolved replica count, intersected against `_k8s_sts_owned_pod_names` for the same-named StatefulSet — a Pod that merely carries the expected name but isn't actually owned by it (e.g. during a recreation race) is never a candidate |
| Result envelope | Flat (`write_task_result`/`fail_task`, matching `ops/*`) | Nested (`response_ok`/`mdbt_fail`, matching `restart`/`list-backups`/`delete-backup`) — top-level `reason` on both success and failure, domain fields under `.data` |
| RBAC | Already had `pods: get/list/delete` — no change | `pods` previously had only `get/list/watch`; **`delete` added** for this family (`tests/chart/templates/mariadb-rbac.yaml`) |

`pods/list` resolves membership the way the table above describes on each
side. `pods/delete` is different on both gateways: it fetches the target
Pod directly (`pods_fetch_json`, one `kubectl get pod <name> -o json`) and
checks *that object's own* `ownerReferences` against the resolved instance
(`pods_owned_by_sts`), rather than checking whether the name appears in a
separately-fetched member list. This matters because a fully-gone Pod drops
out of any live member list — checking the named Pod's own object instead
is what makes `POD_ALREADY_DELETED` reachable for a target that's already
gone, rather than that case always surfacing as `POD_NOT_MEMBER` first. The
RBAC grant on both sides is still a namespace-wide unscoped `delete` on
`pods`, so this per-Pod ownership check remains the only thing standing
between that grant and an arbitrary Pod in the namespace — same fail-closed
guarantee as before, just reachable in the already-gone case now too.

A confirmed `pods/delete` also requires `pod_uid` (from the preceding
dry-run) and rejects with `POD_REPLACED` if it no longer matches the live
Pod — closing the window where the StatefulSet recreates a same-name
replacement between a dry-run and its confirm call. See
[docs/mongodb/pods.md](../mongodb/pods.md#api-reference) for the full
contract; it's identical on MariaDB.

## Usage Scenario: recycle a replica in mariadb-1

```json
POST /tasks/pods%2Flist
{"namespace": "mariadb-1"}
```

```json
POST /tasks/pods%2Fdelete
{"namespace": "mariadb-1", "target_pod": "mariadb-2"}
```

Returns `DRY_RUN_READY` (`.result.data.reason`) with the plan, including
`pod_uid`, under `.result.data.data`. Then execute, carrying that `pod_uid`
forward:

```json
POST /tasks/pods%2Fdelete
{"namespace": "mariadb-1", "target_pod": "mariadb-2", "dry_run": "false", "confirm": "true", "pod_uid": "a1b2c3d4-..."}
```

If the instance already recreated `mariadb-2` under a new UID by the time
this call runs, the delete is rejected with `POD_REPLACED` instead of
deleting the replacement — re-run the dry-run to get the current `pod_uid`.

Follow up with `pods/list` to confirm the replacement came back Ready —
`pods/delete` does not wait for it. See [restart.md](restart.md) for the
alternative "restart every pod, operator-driven" path when the goal is a
full rolling restart rather than recycling one pod.

## Deployment Settings (Internal Config)

No new keys. `pods/*` uses the same instance-resolution path as
`list-backups`/`delete-backup` — no `*_DEFAULT` override exists or is
needed for the sandbox's single-instance-per-namespace convention.

## RBAC Requirements

`tests/chart/templates/mariadb-rbac.yaml` (role `aqsh-mariadb-manager`)
previously granted only `get/list/watch` on `pods`. This family added
`delete` to that same rule — the only RBAC change `pods/*` required on
either gateway (MongoDB's `aqsh-mongo-manager` already had it). As on the
MongoDB side, membership is re-checked in-script before any delete
(`POD_NOT_MEMBER`), so the broadened grant does not by itself let a caller
delete a pod outside the resolved instance.
