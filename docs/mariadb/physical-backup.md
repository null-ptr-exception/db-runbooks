# MariaDB Physical Backup AQSH Runbook

`physical-backup` creates a restorable physical backup for the managed MariaDB
in a namespace. It is the user-facing producer for [`restore`](./restore.md).

**The namespace is the database identity.** The caller chooses the namespace;
AQSH resolves all platform-managed backup and database details internally.

> A physical backup is restored with `restore`. A logical backup is a different
> artifact and must be restored with the logical restore task.

## Behavior

| Step | Detail |
|------|--------|
| Plan (default) | With `dry_run=true`, returns a sanitized preview without creating a backup. Internal manifests and backend configuration are never returned. |
| Guard | To create a backup, set `dry_run=false` and `confirm=true`. |
| Validate | Confirms that the namespace is eligible for backup. Platform-resolution failures are reported with a stable public reason and generic guidance. |
| Create | Starts one physical backup and returns its public name and state. |
| Wait | Waits for completion up to `wait_timeout`. Set it to `0` to return after creation. A timeout returns the last public state and a generic warning, without backend diagnostics. |

## Inputs

The only required input is `namespace`.

| Input | Required | Default | Notes |
|-------|:--:|---------|-------|
| `namespace` | ✓ | — | Database namespace to back up. |
| `dry_run` | | `true` | Preview only. Set to `false` with `confirm=true` to create the backup. |
| `wait_timeout` | | `10m` | Completion wait. `0` returns immediately after creation. |
| `confirm` | | `false` | Must be `true` when `dry_run=false`. |

Backup location, credentials, workload selection, and execution details are
platform-managed and are not task inputs.

## Examples

Preview the operation:

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/physical-backup" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1" }'
```

Create the backup:

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/physical-backup" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1", "dry_run": "false", "confirm": "true" }'
```

## Result

```json
{
  "namespace": "mariadb-1",
  "backupName": "physical-20260630121500",
  "contentType": "Physical",
  "state": "COMPLETED",
  "created": true,
  "dryRun": false
}
```

A dry run uses the same public fields with `state="PLANNED"`, `created=false`,
and `dryRun=true`. Results never contain backend locations, credential
references, rendered manifests, or platform resource details.

## Logical vs physical

| Backup type | Intended restore task |
|---|---|
| Logical | `logical-restore` |
| Physical | `restore` |
