# MariaDB 0.24 Cross-Cluster Replication Runbook

This runbook attaches an existing standby in cluster B to an existing primary
in cluster A. PR #99 targets mariadb-operator 0.24 only.

The operator still owns each cluster's MariaDB CR, StatefulSet, and Services.
It does not participate in the cross-cluster link: 0.24 has no
`ExternalMariaDB`, `spec.multiCluster`, `PhysicalBackup`, or `spec.suspend` API.
The standby must be a one-Pod CR with operator local replication disabled.
Version 0.0.24 stops and resets all SQL channels whenever it reconciles its own
replica topology, so a multi-replica standby cannot safely share that topology
with the runbook-owned cross-cluster channel.

## Architecture

```text
cluster A                                          cluster B
MariaDB primary                                   MariaDB standby (one Pod)
  operator 0.24 owns local instance                 operator 0.24 owns the instance
  physical-backup task streams .xb                  db-runbooks owns cross-cluster SQL
           |                                                     |
           +------ shared S3/MinIO exact backup -----------------+

B standby Pod -- CHANGE MASTER / START SLAVE --> A mesh service
```

The peer hostname is derived from the namespace:

```text
<namespace>-rw.<namespace>.svc.cluster.local:<configured port>
```

Both clusters use the same platform-managed root credential and object-storage
policy. Callers cannot provide an arbitrary replication host, bucket, prefix,
credential reference, or restore image.

The standby deployment must persist a `server_id` distinct from every server
in cluster A, for example through `spec.myCnf`. A runtime `SET GLOBAL server_id`
is insufficient because it is lost whenever the Pod is recreated.

## Task API

| Task | Purpose |
|---|---|
| `replication/attach` | Dry-run assessment, then resume the link or rebuild B and attach it. |
| `replication/status` | Read `SHOW ALL SLAVES STATUS` on B and optionally assess the peer. |
| `replication/detach` | Run `STOP SLAVE; RESET SLAVE ALL` on B. |
| `restore-in-place` | Restore one exact physical backup into an existing v24 instance. |
| `restore` | Separate API: create a new MariaDB instance from backup; it never overwrites an existing instance. |

Public inputs:

```text
replication/attach  namespace, dry_run, confirm, expected_action
replication/status  namespace, include_peer
replication/detach  namespace, dry_run, confirm
restore-in-place    namespace, backup, dry_run, confirm
```

`restore-in-place` is intentionally distinct from `restore`. The former replaces
the data of a named, existing standby while preserving CR/PVC identity; the
latter follows new-instance restore semantics.

## Attach flow

The default call is read-only:

```bash
curl -sX POST "$AQSH_B_URL/tasks/replication%2Fattach" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"namespace":"mariadb-1"}'
```

The assessment checks:

| Check | Result when it fails |
|---|---|
| A and B have distinct, persistent `server_id` values | `SERVER_ID_CONFLICT`; fix the standby deployment before attaching. |
| B has a saved `gtid_slave_pos` | `NO_REPLICATION_HISTORY`; rebuild. |
| B is not ahead of A | `GTID_DIVERGED`; rebuild. |
| A still retains B's starting binlog | `PRIMARY_BINLOG_PURGED`; rebuild. |
| A is reachable and has binary logging | Error; never interpreted as permission to rebuild. |

Execution is the same endpoint with `dry_run=false` and `confirm=true`.
`expected_action` may pin the dry-run result so an expected resume cannot turn
into a destructive rebuild between calls.

When the action is `attach`, B runs:

```sql
CHANGE MASTER 'aqsh-cross-cluster' TO
  MASTER_HOST='<derived peer>',
  MASTER_PORT=<configured port>,
  MASTER_USER='root',
  MASTER_PASSWORD=<platform credential>,
  MASTER_USE_GTID=slave_pos;
START SLAVE 'aqsh-cross-cluster';
```

The password uses a quoted SQL string with quote doubling and a session-local
`NO_BACKSLASH_ESCAPES` mode; it is never included in logs or task results. Attach succeeds only after both replica threads are running.

## Rebuild and in-place restore

If the assessment says B cannot resume:

