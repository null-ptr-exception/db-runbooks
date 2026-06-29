# MariaDB Restore AQSH Runbook

`restore` recreates a namespace's MariaDB from its mariadb-operator physical
backup, optionally to a point in time. **The namespace is the database
identity:** the caller says only *which* namespace to restore (and optionally a
point-in-time). Everything that defines the database — the engine version, the
storage size, the restored instance name, which instance to copy the spec from,
the S3 backup location, and the credentials — is **resolved internally** and is
**not** a task input.

The source must be an operator `PhysicalBackup` / `mariabackup` object-storage
layout, such as the one produced by the blue-green runbook; the logical `backup`
task (a `mariadb-dump`) is **not** a valid restore source.

It is modelled on the AWS RDS restore APIs
(`RestoreDBInstanceFromDBSnapshot` / `RestoreDBInstanceToPointInTime`): a restore
**always creates a new instance and never overwrites in place**, so it is safe to
run against a typo. Under the hood it drives the operator `spec.bootstrapFrom`
path (no replication / multi-cluster wiring). With `target_time`,
`bootstrapFrom.targetRecoveryTime` performs point-in-time recovery; without it,
the **latest backup** under the prefix is restored.

> ⚠️ "No `target_time`" restores the **last backup**, not the live "now". To
> recover close to the present you need point-in-time recovery against
> continuously-archived binlogs (not yet exposed here).

## Scope

- **Same cluster.** Restore runs where aqsh, the mariadb-operator, and the
  MariaDB instances all live (`cluster-dbs`), via the in-cluster config.
  `context` is only a *reachability* hook — leave it empty in-cluster; set it to
  reach the same cluster from an out-of-cluster kubeconfig (dev/ops/tests). It
  is **not** a cross-cluster switch; cross-cluster restore (which would need the
  operator + secrets provisioned in the target cluster) is out of scope.
- **Same namespace.** The restored instance is created in the source namespace;
  there is no target-namespace input.
- **New instance.** Restore never overwrites in place — it refuses if an
  instance with the resolved name already exists.

## Behavior

| Step | Detail |
|------|--------|
| Plan (default) | With `dry_run=true` (the default) the task renders the MariaDB manifest and returns without applying; `confirm` is not required. |
| Guard | To apply, set `dry_run=false` **and** `confirm=true` (mutating). |
| Resolve | The restored instance name is auto-generated; the engine version and PVC size are derived from the namespace's instance (a single shared version is accepted across instances) and are **never** silently defaulted; the backup location, credentials, and S3 config come from platform convention. |
| Guard | If a MariaDB with the resolved name already exists, the task fails — restore never overwrites in place. |
| Validate | `target_time`, when given, must be a range-checked RFC3339 instant (e.g. `2026-06-14T03:21:00Z`). |
| Apply | Creates a standalone `MariaDB` CR via `bootstrapFrom.s3` (`backupContentType: Physical`), `replicas=1`, no replication/multiCluster. |
| Wait | Waits for `condition=Ready` (skip with `wait_timeout=0`). A wait timeout still returns a result carrying the connection endpoint + credential ref (status `error`), so the not-yet-Ready instance is never lost. |

## Inputs

The only required input is `namespace`. The full caller surface is just six
inputs:

| Input | Env | Required | Default | Notes |
|-------|-----|:--:|---------|-------|
| `namespace` | `DB_NAMESPACE` | ✓ | — | The database identity — the namespace to restore. |
| `context` | `K8S_CONTEXT` | | `""` | Reachability hook (see _Scope_). Leave empty in-cluster; set it only to reach the same cluster from an out-of-cluster kubeconfig. Validated when non-empty. |
| `target_time` | `TARGET_TIME` | | — | RFC3339 instant for point-in-time recovery. Omit to restore the latest backup. |
| `dry_run` | `DRY_RUN` | | `true` | Plan-only by default; set `false` (with `confirm=true`) to apply. |
| `wait_timeout` | `WAIT_TIMEOUT` | | `10m` | Ready wait timeout. `0` returns immediately without waiting. |
| `confirm` | `CONFIRM` | | `false` | Must be `true` to apply. |

