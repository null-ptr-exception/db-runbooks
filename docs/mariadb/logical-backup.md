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

## Logical restore

`logical-restore` provisions a new database from a logical backup. Its public
inputs are limited to caller decisions:

| Input | Required | Default | Notes |
|-------|:--:|---------|-------|
| `namespace` | ✓ | — | Database namespace whose logical backup will be restored. |
| `backup` | | latest | Logical backup name. When omitted, the platform selects the latest available backup when applying the restore. |
| `dry_run` | | `true` | Return a sanitized plan. No manifest or platform resource name is returned. |
| `wait_timeout` | | `10m` | Completion wait. `0` returns after the restore request is accepted. |
| `confirm` | | `false` | Must be `true` when `dry_run=false`. |

The public result is limited to `namespace`, `contentType`, `state`, `dryRun`,
`provisioned`, and `restored`. The selected backup and generated database
resource stay internal. State and progress flags have the following meanings:

| Outcome | `state` | `provisioned` | `restored` | `dryRun` |
|---------|---------|:-------------:|:----------:|:--------:|
| Sanitized plan | `PLANNED` | `false` | `false` | `true` |
| Request accepted without waiting | `REQUESTED` | `true` | `false` | `false` |
| Wait elapsed while restore is still running | `PENDING` | `true` | `false` | `false` |
| Restore completed | `COMPLETED` | `true` | `true` | `false` |

Errors use the stable top-level `reason` contract. When progress data is
returned, it uses only this sanitized shape; invalid public inputs may identify
the caller-provided field. Neither success, dry-run, nor error responses expose
a rendered manifest, generated target, internal source or image, credential or
Secret reference, operator/Kubernetes detail, or raw diagnostic output.

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