1. B asks A's AQSH to run `physical-backup` and captures its exact `backupName`.
2. B resolves and verifies exactly one matching `.xb`, `.xb.gz`, or `.xb.bz2`
   object in shared S3/MinIO. This happens before any Pod is replaced.
3. B re-checks the external-connection guard.
4. B temporarily changes the StatefulSet update strategy to `OnDelete` and
   appends one-shot restore init containers to `MariaDB.spec.initContainers`.
   Existing user init containers are preserved.
5. B deletes all old member Pods in one request. Each replacement Pod downloads
   the exact object and, before `mysqld` may start, clears its own datadir, runs
   `mbstream -x`, `mariabackup --prepare`, restores ownership, and writes a
   backup-specific completion marker.
6. B verifies every member marker, removes only the temporary restore hook, and
   deletes the Pods again. They start on the restored datadir with the original
   Pod template; the original StatefulSet update strategy is then restored.
7. Attach configures the peer with `MASTER_USE_GTID=current_pos` and waits for
   both SQL replication threads.

The MariaDB CR and PVC objects are never deleted or recreated. Their UIDs must
remain unchanged across rebuild.

`POST /tasks/restore-in-place` runs steps 2–6 for an explicitly named backup and
does not configure a cross-cluster source. Attach and the public restore task use
the same restore library, so fencing and failure behavior cannot drift.

### Failure behavior

- Before Pod replacement begins, failures restore the original template and
  update strategy where possible.
- After overwrite begins, failures leave `OnDelete` and the idempotent restore
  hook in place. A replacement Pod retries the same exact backup; it never starts
  `mysqld` on a partially prepared datadir.
- A missing, duplicated, or unreachable backup is detected before Pod deletion.
- An unrelated SQL replication source is never overwritten or detached.

## Connection guard

Attach and restore-in-place count external sessions on B. The default allowance
is zero. MariaDB internal threads, replication workers, and configured platform
accounts are excluded. The count is read again immediately before the restore
hook is armed and member Pods are replaced.

An unreadable process list is an error, not an implicit zero.

## Status and detach

`replication/status` reads the v24 SQL connection directly and reports:

- whether a source is configured;
- IO/SQL thread state;
- source host and port;
- GTID mode and lag;
- a replication error, if present;
- operator-reported local readiness and local replica state.

It does not inspect `spec.multiCluster` because that field does not exist on
0.24.

Detach verifies that the configured source is the derived peer, then runs:

```sql
STOP SLAVE 'aqsh-cross-cluster';
RESET SLAVE 'aqsh-cross-cluster' ALL;
```

It leaves the CR, StatefulSet, PVC, and data in place. Repeating detach after
the link is gone is a successful no-op.

## Deployment requirements

- Both clusters run mariadb-operator 0.24 (`mariadb.*.mmontes.io`). Tasks fail
  closed when operator discovery is unknown or a different generation is found.
- Standby B has exactly one Pod and `.spec.replication.enabled` is false or
  absent. Operator-managed local replication is incompatible with this v24 SQL
  channel because its reconciler stops and resets all channels.
- mariadb-operator 0.0.24 has no `serverIdStartIndex` field. Standby B persists
  a server ID disjoint from A in `.spec.myCnf` (for example,
  `[mariadb]\nserver_id=100`).
- The mesh publishes the derived peer Service and A accepts the shared
  credential from B.
- Both workloads resolve the same S3 endpoint, bucket, prefix, and credentials.
- AQSH B has an A AQSH URL, and A's TokenReview policy trusts B's AQSH service
  account. B mints a TokenRequest bearer for the peer call (falling back to its
  projected token); callers never submit a peer credential.

Relevant deployment configuration:

