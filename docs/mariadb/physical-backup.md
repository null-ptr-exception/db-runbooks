# MariaDB Physical Backup AQSH Runbook

`physical-backup` takes a **physical** (`mariabackup`) backup of a namespace's
MariaDB to S3/MinIO, driving the mariadb-operator `PhysicalBackup` path. It is
the user-facing **producer** of the backups that [`restore`](./restore.md)
consumes — together they are the physical backup/restore pair.

**The namespace is the database identity:** the caller says only *which*
namespace to back up (and may pick the instance, the source target, and the
compression). The S3 backup location and credentials are **resolved internally**
from platform convention — the same `mdbt_resolve_backup_location` helper
`restore` reads — so a backup lands exactly where `restore` later looks for it
(`s3://db-backups/mariadb/<namespace>`).

> A physical backup is restorable via `restore`; the logical
> [`backup`](#logical-vs-physical) task (`mariadb-dump`) is a different artifact
> and is **not** a valid `restore` source.

## Behavior

| Step | Detail |
|------|--------|
| Plan (default) | With `dry_run=true` (the default) the task renders the `PhysicalBackup` manifest and returns without applying; `confirm` is not required. |
| Guard | To apply, set `dry_run=false` **and** `confirm=true` (mutating). |
| Resolve | The instance is the namespace's single MariaDB (or the `mariadb` input); the backup name is auto-generated; the S3 location and credentials come from platform convention. A namespace with several instances and no `mariadb` input fails rather than guessing. |
| Guard | The source MariaDB must exist and be `Ready` — otherwise the task fails instead of creating a backup that can never complete. |
| Apply | Creates a one-shot `PhysicalBackup` CR (no schedule) writing to `s3://db-backups/mariadb/<namespace>`. |
| Wait | Waits for `condition=Complete` (skip with `wait_timeout=0`). A wait timeout still returns a result carrying the backup location (status `error`), so a created-but-incomplete backup is never lost. |

## Inputs

The only required input is `namespace`.

| Input | Env | Required | Default | Notes |
|-------|-----|:--:|---------|-------|
| `namespace` | `DB_NAMESPACE` | ✓ | — | The database identity — the namespace to back up. |
| `mariadb` | `MARIADB_NAME` | | (auto) | Which instance to back up. Auto-detected when the namespace has exactly one. |
| `target` | `BACKUP_TARGET` | | `PreferReplica` | Back up from `Primary`, `Replica`, or `PreferReplica`. |
| `compression` | `BACKUP_COMPRESSION` | | `bzip2` | `bzip2`, `gzip`, or `none`. |
| `dry_run` | `DRY_RUN` | | `true` | Plan-only by default; set `false` (with `confirm=true`) to apply. |
| `wait_timeout` | `WAIT_TIMEOUT` | | `10m` | Complete-wait timeout. `0` returns immediately without waiting. |
| `confirm` | `CONFIRM` | | `false` | Must be `true` to apply. |

The **S3 backup location** (`s3://db-backups/mariadb/<namespace>`, MinIO
endpoint) and **credentials** are platform internals resolved from deploy-time
config (`MINIO_BUCKET` / `MINIO_ENDPOINT` in `/etc/aqsh/config/mariadb.env`) plus
the per-namespace convention — never task inputs. `BACKUP_BUCKET` /
`BACKUP_PREFIX` / `BACKUP_ENDPOINT` (and the access/region settings) stay
env-readable as advanced operator overrides only.

## Examples

Dry run (default) — render the plan for a namespace:

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/physical-backup" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1" }'
```

Take the backup:

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/physical-backup" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1", "dry_run": "false", "confirm": "true" }'
```

## Result

```json
{
  "namespace": "mariadb-1",
  "mariadb": "mariadb",
  "backupName": "mariadb-20260630121500",
  "backup": { "bucket": "db-backups", "prefix": "mariadb/mariadb-1", "endpoint": "http://minio.minio.svc.cluster.local:9000", "contentType": "Physical" },
  "target": "PreferReplica",
  "compression": "bzip2",
  "restorableBy": { "task": "restore", "namespace": "mariadb-1" },
  "created": true
}
```

## Logical vs physical

| | `backup` (logical) | `physical-backup` |
|---|---|---|
| Engine | `mariadb-dump` → `.sql.gz` | operator `PhysicalBackup` (`mariabackup`) |
| Restorable by `restore` | ❌ | ✅ |
| Layout | `db-backups/mariadb/<ns>/*.sql.gz` | `db-backups/mariadb/<ns>` (operator layout) |

A live backup → restore round-trip is covered by the e2e suite (tracked in #48).
