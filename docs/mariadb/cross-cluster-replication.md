# MariaDB Cross-Cluster Replication Runbook

Attach an already-deployed standby database in one cluster to the primary in
another, and operate the link afterwards.

This is not provisioning. Both databases exist: cluster-a runs the primary,
cluster-b runs a standby that was deployed alongside it. These tasks connect
them, report on the connection, and remove it.

## Task API

| Task | Runs on | Behavior |
|------|---------|----------|
| `replication/attach` | Standby cluster | Assess whether the standby can resume replication from the primary; wire it up when it can. |
| `replication/rebuild` | Standby cluster | Re-seed a standby that cannot resume, then attach it. **Destroys the standby's data.** |
| `replication/status` | Either cluster | Read-only link state, lag, and current assessment. Safe to poll. |
| `replication/detach` | Standby cluster | Remove the link. Leaves the database and its data alone. |

Only the standby cluster is ever modified. A MariaDB replica initiates its own
replication, and the `multiCluster` topology naming the primary lives entirely
in the standby's own CRs — so no task needs the primary cluster's kubeconfig,
and none of them reach into it. (`blue-green/create` works the same way: it
never patches Blue either.)

`replication/rebuild` is the one task that talks to the primary's cluster at
all, and it does so over AQSH's own HTTP API, not kubectl: only the primary's
cluster can back its own database up.

### Public inputs

```
replication/attach    namespace, dry_run, confirm, wait_timeout, expected_action
replication/rebuild   namespace, dry_run, confirm, wait_timeout, peer_token, peer_aqsh_url
replication/status    namespace, include_peer
replication/detach    namespace, dry_run, confirm
```

The peer address, port, connection-guard policy, member naming, and credential
references are all platform-resolved. They are not task inputs — see
"Deployment configuration".

## How the peer address is derived

Infra publishes an ExternalName Service in every namespace of every cluster,
through the Cilium cluster mesh:

```
<namespace>-rw  →  <mdb>-primary.<namespace>.svc.cluster.local   (the primary)
<namespace>-ro  →  the read endpoint
```

So the standby reaches the primary at:

```
<namespace>-rw.<namespace>.svc.cluster.local:3306
```

That is derived from the namespace alone. There is no per-site connection
catalog to configure or keep in sync, and a caller cannot point a task at an
arbitrary host.

An ExternalName Service is a DNS alias and carries no port of its own; the port
belongs to the Service it aliases, which is why it is deploy-time config here
rather than something read off the Service.

## Attach is two-phase

Both phases are the standard `dry_run` / `confirm` gate every mutating task in
this repo already has. There is nothing extra to learn.

**Phase 1 — assess** (the default; no flags needed):

```bash
kexec "curl -s -X POST '${AQSH_B_URL}/tasks/replication%2Fattach' \
  -H 'Authorization: Bearer ${TOKEN}' \
  -H 'Content-Type: application/json' \
  -d '{\"namespace\": \"mariadb-1\"}'"
```

Nothing is modified. The result reports one of:

```json
{ "action": "attach",  "actionReason": "LINK_RESUMABLE" }
{ "action": "rebuild", "actionReason": "PRIMARY_BINLOG_PURGED" }
```

**Phase 2 — execute:**

```bash
kexec "curl -s -X POST '${AQSH_B_URL}/tasks/replication%2Fattach' \
  -H 'Authorization: Bearer ${TOKEN}' \
  -H 'Content-Type: application/json' \
  -d '{
    \"namespace\": \"mariadb-1\",
    \"dry_run\": \"false\",
    \"confirm\": \"true\",
    \"expected_action\": \"attach\"
  }'"
```

`expected_action` is optional. Passing the action the dry run reported makes the
task refuse to run if the assessment has changed in between — so a call you
believed was "just connect it" cannot turn into a destructive rebuild. Omit it
to follow whatever the live assessment says.

Attach only reports success once the replication threads are actually running.
A topology that reconciles into a broken replica is a failure, not a success
with a caveat.

## The connection guard

Before assessing anything, attach counts external connections on the standby
and refuses to run if any exist. The reason is the rebuild path: rebuilding
destroys the standby's data, and an open session means something is relying on
it right now.

Not counted as external: MariaDB's own internal threads, the replication
threads, and the platform accounts listed in `REPL_IGNORED_ACCOUNTS_DEFAULT`
(operator probes, monitoring, healthchecks).

A process list that cannot be read is an error, never an implicit "nobody is
connected".

## Attach or rebuild: the checks

