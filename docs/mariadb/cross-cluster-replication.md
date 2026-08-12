# MariaDB 0.24 Cross-Cluster Replication Runbook

This runbook attaches an existing standby in cluster B to an existing primary
in cluster A. PR #99 targets mariadb-operator 0.24 only.

The operator still owns each cluster's MariaDB CR, StatefulSet, Services, and
local primary/replica topology. It does not participate in the cross-cluster
link: 0.24 has no `ExternalMariaDB`, `spec.multiCluster`, `PhysicalBackup`, or
`spec.suspend` API.

## Architecture

```text
cluster A                                          cluster B
MariaDB primary                                   MariaDB standby
  operator 0.24 owns local instance                 operator 0.24 owns local instance
  physical-backup task streams .xb                  db-runbooks owns cross-cluster SQL
           |                                                     |
           +------ shared S3/MinIO exact backup -----------------+

B current primary -- CHANGE MASTER / START SLAVE --> A mesh service
```

The peer hostname is derived from the namespace:

```text
<namespace>-rw.<namespace>.svc.cluster.local:<configured port>
```

Both clusters use the same platform-managed root credential and object-storage
policy. Callers cannot provide an arbitrary replication host, bucket, prefix,
credential reference, or restore image.

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
replication/attach  namespace, dry_run, confirm, wait_timeout, expected_action
replication/status  namespace, include_peer
replication/detach  namespace, dry_run, confirm
restore-in-place    namespace, backup, dry_run, wait_timeout, confirm
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
| A and B have distinct `server_id` values | `SERVER_ID_CONFLICT`; redeploy with disjoint ranges. |
| B has a saved `gtid_slave_pos` | `NO_REPLICATION_HISTORY`; rebuild. |
| B is not ahead of A | `GTID_DIVERGED`; rebuild. |
| A still retains B's starting binlog | `PRIMARY_BINLOG_PURGED`; rebuild. |
| A is reachable and has binary logging | Error; never interpreted as permission to rebuild. |

Execution is the same endpoint with `dry_run=false` and `confirm=true`.
`expected_action` may pin the dry-run result so an expected resume cannot turn
into a destructive rebuild between calls.

When the action is `attach`, B runs:

```sql
STOP SLAVE;
RESET SLAVE ALL;
CHANGE MASTER TO
  MASTER_HOST='<derived peer>',
  MASTER_PORT=<configured port>,
  MASTER_USER='root',
  MASTER_PASSWORD=<platform credential>,
  MASTER_USE_GTID=slave_pos;
START SLAVE;
```

The password is encoded as a SQL hex literal and is never included in logs or
task results. Attach succeeds only after both replica threads are running.

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
STOP SLAVE;
RESET SLAVE ALL;
```

It leaves the CR, StatefulSet, PVCs, data, and operator-managed local replication
in place. Repeating detach after the link is gone is a successful no-op.

## Deployment requirements

- Both clusters run mariadb-operator 0.24 (`mariadb.*.mmontes.io`). Tasks fail
  closed when operator discovery is unknown or a different generation is found.
- `serverIdStartIndex` ranges are disjoint across clusters and set before
  deployment; the field is immutable.
- The mesh publishes the derived peer Service and A accepts the shared
  credential from B.
- Both workloads resolve the same S3 endpoint, bucket, prefix, and credentials.
- AQSH B has an A AQSH URL, and A's TokenReview policy trusts B's AQSH service
  account. B reads its projected token internally; callers never submit it.

Relevant deployment configuration:

| Variable | Default | Purpose |
|---|---|---|
| `REPL_PEER_SERVICE_SUFFIX_DEFAULT` | `-rw` | Derived peer Service suffix. |
| `REPL_PEER_PORT_DEFAULT` | `3306` | Peer MariaDB port. |
| `REPL_MAX_EXTERNAL_CONNECTIONS_DEFAULT` | `0` | Maximum allowed external sessions. |
| `REPL_IGNORED_ACCOUNTS_DEFAULT` | platform account list | Sessions excluded from the guard. |
| `REPL_PEER_CONNECT_TIMEOUT_DEFAULT` | `10` | Peer SQL connection timeout in seconds. |
| `REPL_PEER_AQSH_URL_DEFAULT` | unset | Primary AQSH URL used to request a backup. |
| `REPL_PEER_TOKEN_FILE_DEFAULT` | projected service-account token | Internal token used for the peer AQSH call. |
| `REPL_PEER_TASK_TIMEOUT_DEFAULT` | `900` | Maximum peer backup task wait. |

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