| Variable | Default | Purpose |
|---|---|---|
| `REPL_PEER_SERVICE_SUFFIX_DEFAULT` | `-rw` | Derived peer Service suffix. |
| `REPL_PEER_PORT_DEFAULT` | `3306` | Peer MariaDB port. |
| `REPL_MAX_EXTERNAL_CONNECTIONS_DEFAULT` | `0` | Maximum allowed external sessions. |
| `REPL_IGNORED_ACCOUNTS_DEFAULT` | platform account list | Sessions excluded from the guard. |
| `REPL_PEER_CONNECT_TIMEOUT_DEFAULT` | `10` | Peer SQL connection timeout in seconds. |
| `REPL_PEER_AQSH_URL_DEFAULT` | unset | Primary AQSH URL used to request a backup. |
| `REPL_PEER_TOKEN_FILE_DEFAULT` | projected service-account token | Fallback token file; attach prefers a minted TokenRequest bearer for peer AQSH auth. |
| `REPL_PEER_TOKEN_SA_DEFAULT` | unset (JWT claim fallback) | ServiceAccount name used to mint the peer TokenRequest bearer. |
| `REPL_PEER_TASK_TIMEOUT_DEFAULT` | `900` | Maximum peer backup task wait. |
| `REPL_RESTORE_WAIT_TIMEOUT_DEFAULT` | `900` | Maximum local restore reconciliation and final link wait. |

## Testing

Unit tests cover GTID decisions, SQL status parsing, password-safe `CHANGE
MASTER`, exact-object selection, one-shot init hook construction, PVC selection,
OnDelete fencing, and two-phase Pod replacement:

```bash
bats tests/unit/mariadb/replication-link.bats \
     tests/unit/mariadb/replication-rebuild.bats \
     tests/unit/aqsh/mariadb_public_inputs.bats
```

The v24 Kind suite is `tests/mariadb-legacy/replication_link.bats`. It installs
operator 0.24 in both clusters and verifies:

```text
peer connectivity
  -> dry-run says rebuild
  -> fresh hand-rolled physical backup on A
  -> exact in-place restore on B
  -> unchanged CR/PVC UIDs
  -> running SQL replication with the derived source
  -> idempotent attach
  -> SQL-only detach
  -> idempotent detach
```

The sandbox uses the Istio TCP mesh stand-in in
`tests/chart/templates/replication-mesh.yaml`; production uses Cilium cluster
mesh. Kind/operator E2E is intentionally separate from the local pre-review
suite because it provisions clusters and takes a real physical backup.

## Local E2E isolation

Use the [low-resource validation and AI handoff](local-validation.md) for the
default local gate. The full E2E below is opt-in; focused unit results do not
constitute runtime replication evidence.

Run the replication file independently from the repository root:

```bash
scripts/local-e2e/run.sh tests/mariadb-legacy/replication_link.bats
```

The wrapper copies the current worktree into a fresh privileged Docker-in-Docker
container, with no host Docker socket or kubeconfig mount and no published host
ports. The nested daemon owns its registry, images, two Kind clusters, operator
CRDs, namespaces, and MinIO bucket. The container is removed on exit; logs are
retained in the printed private temporary directory. Tool installation also
stays inside that container. Default limits are 4 CPUs and 4 GiB; deployments
with sufficient local resources can set `LOCAL_E2E_CPUS` and `LOCAL_E2E_MEMORY`.
An in-container watchdog stops the daemon after 3600 seconds by default
(`LOCAL_E2E_MAX_SECONDS`), even if the host runner dies. The next invocation
removes only stopped containers carrying this runner's ownership label.
The runner uses HTTP/1.1 for Go clients inside the container because chart
repository downloads can fail over HTTP/2 in nested local networking.
Helmfile setup gets a 900-second readiness budget for cold CNI startup and at
most three attempts for specific transport errors. Bats and AQSH operations
are not retried, and the original readiness checks remain required.

The file contains one lifecycle scenario, including real row replication, standby
Pod restart, persistent server ID, and the public exact-backup in-place restore. Assessment, rebuild, status, repeated
attach, and repeated detach are consecutive steps inside that scenario, so
Bats test filtering or parallel jobs cannot split their state dependencies.
Run another E2E file with a separate wrapper invocation; it receives a fresh
fixture. A successful second invocation demonstrates independence from the
first invocation's data and cleanup.

Direct `bats tests/mariadb-legacy/` still uses the shared `cluster-a`/`cluster-b`
fixtures. Do not run that command concurrently with MariaDB, MongoDB, AQSH, or
infra suites on the same Docker daemon. Legacy setup removes current-generation
operator CRDs; suite teardown removes shared namespaces and MinIO. Separate
namespaces alone cannot isolate those cluster-wide operations. The wrapper
isolates those resources, but concurrent runs still share host CPU, memory,
network bandwidth, and disk: run them sequentially on a resource-limited laptop.
