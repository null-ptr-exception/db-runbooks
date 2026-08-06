# Cross-Cluster Replication — Operator Version Support

> **Status: design.** The 26 path is implemented and verified end to end (PR #99).
> The 24 path is designed here from live probes but not yet implemented.

Two operator generations must be supported:

| | apiGroup | Deployed as |
|---|---|---|
| Current | `k8s.mariadb.com` | mariadb-operator 26.x |
| Legacy | `mariadb.*.mmontes.io` | mariadb-operator 0.24.x |

They cannot coexist: the legacy suite deletes the current-generation CRDs before
installing 0.24, precisely so API discovery stays unambiguous.

## What 24 does not have

Confirmed from the installed CRD set (`mariadb.mmontes.io` has exactly 8:
`backups`, `connections`, `databases`, `grants`, `mariadbs`, `restores`,
`sqljobs`, `users`):

- **no `externalmariadbs`** — the endpoint objects the multiCluster topology
  references
- **no `physicalbackups`** — physical backup is hand-rolled on this generation
  (already true for `physical-backup`/`restore`, see `mdb_physical_backup_mode`)
- **no `spec.multiCluster`** — the whole cross-cluster topology mechanism
- **no `spec.suspend`** — verified absent from the CRD schema

So the 26 implementation is not "mostly portable" to 24; the parts that name the
peer and wire replication have no counterpart there and must be done in SQL.

## What stays shared

Everything that reasons about the databases rather than the operator:

- The attach/re-seed decision — all five checks (`server_id` collision, resumable
  GTID position, divergence, standby-local writes, primary binlog retention)
- The connection guard, including the re-check immediately before destroying data
- `dry_run` / `confirm` gating and the public result/reason contract
- Peer address derivation from the namespace
- **The in-place datadir restore** (below), which is plain Kubernetes + mariabackup

## The in-place restore, shared by both

Verified live. Replaces the delete-CR-and-PVC approach entirely:

```text
1. quiesce      stop the database without the operator restarting it
2. overwrite    Job mounts the existing PVC:
                  find /datadir -mindepth 1 -delete      (wipe in place)
                  mbstream -x -C /datadir < backup.xb
                  mariadb-backup --prepare --target-dir=/datadir
                  chown -R <uid>:<uid> /datadir
3. resume       scale back up
```

Probe results on a PVC pre-seeded with stale data: the stale files were gone,
the datadir contained the backup's contents, `--prepare` reported
`completed OK`, and the PVC was never deleted.

**The GTID starting point comes with the backup.** The restored datadir contains:

```text
xtrabackup_binlog_info:  mariadb-bin.000001  330  0-10-100
xtrabackup_slave_info:   SET GLOBAL gtid_slave_pos = '0-10-100';
                         CHANGE MASTER TO master_use_gtid = slave_pos;
```

`xtrabackup_slave_info` is literally the SQL the 24 path needs — the position
does not have to be derived. This is a consequence of how the backup is taken
(`--slave-info --safe-slave-backup`, seen in `xtrabackup_info.tool_command`).

Why this matters beyond 24: the current implementation deletes the MariaDB CR
and its PVCs because `bootstrapFrom` only applies to a new instance. In-place
overwrite removes that need on **both** generations, turning an irreversible
operation into one that leaves the standby intact if it fails.

## Where the two paths differ

| Concern | 26 | 24 |
|---|---|---|
| Capability gate | `mdb_operator_group` = `k8s.mariadb.com` | `mdb_is_legacy_operator` |
| Quiesce | `spec.suspend: true`, then scale the StatefulSet to 0 | scale the StatefulSet to 0 directly |
| Fresh backup | `PhysicalBackup` CR on the primary's AQSH | hand-rolled backup path (no CRD) |
| Restore | shared in-place Job | shared in-place Job |
| Wire replication | `multiCluster` + two `ExternalMariaDB` | `CHANGE MASTER TO ... MASTER_USE_GTID=slave_pos` + `START SLAVE` |
| Link state | `status.replication.replicas[<currentPrimary>]` | `SHOW ALL SLAVES STATUS` (connection name is operator-chosen on 26; unnamed here) |
| GTID start | operator handles it | replay `xtrabackup_slave_info` before `START SLAVE` |

### Quiesce, in detail

26 needs `suspend` because its operator reconciles the StatefulSet's replica
count back. Verified: with `suspend: true`, a manual scale to 0 held, pods went
away, PVCs survived, and after scaling back and clearing suspend the
cross-cluster link resumed on its own.

24 has no `suspend`, but its operator did **not** revert a direct scale to 0
within 45s, and the PVC survived.

> **Not yet proven for 24:** 45 seconds only rules out fast reconciliation. A
> longer periodic resync could still restart the StatefulSet mid-restore, which
> would be actively dangerous — the datadir would be half-overwritten. Before
> implementing, hold the scale-down for at least one full resync period, or find
> an explicit opt-out on 0.24. Scaling the CR to 0 instead is **not** available
> as a fallback: on a replicated instance the webhook rejects it ("Multiple
> replicas must be specified when 'spec.replication' or 'spec.galera' are
> configured") — observed on 26; 24's own validation is unverified.

### Wiring replication on 24

No `ExternalMariaDB` exists, so the peer is named directly in SQL on the
standby's primary pod:

```sql
SET GLOBAL gtid_slave_pos = '<from xtrabackup_slave_info>';
CHANGE MASTER TO
  MASTER_HOST = '<namespace>-rw.<namespace>.svc.cluster.local',
  MASTER_PORT = <peer port>,
  MASTER_USER = '<replication user>',
  MASTER_PASSWORD = '<...>',
  MASTER_USE_GTID = slave_pos;
START SLAVE;
```

The peer address is derived exactly as on 26 — the naming convention is
infrastructure, not an operator feature.

Two consequences to design around:

- **The operator does not know about this link.** On 26 the topology is declared
  and reconciled; here it is runtime state that a pod restart could lose. The
  status task must therefore read `SHOW ALL SLAVES STATUS` rather than trusting a
  spec field, and re-running attach has to be safe (it already is — an
  established, healthy link short-circuits).
- **Credentials appear in a SQL statement.** They must not reach the task log or
  the public result. The existing scripts already source them from the CR's own
  Secret reference; the same rule applies here, and the statement must never be
  echoed.

## Testing

Both e2e environments already exist: `tests/mariadb/` (26) and
`tests/mariadb-legacy/` (24, operator 0.24.0). They deploy to the same kind
clusters and delete each other's CRDs, so they cannot run concurrently.

The shared decision logic is covered by unit tests that mock the SQL layer and
are therefore version-agnostic. What needs a legacy e2e is the 24-specific
wiring: quiesce duration, SQL replication setup, and `SHOW ALL SLAVES STATUS`
parsing.

## Open questions

1. **24 resync period** — the blocking unknown above.
2. **Does 24's operator interfere with a manually configured slave?** On a
   replicated instance it manages `CHANGE MASTER` for its own replicas; whether
   it would reset a primary pod pointed at an external host is unverified.
3. **Replication user** — 26's `ExternalMariaDB` carries a credential reference.
   The 24 path needs the same account provisioned, and this repo's convention for
   where that lives across clusters is not yet settled.
