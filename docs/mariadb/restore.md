# MariaDB Restore AQSH Runbook

`restore` creates a new MariaDB for a namespace from an available physical
backup, optionally to a point in time. **The namespace is the database
identity:** the caller chooses the namespace and optional recovery time; all
database and backup configuration is platform-managed.

A restore always creates a new database target and never overwrites the current
one. Logical backups must use the logical restore task.

> Omitting `target_time` restores the latest available backup, not the live
> database at the moment the request is made.

## Scope

- Restore stays within the managed environment and source namespace.
- Restore creates a new target and refuses to overwrite an existing one.
- Point-in-time recovery is limited to recovery points retained by the platform.

## Behavior

| Step | Detail |
|------|--------|
| Plan (default) | With `dry_run=true`, returns a sanitized preview without creating a restored database. Internal manifests and backend configuration are never returned. |
| Guard | To start restore, set `dry_run=false` and `confirm=true`. |
| Resolve | Resolves the database definition and latest backup or requested recovery point internally. Resolution failures return a stable public reason and generic guidance. |
| Validate | `target_time`, when present, must be a valid RFC3339 instant, for example `2026-06-14T03:21:00Z`. |
| Restore | Creates a new restored database target. |
| Wait | Waits for readiness up to `wait_timeout`. Set it to `0` to return after creation. A timeout returns the last public state and a generic warning. |

## Inputs

The only required input is `namespace`.

| Input | Required | Default | Notes |
|-------|:--:|---------|-------|
| `namespace` | ✓ | — | Database namespace to restore. |
| `target_time` | | — | RFC3339 recovery time. Omit to restore the latest available backup. |
| `dry_run` | | `true` | Preview only. Set to `false` with `confirm=true` to restore. |
| `wait_timeout` | | `10m` | Readiness wait. `0` returns immediately after creation. |
| `confirm` | | `false` | Must be `true` when `dry_run=false`. |

Backup location, credentials, workload selection, database image, capacity, and
execution details are platform-managed and are not task inputs.

## Examples

Preview a latest-backup restore:

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/restore" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-bg" }'
```

Restore the latest available backup:

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/restore" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-bg", "dry_run": "false", "confirm": "true" }'
```

Restore to a point in time:

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
  "contentType": "Physical",
  "state": "COMPLETED",
  "pointInTimeRecovery": {
    "enabled": false,
    "targetRecoveryTime": null
  },
  "provisioned": true,
  "restored": true,
  "dryRun": false
}
```

The namespace remains the public database identity. Connection and credentials
continue through the platform's normal user access flow. Results never contain
backup locations, credential references, rendered manifests, or platform
resource details.

## Notes

- A requested recovery time outside the available recovery window fails without
  creating a target.
- Restore requires the platform to retain enough database configuration to
  rebuild the target. If that configuration is unavailable, the task fails with
  generic guidance rather than exposing backend details.
- A restored database is standalone. Use the blue/green workflow separately if
  it must join a blue/green deployment.
