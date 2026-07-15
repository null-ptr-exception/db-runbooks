# MariaDB Object-Storage Resolution

AQSH resolves backup storage from the selected `MariaDB` workload. The
`S3_*` variables are an AQSH contract carried by `MariaDB.spec.env` or
`MariaDB.spec.envFrom`; they are not mariadb-operator configuration fields.
Both the legacy and current MariaDB CRDs expose these container environment
fields.

## Workload contract

| Effective container variable | AQSH meaning | Allowed source |
|---|---|---|
| `S3_URL` | S3-compatible endpoint | value, Secret, or ConfigMap |
| `S3_BUCKET` | bucket | value, Secret, or ConfigMap |
| `S3_SUBFOLDER` | complete object prefix | value, Secret, or ConfigMap |
| `BACKUP_REGION` | region | value, Secret, or ConfigMap |
| `S3_ACCESS_KEY` | access-key credential | Secret reference only |
| `S3_ACCESS_SECRET` | secret-key credential | Secret reference only |

`env`, `envFrom.secretRef`, `envFrom.configMapRef`, and `envFrom.prefix` follow
Kubernetes environment precedence: explicit `env` wins; among `envFrom`
entries, the later source wins. Referenced Secrets and ConfigMaps must be in the
MariaDB namespace.

Credential literals and ConfigMap-backed credentials are rejected. AQSH keeps
the two credential references independently, so the access key and secret key
may come from different Secrets. Operator-native manifests contain only
`accessKeyIdSecretKeyRef` and `secretAccessKeySecretKeyRef`; direct-client
legacy paths read the values only immediately before invoking the S3 client.

The resolver reads the MariaDB CR and matching Pod specifications through the
Kubernetes API. It never enters the database container to discover storage
configuration. If CR and Pod candidates disagree during a rollout, the task
fails closed without printing either value.

## Precedence and paths

Each field is resolved independently:

1. explicit advanced `BACKUP_*` process override;
2. selected MariaDB workload contract;
3. deploy-time AQSH configuration;
4. compatibility default.

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
root. The legacy hand-rolled physical path stores
`<prefix>/<backup-name>.xb`; current operator object names below the prefix are
operator-managed.

Operator logical backup retains its historical `mariadb-logical/<namespace>`
fallback when the workload does not define `S3_SUBFOLDER`. On the current CRD,
an explicit workload prefix is honored. The legacy logical Backup CRD has no
S3 `prefix` field and necessarily writes at bucket root; use a dedicated bucket
or credential boundary when namespace isolation is required there.

## Security behavior

- Credential values are never included in dry-run manifests, task results, or
  resolver errors.
- Arbitrary S3 client stderr is not reflected into task results.
- Secret values are not copied into temporary Kubernetes Secrets.
- Reading workload configuration requires `get` on MariaDB, Pod, Secret, and
  ConfigMap resources in the target namespace.
