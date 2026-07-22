# MariaDB Object Storage — Platform Operator Reference

> **Audience: platform operators and db-runbooks maintainers.** This document
> describes deployment and resolver internals. It is not part of the public
> AQSH task API. API callers never provide or receive the fields described below.

AQSH resolves backup storage from the managed MariaDB workload associated with
the requested namespace. The `S3_*` variables are an AQSH workload contract
carried by `MariaDB.spec.env` or `MariaDB.spec.envFrom`; they are not
mariadb-operator configuration fields. Both the legacy and current MariaDB CRDs
expose these container environment fields.

This remains deployment configuration. The change is its ownership and
location: instead of relying on one AQSH-wide storage setting, each MariaDB can
declare its own object-storage policy. Reading that declared policy is not
generic live auto-detection or a best-effort guess. Legacy AQSH-wide
configuration remains supported as a migration fallback, and an advanced
explicit platform-process override remains the highest-precedence operator
control.

If the namespace does not resolve to exactly one eligible workload policy, the
resolver fails closed. A public caller cannot select a MariaDB custom resource
or use it to choose a storage policy.

## Public API boundary

Public task inputs are intentionally limited to user decisions:

| Task | Public inputs |
|---|---|
| `backup` | `namespace` |
| `physical-backup` | `namespace`, `dry_run`, `wait_timeout`, `confirm` |
| `logical-backup` | `namespace`, `dry_run`, `wait_timeout`, `confirm` |
| `logical-restore` | `namespace`, `backup`, `dry_run`, `wait_timeout`, `confirm` |
| `list-backups` | `namespace` |
| `delete-backup` | `namespace`, `backup`, `dry_run`, `confirm` |
| `restore` | `namespace`, `target_time`, `dry_run`, `wait_timeout`, `confirm` |

The public API never accepts a Kubernetes context, MariaDB resource name,
container name, backend location, credential reference, or resolver override.

Public results are allowlisted by operation:

- Backup creation: namespace, backup name, type, state, created/dry-run flags,
  and a generic warning when needed.
- Backup listing: namespace plus backup name, size, and modification time.
- Backup deletion: namespace, backup name, state, deleted/dry-run flags,
  and a generic warning when needed.
- Physical restore: namespace, type, state, provisioned/restored/dry-run flags,
  requested PITR state, and a generic warning when needed.
- Logical restore: namespace, type, state, and provisioned/restored/dry-run
  flags. The selected backup and generated database resource stay internal.

Public dry runs return a sanitized plan, never a rendered manifest. Results and
errors never contain endpoint, bucket, prefix, region, object path, a rendered
manifest, generated restore target or internal source/image selection, Secret
or ConfigMap names/keys, credential data, Kubernetes resource names, operator
API details, or raw Kubernetes/backend diagnostics. Public failures use a
stable reason code and generic guidance; platform operators use internal
observability for diagnosis.

The machine-readable code is the top-level `reason` field. The backup/restore
surface uses this stable set:

| Reason | Meaning |
|---|---|
| `INVALID_REQUEST` | A public input or confirmation gate is invalid. |
| `DATABASE_CONFIGURATION_AMBIGUOUS` | Namespace identity cannot safely resolve to one database policy. |
| `DATABASE_NOT_FOUND` / `DATABASE_NOT_READY` | The namespace database is absent or not ready for the operation. |
| `BACKUP_CONFIGURATION_UNAVAILABLE` | Platform-managed backup configuration cannot be resolved safely. |
| `BACKUP_SERVICE_UNAVAILABLE` | The backup service request failed without returning backend diagnostics. |
| `BACKUP_CAPABILITY_UNAVAILABLE` / `RESTORE_CAPABILITY_UNAVAILABLE` | The requested operation is unavailable for this database. |
| `BACKUP_NOT_FOUND` | The requested backup does not exist. |
| `BACKUP_FAILED` / `RESTORE_FAILED` | The operation failed after validation. |
| `BACKUP_TIMEOUT` / `RESTORE_TIMEOUT` | The operation was started but remains pending past the requested wait. |
| `OPERATION_UNAVAILABLE` / `PEER_OPERATION_FAILED` | A composed workflow capability or peer stage is unavailable. |
| `INTERNAL_ERROR` | The platform could not complete an internal step safely. |

