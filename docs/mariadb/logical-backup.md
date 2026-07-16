# MariaDB Logical Backup AQSH Runbook

`logical-backup` creates a logical backup for the managed MariaDB in a
namespace. Restore it with the logical restore task; it is not a physical
`restore` input.

**The namespace is the database identity.** Backup location, credentials,
workload selection, and platform compatibility are resolved internally and are
not caller inputs.

## Behavior

| Step | Detail |
|------|--------|
| Plan (default) | With `dry_run=true`, returns a sanitized preview without creating a backup. Internal manifests and backend configuration are never returned. |
| Guard | To create a backup, set `dry_run=false` and `confirm=true`. |
| Validate | Confirms that the namespace is eligible for logical backup. Platform-resolution failures use a stable public reason and generic guidance. |
| Create | Starts one logical backup and returns its public name and state. |
| Wait | Waits for completion up to `wait_timeout`. Set it to `0` to return after creation. A timeout returns the last public state and a generic warning. |

## Inputs

The only required input is `namespace`.

| Input | Required | Default | Notes |
|-------|:--:|---------|-------|
| `namespace` | ✓ | — | Database namespace to back up. |
| `dry_run` | | `true` | Preview only. Set to `false` with `confirm=true` to create the backup. |
| `wait_timeout` | | `10m` | Completion wait. `0` returns immediately after creation. |
| `confirm` | | `false` | Must be `true` when `dry_run=false`. |

The compatibility `backup` task accepts only `namespace`; it exposes the same
sanitized storage boundary and starts the backup immediately.

## Examples

Preview the operation:

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/logical-backup" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1" }'
```

Create the backup:

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/logical-backup" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1", "dry_run": "false", "confirm": "true" }'
```

## Result

```json
{
  "namespace": "mariadb-1",
  "backupName": "logical-20260630122000",
  "contentType": "Logical",
  "state": "COMPLETED",
  "created": true,
  "dryRun": false
}
```

Results never contain backend locations, credential references, rendered
manifests, or platform resource details.
