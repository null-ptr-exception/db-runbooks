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
| Member-pod membership | `_k8s_sts_owned_pod_names` — **live** ownerReference check against currently-existing Pods | `mariadb_list_member_pods` — ordinal names (`<instance>-0..N-1`) generated from the resolved replica count; does **not** re-verify each name still exists as a live Pod |
| Result envelope | Flat (`write_task_result`/`fail_task`, matching `ops/*`) | Nested (`response_ok`/`mdbt_fail`, matching `restart`/`list-backups`/`delete-backup`) — top-level `reason` on both success and failure, domain fields under `.data` |
| RBAC | Already had `pods: get/list/delete` — no change | `pods` previously had only `get/list/watch`; **`delete` added** for this family (`tests/chart/templates/mariadb-rbac.yaml`) |

The membership-resolution difference has one behavioral consequence: because
MariaDB's member list is name-pattern-based rather than live-verified, the
`POD_ALREADY_DELETED` short-circuit is reliably reachable there (a
force-deleted, not-yet-recreated ordinal still passes membership, then fails
the live-existence check). On the MongoDB side the same short-circuit exists
defensively (e.g. a second, concurrent `pods/delete` call racing the first),
but ordinary sequential use will see `POD_NOT_MEMBER` instead during the
narrow recreation window, since a fully-gone Pod also drops out of the live
ownerReference list. Neither behavior is incorrect — both fail closed.

## Usage Scenario: recycle a replica in mariadb-1

```json
POST /tasks/pods%2Flist
{"namespace": "mariadb-1"}
```

```json
POST /tasks/pods%2Fdelete
{"namespace": "mariadb-1", "target_pod": "mariadb-2"}
```

Returns `DRY_RUN_READY` (`.result.data.reason`) with the plan under
`.result.data.data`. Then execute:

```json
POST /tasks/pods%2Fdelete
{"namespace": "mariadb-1", "target_pod": "mariadb-2", "dry_run": "false", "confirm": "true"}
```

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