## Workload contract

| Effective container variable | AQSH meaning | Allowed source |
|---|---|---|
| `S3_URL` | S3-compatible endpoint | value, Secret, or ConfigMap |
| `S3_BUCKET` | bucket | value, Secret, or ConfigMap |
| `S3_SUBFOLDER` | complete object prefix | value, Secret, or ConfigMap |
| `S3_BACKUP_REGION` | region | value, Secret, or ConfigMap |
| `S3_ACCESS_KEY` | access-key credential | Secret reference only |
| `S3_ACCESS_SECRET` | secret-key credential | Secret reference only |

`env`, `envFrom.secretRef`, `envFrom.configMapRef`, and `envFrom.prefix` follow
Kubernetes environment precedence: explicit `env` wins; among `envFrom`
entries, the later source wins. Referenced Secrets and ConfigMaps must be in the
MariaDB namespace.

Credential literals and ConfigMap-backed credentials are rejected. The access
key and secret key references may point to different Secrets within one valid
credential bundle, but credential precedence is bundle-aware. If the platform
process supplies any advanced explicit credential-reference override, that
platform-supplied set supersedes the workload pair. Otherwise a workload must
provide both references or neither; AQSH never completes an incomplete workload
pair from a lower-precedence source. When the workload provides neither,
legacy AQSH-wide references and compatibility defaults remain the migration
fallback. Operator-native manifests contain only `accessKeyIdSecretKeyRef` and
`secretAccessKeySecretKeyRef`; direct-client legacy paths read values only
immediately before invoking the storage client.

The resolver reads the MariaDB custom resource and matching Pod specifications
through the Kubernetes API. It never enters the database container to discover
storage configuration. If custom-resource and Pod candidates disagree during a
rollout, resolution fails closed without printing either value.

## Precedence and paths

Non-credential storage fields are resolved independently:

1. explicit platform process override;
2. namespace-resolved, explicitly declared MariaDB workload policy;
3. legacy AQSH-wide deploy-time configuration as a migration fallback;
4. compatibility default.

Credential references follow the same tier order but select a bundle as
described above; they are not mixed one side at a time with an incomplete
workload pair.

The default bucket is `db-backups`, and the default physical prefix is
`mariadb/<namespace>`. Therefore the default physical root is:

```text
s3://db-backups/mariadb/<namespace>/
```

`S3_SUBFOLDER` is the complete prefix. AQSH does not append the namespace to
it. For example, the generic value `team-a/db-main` resolves to:

```text
s3://<resolved-bucket>/team-a/db-main/
```

Physical backup, physical restore, list, and delete all use this same resolved
root. The legacy direct-client physical path stores
`<prefix>/<backup-name>.xb`; current operator object names below the prefix are
operator-managed.

Operator logical backup retains its historical `mariadb-logical/<namespace>`
fallback when the workload does not define `S3_SUBFOLDER`. On the current CRD,
an explicit workload prefix is honored. The legacy logical Backup CRD has no S3
`prefix` field and necessarily writes at bucket root; use a dedicated bucket or
credential boundary when namespace isolation is required there.

## Security and diagnostics

- Internal manifests may contain credential references but are never returned
  through public dry-run or result payloads.
- Credential values and reference metadata are excluded from public results and
  public errors.
- Arbitrary storage-client stderr is not reflected into task results.
- Secret values are not copied into temporary Kubernetes Secrets.
- Reading workload configuration requires `get` on MariaDB, Pod, Secret, and
  ConfigMap resources in the target namespace.
- Resolver failures are translated to stable public reason codes; detailed
  diagnostics must remain redacted and restricted to platform logs.