Everything else that defines the restored database is a **platform internal,
resolved from the namespace — not a task input**:

- **Engine version & storage size** are derived from the namespace's instance
  and never silently defaulted (a mismatched version is unsafe for a physical
  restore; an undersized PVC would truncate the restored data). A single shared
  version is accepted across instances; mixed versions or no instance make the
  task fail rather than guess.
- **Restored instance name & source instance** are auto-resolved from the
  namespace.
- **Credentials / S3 access** are resolved internally. The restored instance
  reuses the platform-managed root Secret (named `mariadb`, key `password`) —
  the same convention every managed MariaDB in a namespace follows — returned
  as `credentialsRef` in the result.
- **Backup location** (`s3://db-backups/mariadb/<namespace>`, MinIO endpoint,
  region) is resolved from platform convention — the caller never specifies
  where backups live.

> **Operator overrides.** `RESTORE_SOURCE`, `RESTORE_TARGET`, `RESTORE_IMAGE`,
> and `STORAGE_SIZE` stay readable as environment overrides for operators /
> automation, but they are deliberately **not** task inputs — a caller restores
> by namespace, not by spelling out the spec.

## Examples

Dry run (default) — render the plan for a namespace:

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/restore" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-bg" }'
```

Restore the latest backup:

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/restore" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-bg", "dry_run": "false", "confirm": "true" }'
```

Point-in-time restore:

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/restore" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{
    "namespace": "mariadb-bg",
    "target_time": "2026-06-14T03:21:00Z",
    "dry_run": "false",
    "confirm": "true"
  }'
```

## Result

```json
{
  "namespace": "mariadb-bg",
  "target": "mariadb-bg-restore-20260614031500",
  "image": "mariadb:11.4",
  "backup": { "bucket": "db-backups", "prefix": "mariadb/mariadb-bg", "endpoint": "minio.db-ops.svc.cluster.local:9000", "contentType": "Physical" },
  "pointInTimeRecovery": { "enabled": false, "targetRecoveryTime": null },
  "connection": { "host": "mariadb-bg-restore-20260614031500-primary.mariadb-bg.svc.cluster.local", "port": 3306 },
  "credentialsRef": { "secretName": "mariadb", "secretKey": "password" },
  "restored": true
}
```

The restored instance is reached at `connection.host:port`; its root credentials
live in the Secret named by `credentialsRef` (the restored data carries the
source's users and passwords).

## Notes

- **Forward-looking backup convention.** Restore reads from
  `s3://db-backups/mariadb/<namespace>` (resolved internally). This is a
  forward-looking convention: until the physical-backup *write* side adopts the
  same layout, restore reads from a location nothing writes to yet. Closing that
  gap (and dropping this note) is tracked as a follow-up.
- **PITR depends on the operator + backup retaining the recovery point.** A
  `target_time` outside the available backup/binlog window will fail at the
  operator level.
- **Version sensitivity.** A physical restore must use the source's MariaDB
  version, so the engine version is derived from the namespace's instances and
  never guessed: a single shared version is used automatically (instances in a
  namespace should not differ outside a blue-green upgrade); mixed versions make
  the task fail rather than guess.
- **Full-loss DR is not self-reconstructing yet.** Today the version and storage
  are derived from an instance that is **still present** in the namespace. If a
  namespace's MariaDB is *entirely* gone (the canonical "restore my deleted
  database" case), there is no in-cluster spec left to derive from — the
  namespace's identity is durable, but the spec behind it is not yet persisted
  anywhere the in-cluster task can read. Closing this needs the backup to carry
  the spec (or a per-namespace config), tracked together with the physical-backup
  write side. Meanwhile an operator can drive a full-loss restore via the
  `RESTORE_IMAGE` / `STORAGE_SIZE` env overrides.
- **Standalone by design.** To turn a restored instance into a replica or a
  blue/green member, drive it through the blue-green tasks afterwards.
