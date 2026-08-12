# Cross-Cluster Replication Operator Support

PR #99 targets mariadb-operator 0.24 (`mariadb.*.mmontes.io`) only.

## Why the runbook owns the link

The installed 0.24 CRD set has no:

- `externalmariadbs` resource;
- `physicalbackups` resource;
- `MariaDB.spec.multiCluster` field;
- `MariaDB.spec.suspend` field.

Therefore cross-cluster replication cannot be delegated to the operator. The
division of responsibility is:

| Concern | Owner on v24 |
|---|---|
| MariaDB CR, StatefulSet, Services, local replicas | mariadb-operator |
| Physical backup | db-runbooks hand-rolled `mariabackup` stream |
| In-place restore | db-runbooks one-shot Pod init hook on existing PVCs |
| Cross-cluster source configuration | db-runbooks native MariaDB SQL |
| Link status | `SHOW ALL SLAVES STATUS` |

The runbook requires a confidently detected legacy operator profile. A current
operator or failed/ambiguous discovery returns `OPERATION_UNAVAILABLE` or
`INTERNAL_ERROR`; it never silently selects another implementation.

## v24 restore behavior

The existing `restore` task creates a new database instance. Cross-cluster
rebuild instead uses the new `restore-in-place` primitive:

```text
verify exact backup object
  -> connection guard
  -> fence StatefulSet rollout with OnDelete
  -> append one-shot restore init containers to the MariaDB CR
  -> delete all old DB pods
  -> restore each PVC before its mysqld starts
  -> verify restore markers
  -> remove the hook and delete pods for a clean final start
  -> restore the original update strategy
```

No CR or PVC is deleted. v24 cannot be suspended through its CR, and its
reconciler overwrites direct StatefulSet replica changes from
`MariaDB.spec.replicas`; therefore the task never scales the StatefulSet. The
operator-supported `spec.initContainers` hook guarantees the restore finishes
before the MariaDB main container starts. A backup-specific marker makes Pod
replacement retries idempotent.

## v24 SQL behavior

After an in-place restore, attach uses `MASTER_USE_GTID=current_pos`. A resumable
standby uses `MASTER_USE_GTID=slave_pos`. The source host is derived from the
namespace, the credential is platform-managed, and the SQL statement is never
logged.

Detach only stops/resets that derived source. If B is configured for another
source, attach and detach both fail with `REPLICATION_SOURCE_MISMATCH` instead
of overwriting unrelated replication state.

## Future v26 work

Support for a newer operator generation may later use `ExternalMariaDB` and
`spec.multiCluster`, but it is outside PR #99. It should be introduced as a
separate capability path with its own E2E evidence, not mixed into the v24 SQL
implementation.
