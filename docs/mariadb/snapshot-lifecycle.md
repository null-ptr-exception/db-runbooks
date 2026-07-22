# MariaDB Backup Lifecycle AQSH Runbook (list / delete)

`list-backups` and `delete-backup` manage backups associated with a database
namespace. Backup storage and execution details are resolved internally and are
never caller inputs or result fields.

## list-backups

`list-backups` is read-only. Its only input is `namespace`.

| Input | Required | Notes |
|-------|:--:|-------|
| `namespace` | ✓ | Database namespace whose backups should be listed. |

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/list-backups" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1" }'
```

```json
{
  "namespace": "mariadb-1",
  "count": 2,
  "backups": [
    {
      "name": "backup-20260101000000",
      "sizeBytes": 10485760,
      "lastModified": "2026-01-01T00:00:00Z"
    },
    {
      "name": "backup-20260102000000",
      "sizeBytes": 20971520,
      "lastModified": "2026-01-02T00:00:00Z"
    }
  ]
}
```

## delete-backup

`delete-backup` deletes one backup associated with the namespace.

| Input | Required | Default | Notes |
|-------|:--:|---------|-------|
| `namespace` | ✓ | — | Database namespace that owns the backup. |
| `backup` | ✓ | — | Exact backup name returned by `list-backups`. |
| `dry_run` | | `true` | Preview only. Set to `false` with `confirm=true` to delete. |
| `confirm` | | `false` | Must be `true` when `dry_run=false`. |

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/delete-backup" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1", "backup": "backup-20260102000000", "dry_run": "false", "confirm": "true" }'
```

```json
{
  "namespace": "mariadb-1",
  "backup": "backup-20260102000000",
  "state": "DELETED",
  "deleted": true,
  "dryRun": false
}
```

A missing or invalid backup name fails without deleting anything. Public
results and errors never include backend locations, credential references,
rendered manifests, or platform resource details.

Automated retention and scheduled cleanup are separate platform policies.
