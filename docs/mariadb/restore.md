# MariaDB Restore AQSH Runbook

`restore` provisions a **new** MariaDB instance from a mariadb-operator physical
backup, optionally to a point in time. The caller says *what* to restore (a
namespace, and optionally a point-in-time); the managed-database internals —
credentials, S3 endpoint/region/credentials, the backup location, the engine
version, and the storage size — are **resolved automatically** and are only
overridable as advanced options.

The source must be an operator `PhysicalBackup` / `mariabackup` object-storage
layout, such as the one produced by the blue-green runbook; the logical `backup`
task (a `mariadb-dump`) is **not** a valid restore source.

It is modelled on the AWS RDS restore APIs
(`RestoreDBInstanceFromDBSnapshot` / `RestoreDBInstanceToPointInTime`): a restore
**always creates a new instance and never overwrites in place**, so it is safe to
run against a typo and doubles as a "clone for debugging". Under the hood it
drives the operator `spec.bootstrapFrom` path (no replication / multi-cluster
wiring). With `target_time`, `bootstrapFrom.targetRecoveryTime` performs
point-in-time recovery; without it, the **latest backup** under the prefix is
restored.

> ⚠️ "No `target_time`" restores the **last backup**, not the live "now". To
> recover close to the present you need point-in-time recovery against
> continuously-archived binlogs (not yet exposed here).

## Behavior

| Step | Detail |
|------|--------|
| Plan (default) | With `dry_run=true` (the default) the task renders the MariaDB manifest and returns without applying; `confirm` is not required. |
| Guard | To apply, set `dry_run=false` **and** `confirm=true` (mutating). |
| Resolve | `target` is auto-named; the source instance is auto-detected (the single MariaDB in the namespace, or `source`) and `image`/`storage_size` come from it; the backup location, credentials, and S3 config come from platform convention. |
| Guard | If a MariaDB named `target` already exists, the task fails — restore never overwrites in place. |
| Validate | `target_time`, when given, must be a range-checked RFC3339 instant (e.g. `2026-06-14T03:21:00Z`). |
| Apply | Creates a standalone `MariaDB` CR via `bootstrapFrom.s3` (`backupContentType: Physical`), `replicas=1`, no replication/multiCluster. |
| Wait | Waits for `condition=Ready` (skipped with `wait_ready=false`). |

## Inputs

The only required input is `namespace`.

| Input | Env | Required | Default | Notes |
|-------|-----|:--:|---------|-------|
| `namespace` | `DB_NAMESPACE` | ✓ | — | Source namespace. |
| `target_time` | `TARGET_TIME` | | — | RFC3339 instant for point-in-time recovery. Omit to restore the latest backup. |
| `source` | `RESTORE_SOURCE` | | auto | Source MariaDB instance (for version/storage). Auto-detected as the single MariaDB in the namespace; **required when more than one exists** (restore itself creates new instances in the namespace). |
| `target` | `RESTORE_TARGET` | | auto | New instance name. Auto-named `<namespace>-restore-<ts>` when omitted. |
| `image` | `RESTORE_IMAGE` | | source | MariaDB image, derived from the source instance. The version is **never guessed** — if the source is gone or ambiguous, pass `image` explicitly. |
| `storage_size` | `STORAGE_SIZE` | | source | PVC size. Derived from the source instance; `1Gi` if it is gone. |
| `backup_bucket` | `BACKUP_BUCKET` | | `db-backups` | Advanced override. |
| `backup_prefix` | `BACKUP_PREFIX` | | `mariadb/<namespace>` | Advanced override (per-namespace convention). |
| `backup_endpoint` | `BACKUP_ENDPOINT` | | platform MinIO | Advanced override. |
| `wait_ready` | `WAIT_READY` | | `true` | Set `false` to return without waiting for Ready. |
| `dry_run` | `DRY_RUN` | | `true` | Plan-only by default; set `false` (with `confirm=true`) to apply. |
| `wait_timeout` | `WAIT_TIMEOUT` | | `10m` | Ready wait timeout. |
| `confirm` | `CONFIRM` | | `false` | Must be `true` to apply. |

Credentials and S3 access are platform internals and are **not** task inputs.

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

- **Forward-looking backup convention.** `backup_prefix` defaults to
  `mariadb/<namespace>`. Until the physical-backup task writes to that layout,
  point `backup_prefix`/`backup_bucket` at where the backup actually lives.
- **PITR depends on the operator + backup retaining the recovery point.** A
  `target_time` outside the available backup/binlog window will fail at the
  operator level.
- **Version sensitivity.** A physical restore must use the source's MariaDB
  version, so `image` is taken from the source instance and is never guessed.
  When the source is gone or ambiguous and `image` is not provided, the task
  fails and asks for `image` explicitly.
- **Standalone by design.** To turn a restored instance into a replica or a
  blue/green member, drive it through the blue-green tasks afterwards.
