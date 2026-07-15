# MariaDB Logical Backup AQSH Runbook

`logical-backup` creates a one-shot mariadb-operator `Backup` CR. The operator
runs `mariadb-dump` and writes the logical artifact to the configured S3/MinIO
bucket. Restore these artifacts with `logical-restore`; they are not physical
`restore` inputs.

## Operator compatibility

The task supports both mariadb-operator API generations and fails closed when
the generation cannot be determined:

| Operator group | S3 layout |
|---|---|
| `k8s.mariadb.com` | `mariadb-logical/<namespace>` via `spec.storage.s3.prefix` |
| `mariadb*.mmontes.io` | Bucket root; the legacy v0.0.24 S3 schema has no `prefix` field |

The legacy manifest intentionally omits `spec.storage.s3.prefix`; including it
causes strict decoding to reject the entire `Backup` object. Consequently, the
legacy operator cannot provide prefix-based namespace isolation inside a shared
bucket. Deployments that require storage-level isolation should configure a
dedicated bucket or credentials boundary for the legacy operator. AQSH reports
`backup.prefix=null`, `prefixSupported=false`, and
`storageLayout="bucket-root"` on this path instead of claiming that the
namespace prefix was applied.

## Inputs and behavior

- `namespace` is required and identifies the database namespace.
- `mariadb` is optional when the namespace contains exactly one MariaDB.
- `dry_run=true` renders the generation-specific manifest without applying it.
- Applying requires `dry_run=false` and `confirm=true`.
- `wait_timeout` defaults to `10m`; set it to `0` to return after creating the
  Backup CR without waiting for `condition=Complete`.
- The source MariaDB must be `Ready` before the Backup CR is created.

S3 endpoint, bucket, region, and credential references are deployment
configuration rather than task inputs.
