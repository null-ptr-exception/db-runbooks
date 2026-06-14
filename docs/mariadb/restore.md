# MariaDB Restore AQSH Runbook

`restore` provisions a **new** MariaDB instance from a mariadb-operator
physical backup in S3/MinIO, optionally to a point in time. The source must be
an operator `PhysicalBackup` / `mariabackup` object-storage layout, such as the
one produced by the blue-green runbook; the logical `backup` task is not a
valid restore source.

It is modelled on the AWS RDS restore APIs
(`RestoreDBInstanceFromDBSnapshot` / `RestoreDBInstanceToPointInTime`): a
restore **always creates a new instance and never overwrites in place**. That
makes it safe to run against a typo and doubles as a "clone for debugging".

Under the hood it drives the mariadb-operator `spec.bootstrapFrom` restore path
— the same machinery `blue-green/create` uses to bootstrap Green — but without
the replication / multi-cluster wiring. When `target_time` is supplied,
`bootstrapFrom.targetRecoveryTime` performs point-in-time recovery; otherwise
the latest backup under the prefix is restored.

## Behavior

| Step | Detail |
|------|--------|
| Plan (default) | With `dry_run=true` (the default) the task renders the MariaDB manifest and returns without applying it; `confirm` is not required. |
| Guard | To apply, set `dry_run=false` **and** `confirm=true` (mutating). |
| Guard | If a MariaDB named `target` already exists, the task fails — restore never overwrites in place. |
| Validate | `target_time`, when given, must be an RFC3339 instant (e.g. `2026-06-14T03:21:00Z`). |
| Apply | Creates a standalone `MariaDB` CR with `bootstrapFrom.s3` (`backupContentType: Physical`), `replicas=1`, no replication/multiCluster. |
| Wait | Waits for `condition=Ready` (skipped with `wait_ready=false`). |

## Inputs

| Input | Env | Required | Default | Notes |
|-------|-----|:--:|---------|-------|
| `namespace` | `DB_NAMESPACE` | ✓ | — | Target namespace. |
| `target` | `RESTORE_TARGET` | ✓ | — | Name of the **new** MariaDB instance to create. Must not already exist. |
| `image` | `RESTORE_IMAGE` | ✓ | — | MariaDB image to restore as (match the backup's major version). |
| `target_time` | `TARGET_TIME` | | — | RFC3339 instant for point-in-time recovery. Omit to restore the latest backup. |
| `root_secret_name` | `ROOT_SECRET_NAME` | | `mariadb` | Secret holding the root password. |
| `root_secret_key` | `ROOT_SECRET_KEY` | | `password` | Key within the secret. |
| `storage_size` | `STORAGE_SIZE` | | `1Gi` | PVC size for the restored instance. |
| `replicas` | `REPLICAS` | | `1` | Must be `1`; restore does not create replication/multiCluster wiring. |
| `backup_bucket` | `BACKUP_BUCKET` | ✓ | — | S3/MinIO bucket holding the backup. |
| `backup_prefix` | `BACKUP_PREFIX` | ✓ | — | Prefix under the bucket. |
| `backup_endpoint` | `BACKUP_ENDPOINT` | ✓ | — | S3/MinIO endpoint (`host:port`). |
| `backup_region` | `BACKUP_REGION` | | `us-east-1` | |
| `backup_access_secret` | `BACKUP_ACCESS_SECRET` | | `minio` | Secret holding the S3 credentials. |
| `backup_access_key` | `BACKUP_ACCESS_KEY` | | `access-key-id` | Access-key-id key within the secret. |
| `backup_secret_key` | `BACKUP_SECRET_KEY` | | `secret-access-key` | Secret-access-key key within the secret. |
| `wait_ready` | `WAIT_READY` | | `true` | Set `false` to return without waiting for Ready. |
| `dry_run` | `DRY_RUN` | | `true` | Plan-only by default: renders the manifest without applying. Set `false` (with `confirm=true`) to apply. |
| `wait_timeout` | `WAIT_TIMEOUT` | | `10m` | Ready wait timeout. |
| `confirm` | `CONFIRM` | | `false` | Must be `true` to apply. |

## Examples

Restore the latest backup into a new instance:

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/restore" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{
    "namespace": "mariadb-bg",
    "target": "mariadb-restored",
    "image": "mariadb:10.11",
    "backup_bucket": "multi-cluster",
    "backup_prefix": "blue",
    "backup_endpoint": "minio.db-ops.svc.cluster.local:9000",
    "confirm": "true"
  }'
```

Point-in-time restore to a specific instant:

```bash
curl -sX POST "$MARIADB_AQSH_URL/tasks/restore" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{
    "namespace": "mariadb-bg",
    "target": "mariadb-pitr",
    "image": "mariadb:10.11",
    "backup_bucket": "multi-cluster",
    "backup_prefix": "blue",
    "backup_endpoint": "minio.db-ops.svc.cluster.local:9000",
    "target_time": "2026-06-14T03:21:00Z",
    "confirm": "true"
  }'
```

## Result

```json
{
  "namespace": "mariadb-bg",
  "target": "mariadb-restored",
  "image": "mariadb:10.11",
  "backup": {
    "bucket": "multi-cluster",
    "prefix": "blue",
    "endpoint": "minio.db-ops.svc.cluster.local:9000",
    "region": "us-east-1",
    "contentType": "Physical"
  },
  "pointInTimeRecovery": { "enabled": false, "targetRecoveryTime": null },
  "restored": true
}
```

## Notes

- **Depends on a physical backup.** The logical `backup` task (a `mariadb-dump`)
  is not a valid restore source — only physical (`mariabackup`) backups carry
  the base a `bootstrapFrom` / PITR restore needs.
- **Requires existing target-namespace Secrets.** The restore manifest references
  `root_secret_name` / `root_secret_key` (default `mariadb` / `password`) and
  `backup_access_secret` (default `minio`) in the target namespace. Create or
  copy those Secrets before running the task.
- **One replica only.** The task intentionally provisions a standalone restored
  instance. Use blue-green or replication-specific tasks after restore if the
  clone needs to join a replicated topology.
- **PITR depends on the operator + backup retaining the recovery point.** A
  `target_time` outside the available backup/binlog window will fail at the
  operator level.
- **Standalone by design.** To turn a restored instance into a replica or a
  blue/green member, drive it through the blue-green tasks afterwards.
