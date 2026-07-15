# MariaDB Backup Lifecycle AQSH Runbook (list / delete)

`list-backups` and `delete-backup` manage the backups produced by `backup`
(logical) and `physical-backup` (physical) and consumed by `restore`. They are
the AWS RDS `DescribeDBSnapshots` / `DeleteDBSnapshot` analogues.

**The namespace is the database identity.** The caller gives the `namespace`
(and, for delete, the `backup` name); the bucket, endpoint, and prefix are
resolved from the selected MariaDB workload, then deploy-time configuration and
the `s3://<bucket>/mariadb/<namespace>/` compatibility convention — the same
location the physical backup tasks write and `restore` reads. See
[MariaDB object-storage resolution](object-storage-resolution.md).

## list-backups (DescribeDBSnapshots)

Read-only. Lists the backup objects under the namespace's prefix.

| Input | Env | Required | Notes |
|-------|-----|:--:|-------|
| `namespace` | `DB_NAMESPACE` | ✓ | The database identity |
| `mariadb` | `MARIADB_NAME` | | Workload storage policy; auto-selected when exactly one exists |

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/list-backups" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1" }'
```

```json
{
  "namespace": "mariadb-1",
  "location": { "bucket": "db-backups", "prefix": "mariadb/mariadb-1", "endpoint": "http://minio.minio.svc.cluster.local:9000" },
  "count": 2,
  "backups": [
    { "name": "mariadb-mariadb-1-20260101-000000.sql.gz", "size": 10485760, "lastModified": "2026-01-01T00:00:00Z" },
    { "name": "physicalbackup-20260102", "size": 0, "lastModified": "2026-01-02T00:00:00Z" }
  ]
}
```

## delete-backup (DeleteDBSnapshot)

Mutating. Deletes one named backup under the namespace's prefix.

| Input | Env | Required | Default | Notes |
|-------|-----|:--:|---------|-------|
| `namespace` | `DB_NAMESPACE` | ✓ | — | The database identity |
| `mariadb` | `MARIADB_NAME` | | (auto) | Workload storage policy; required only when selection is ambiguous |
| `backup` | `BACKUP_NAME` | ✓ | — | Backup to delete — a **single name segment** (from `list-backups`); no paths |
| `dry_run` | `DRY_RUN` | | `true` | Plan-only by default; set `false` (with `confirm=true`) to delete |
| `confirm` | `CONFIRM` | | `false` | Must be `true` to delete |

The `backup` value must be a single name segment (`^[A-Za-z0-9._-]+$`), so a
delete can never escape the namespace's own prefix. A missing backup fails
clearly rather than silently no-op'ing.

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/delete-backup" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1", "backup": "physicalbackup-20260102", "dry_run": "false", "confirm": "true" }'
```

## Notes

- These operate over the S3/MinIO objects (via `mc`), so a delete removes the
  actual backup data (RDS `DeleteDBSnapshot` semantics), and a list reflects
  what `restore` could consume.
- The mariadb-operator's exact **physical** backup object layout under the prefix
  should be confirmed against a live lab (tracked with the restore e2e work in
  #48); the logical (`mariadb-dump`) layout `mariadb/<namespace>/*.sql.gz` is known.
- Automated retention / backup-window cleanup (RDS retention period) is a
  separate future item.