A GTID (`domain-server-seq`, e.g. `1-101-500`) is MariaDB's record of how far
replication has progressed. Attaching means resuming from the standby's GTID
position, which is only possible if that position is still a valid point in the
primary's history.

| # | Check | Failure reason | What happened |
|---|-------|----------------|---------------|
| 0 | The two servers have different `server_id`s | `SERVER_ID_CONFLICT` | MariaDB refuses to replicate at all |
| 1 | Standby has a GTID position | `NO_REPLICATION_HISTORY` | Never replicated; there is no point to resume from |
| 2 | Standby is not ahead of the primary | `GTID_DIVERGED` | The two have separate histories |
| 3 | Standby's binlog holds no writes of its own | `STANDBY_HAS_LOCAL_WRITES` | Something wrote directly to the standby |
| 4 | Primary still retains the binlog from that point | `PRIMARY_BINLOG_PURGED` | The primary expired the segment the standby needs |

**Check 0 runs first and is not a GTID question.** With equal `server_id`s
MariaDB stops the replica's IO thread outright (errno 1593, *"master and slave
have equal MariaDB server ids"*), so no amount of GTID agreement helps. It also
makes GTID comparison meaningless: two clusters both defaulting to `server_id`
10 produce positions like `0-10-100` and `0-10-4`, which compare as "covered"
while sharing no history at all.

This is easy to hit, because the operator's default range is the same on every
cluster. See "Deployment prerequisites".

**Check 4 is the one that bites in practice.** A standby that was disconnected
for longer than the primary's `expire_logs_days` fails only this check —
everything else looks healthy. It surfaces at runtime as replication error 1236.

Two deliberate biases:

- **Coverage is compared per domain, not per domain+server.** The server
  component records whichever server last wrote that domain, so it changes every
  time `switch-primary` runs on the primary. Comparing on domain+server would
  read a perfectly healthy standby as diverged and send it to be rebuilt.
- **Any write the standby made itself means rebuild**, without asking whether
  the primary "already covers" it by sequence number. Within one domain both
  servers allocate sequence numbers from the same counter, so unrelated writes
  can compare as covered. Sequence coverage cannot tell them apart, and getting
  this wrong means silent data divergence, so the check errs toward rebuild.

Anything the assessment cannot read — unreachable peer, unreadable position,
primary with binary logging off — is an **error**, never a silent pass and never
an implicit rebuild.

## Rebuild

Run this when attach reports `REBUILD_REQUIRED`. It is a separate task rather
than a flag on attach: it destroys data, and it needs the primary's AQSH.

```bash
kexec "curl -s -X POST '${AQSH_B_URL}/tasks/replication%2Frebuild' \
  -H 'Authorization: Bearer ${TOKEN}' \
  -H 'Content-Type: application/json' \
  -d '{
    \"namespace\": \"mariadb-1\",
    \"peer_token\": \"${TOKEN}\",
    \"dry_run\": \"false\",
    \"confirm\": \"true\"
  }'"
```

It refuses to run on a standby that does not need it: the same assessment runs
first, and a resumable standby gets `REBUILD_NOT_REQUIRED` pointing at attach
instead. An assessment that cannot be *completed* does not block — a standby too
broken to answer is the normal reason to be here.

Steps:

1. Ask the primary's AQSH for a **fresh** physical backup, and wait for it.
2. Capture the standby's own CR spec.
3. Delete the standby: the MariaDB CR, then its data volumes.
4. Recreate it from the captured spec plus `bootstrapFrom.s3` and the
   `multiCluster` wiring.
5. Wait for Ready, then for replication to actually run.

**Why a fresh backup and not the newest object already in the bucket.** A stale
backup restores the standby to a position that may itself predate the primary's
retained binlog — failing check 4 all over again, after the data has already
been destroyed. One backup is cheaper than discovering that afterwards.

**Why the CR is recreated rather than restored in place.** Neither the
current-generation operator (`bootstrapFrom.s3`) nor the legacy hand-rolled
path can seed an existing instance; both only ever bootstrap a new one. The
existing spec is carried over wholesale, so resources, tolerations, TLS,
storage class, and replication settings survive — only `bootstrapFrom` and
`multiCluster` are added.

**Deleting the PVCs is not optional, and is fail-closed.** A StatefulSet's PVCs
outlive its CR. A surviving datadir makes the operator skip `bootstrapFrom`
entirely, and the standby returns carrying exactly the stale data the rebuild
existed to replace — a silent wrong-data success. The volumes are therefore
selected two ways (operator label, and the `<template>-<mdb>-<ordinal>` naming),
and the task re-checks afterwards and aborts if anything still matches, rather
than trusting that a `delete` which matched nothing did its job.

### There is no rollback

Step 3 is irreversible, and everything after it depends on the step-1 backup
being restorable. If step 4 fails, the standby is gone and has to be recreated
by whatever provisioned it originally. Failures *before* step 3 (backup
unavailable, connections open, peer unreachable) are safe and change nothing.

## Status

```bash
kexec "curl -s -X POST '${AQSH_B_URL}/tasks/replication%2Fstatus' \
  -H 'Authorization: Bearer ${TOKEN}' \
  -H 'Content-Type: application/json' \
  -d '{\"namespace\": \"mariadb-1\"}'"
```

Reports the local view (linked or not, threads running, seconds behind) and, when
the peer is reachable, the same assessment attach would make — so the link can be
checked without arming a mutating task. Pass `include_peer: "false"` to skip the
cross-cluster round trip in a tight monitoring loop.

An unreachable peer is reported as unreachable. Status never downgrades an
unknown into a healthy-looking answer.

## Detach

```bash
kexec "curl -s -X POST '${AQSH_B_URL}/tasks/replication%2Fdetach' \
  -H 'Authorization: Bearer ${TOKEN}' \
  -H 'Content-Type: application/json' \
  -d '{\"namespace\": \"mariadb-1\", \"dry_run\": \"false\", \"confirm\": \"true\"}'"
```

Removes the `multiCluster` block and the `ExternalMariaDB` references, in that
order, so the operator never sees members pointing at objects that are already
gone. Endpoint names are read from the CR rather than recomputed, so a detach
removes what is actually wired up even if the naming convention has changed.

Detaching on an already-detached database succeeds rather than erroring — a
re-run of a runbook should not fail because the end state is already true.

A detached standby holds a frozen copy of the data and drifts from that moment
on. Re-attaching later is subject to the same four checks as any other attach.

## Deployment configuration

Internal config in `aqsh-tasks/config/mariadb.env`, mounted at
`/etc/aqsh/config/mariadb.env`. None of these are task inputs: they are naming
convention and safety policy, fixed for a deployment.

| Variable | Default | Purpose |
|---|---|---|
| `REPL_PEER_SERVICE_SUFFIX_DEFAULT` | `-rw` | Mesh Service suffix for the primary |
| `REPL_PEER_PORT_DEFAULT` | `3306` | Port on the Service the alias points at |
| `REPL_MAX_EXTERNAL_CONNECTIONS_DEFAULT` | `0` | Connections tolerated before attach refuses |
| `REPL_IGNORED_ACCOUNTS_DEFAULT` | `root,mariadb.sys,healthcheck,monitor,exporter,repl` | Platform accounts that never count as external |
| `REPL_PEER_CONNECT_TIMEOUT_DEFAULT` | `10` | Seconds before a peer probe is treated as unreachable |
| `REPL_PEER_AQSH_URL_DEFAULT` | *(unset)* | Primary's AQSH, for `rebuild`. Set it and callers never pass an address. |
| `REPL_PEER_TASK_TIMEOUT_DEFAULT` | `900` | Seconds to wait on the peer's backup task |

The root credential reference is not configured here: it is read from the
standby's own `MariaDB.spec.rootPasswordSecretKeyRef`, which is the
authoritative source.

### Where these actually get set

`aqsh-tasks/config/mariadb.env` in this repo is a **reference template only** —
the Dockerfile copies `lib/`, `scripts/`, and `task*.yaml`, not `config/`. The
real file is supplied by the deployment through the aqsh ConfigMap
(`aqsh.config."mariadb.env"` in the chart).

The two peer settings are additionally **per-cluster by nature**: each AQSH's
peer is the *other* cluster, so a single shared file cannot express them. In
this repo's test suite they live in each aqsh release separately:

```yaml
# tests/mariadb/helmfile.yaml — cluster-a's aqsh
REPL_PEER_AQSH_URL_DEFAULT=http://aqsh-mariadb.kind-b.test:30080
# tests/mariadb/helmfile.yaml — cluster-b's aqsh
REPL_PEER_AQSH_URL_DEFAULT=http://aqsh-mariadb.kind-a.test:30080
```

## Deployment prerequisites

**`server_id` ranges must be disjoint across the two clusters.** The operator
derives each pod's `server_id` from `spec.replication.serverIdStartIndex`, whose
default is identical on every cluster — so two independently deployed instances
both get 10, 11, 12… and cannot replicate to each other.

The field is **immutable**. An already-deployed standby that collides with its
primary cannot be repaired in place; `attach` can only detect the collision and
refuse. `rebuild` is the one operation that can fix it, because it recreates the
CR — it sets `serverIdStartIndex` from `REPL_STANDBY_SERVER_ID_START_DEFAULT`
(default `100`).

Getting this right at deploy time is cheaper than discovering it later:

```yaml
# the standby's MariaDB spec
replication:
  serverIdStartIndex: 100   # primary uses the default range (10, 11, 12, ...)
```

## RBAC

Beyond what the other MariaDB tasks need, this surface requires:

| Resource | Verb | Why |
|---|---|---|
| `externalmariadbs` | `create`, `patch`, `delete` | The endpoint references attach applies and detach removes |
| `mariadbs` | `patch`, `delete`, `create` | The `multiCluster` block; rebuild recreates the CR |
| `persistentvolumeclaims` | `delete` | Rebuild must remove the standby's data volumes |

The PVC `delete` verb is the one that is easy to miss, and it fails at the worst
moment: after the CR is already gone.

## Reason codes

Adds to the shared MariaDB set:

| Reason | Meaning |
|---|---|
| `STANDBY_IN_USE` | External connections are open; the task refused to proceed. |
| `REBUILD_REQUIRED` | The standby cannot resume; run `replication/rebuild`. |
| `REBUILD_NOT_REQUIRED` | `rebuild` was called on a standby that can simply be attached. |
| `SERVER_ID_CONFLICT` | Standby and primary share a `server_id`; MariaDB will not replicate. |
| `PEER_CONFIGURATION_UNAVAILABLE` | No primary AQSH address is configured or supplied. |
| `PEER_OPERATION_FAILED` | The primary's AQSH could not produce a backup. Nothing was destroyed. |
| `REPLICATION_CONFIGURATION_UNAVAILABLE` | The database declares no replication configuration to rebuild into. |
| `UNEXPECTED_ACTION` | The assessment disagrees with `expected_action`. |
| `PEER_UNREACHABLE` | The primary could not be reached through the mesh Service. |
| `PRIMARY_BINLOG_UNAVAILABLE` | The primary has binary logging off or no readable binlog. |
| `LINK_NOT_ESTABLISHED` | Wiring applied, but replication did not start within `wait_timeout`. |

## Not covered

**Promote and switchover.** Nothing here promotes a standby. When they land,
check 3's conservative treatment of local writes needs revisiting: a
legitimately promoted standby that later rejoins would currently be sent to
rebuild.

**Cilium's own resolution path.** The e2e below runs the whole flow, but over an
Istio stand-in rather than a real cluster mesh (see below).

## Testing

**Unit** — `tests/unit/mariadb/replication-link.bats` pins the attach/rebuild
decision matrix in both directions. A wrong "attach" silently diverges two
databases; a wrong "rebuild" destroys a healthy standby. Both are covered,
including the two comparisons that are easy to get subtly wrong (a primary that
has switched its own primary, and a standby whose sequence numbers merely
*look* covered).

**End to end** — `tests/mariadb/replication_link.bats` runs the whole runbook
against the two kind clusters:

```
unlinked → assess (rebuild: NO_REPLICATION_HISTORY, because a fresh standby
                   has no history) → attach refuses → rebuild → linked
         → assess (attach) → detach → detach again (no-op)
```

It is slow: the rebuild takes a real physical backup on cluster-a, destroys the
standby, and re-seeds it. Budget ~15 minutes for that test.

### The mesh stand-in

The sandbox has no Cilium cluster mesh, so `tests/chart/templates/replication-mesh.yaml`
reproduces the same *contract* over what the sandbox does have:

```
standby pod
  → mariadb-1-rw.mariadb-1.svc.cluster.local   ExternalName, cluster-b
  → CNAME mariadb.kind-a.test                  CoreDNS → cluster-a node IP
  → :30091                                     shared gateway MySQL nodePort
  → Istio TCP passthrough                      infra/shared/templates/gateway.yaml
  → mariadb-primary.mariadb-1.svc.cluster.local:3306
```

The Service name is **derived from the namespace in the template too**, not
hardcoded — otherwise the e2e would prove nothing about the derivation the tasks
rely on.

Two things it deliberately does not reproduce: Cilium's own resolution path, and
the real deployment's port. The stand-in reaches the primary on 30091 rather
than 3306, which is exactly why the port is deploy-time config
(`REPL_PEER_PORT_DEFAULT`) and not a constant.

Plain TCP carries no host header, so the gateway routes by port alone — one
published database per cluster, which is all this suite needs.
