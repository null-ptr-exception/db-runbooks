# MariaDB Cross-Cluster Migration AQSH Runbook

`migration/*` moves a MariaDB database from a source instance on one cluster
(or platform) to a destination instance on another, via an external MinIO
bucket as the transfer point and a Vault KV-v2 path as the credential relay.
It is a chain of independent tasks rather than one orchestrated task — each
step is individually retryable, and results from an earlier step (a backup
path, a Vault path) are passed explicitly into the next.

Unlike `backup` / `restore` (which resolve MinIO location and credentials
purely from this deployment's own internal config), every `migration/*` task
that touches MinIO accepts those fields as **caller-suppliable inputs**,
falling back to `MINIO_*_DEFAULT` deploy-time config
(`/etc/aqsh/config/mariadb.env`) when omitted — a migration source or
destination is legitimately some *other* MinIO than this deployment's own.
Vault AppRole config is different: it is **deployment-only, never a task
input** — see the Notes section below.

## Scope

- **Cross-cluster by design.** The chain below shows source on `cluster-a`
  and target on `cluster-b`, but nothing about it assumes two clusters
  specifically — the source and target could be the same cluster in
  different namespaces, or entirely different platforms, as long as both
  sides can reach the same MinIO bucket and Vault path.
- **Physical backup only.** Like `restore`/`physical-backup`, this is a
  mariabackup physical restore — same MariaDB version required on both
  sides, replicas cloned byte-for-byte. Logical (`mariadb-dump`) migration is
  out of scope here.
- **The destination namespace needs a placeholder MariaDB instance running
  before migration starts.** `migration/restore` auto-detects `image`/
  `storage_size` from an existing instance in the namespace when they're
  omitted, and `migration/check-connection` (step 5, below) needs a pod to
  `kubectl exec` into — neither works against a namespace with nothing
  running in it yet. `tests/mariadb/migration_e2e.bats` sets this up via
  `deploy_throwaway_mariadb`.
- **The destination's `server_id` must already be distinct from the
  source's, independent of migration.** This is a prerequisite, not
  something migration arranges: step 5's `server_id` check runs against the
  placeholder instance (restore always creates a new, differently-named
  instance and never reuses it), so it's only representative of the
  eventual restored instance if `server_id` is assigned at the
  cluster/namespace level rather than randomly per-instance. If your
  mariadb-operator assigns it per-instance instead, re-verify `server_id`
  after step 6 rather than relying solely on step 5.
- **Root or a dedicated replication account.** `setup-replication`'s
  `repl_user` defaults to `root`. `repl_password_secret` is required for
  every real (`dry_run=false`) run regardless of `repl_user` — source and
  target legitimately have different root passwords in a real migration, so
  there is no safe default credential to fall back to. The target pod's own
  `MARIADB_ROOT_PASSWORD` is used as `MASTER_PASSWORD` only as a `repl_user:
  root`, `dry_run=true` SQL-plan-preview convenience, never on a real run.

## The chain

| Step | Task | Runs on | Purpose |
|------|------|---------|---------|
| 1 | `migration/preflight` | source (and, optionally, target) | Confirms the pod is reachable and can reach the migration MinIO bucket before anything is moved. |
| 2 | `migration/sourcedb-backup` | source | Takes a physical (mariabackup) backup of the source to the migration MinIO bucket. |
| 3 | `migration/export-db-env-to-vault` | source | Reads the source's root password (or a dedicated account's password) and writes it to a Vault KV-v2 path — never returned in the task result. |
| 4 | `migration/import-db-env-from-vault` | target | Reads the Vault path step 3 wrote and materializes it as a Kubernetes Secret in the target namespace. |
| 5 | `migration/check-connection` | target | Confirms the target can actually reach and authenticate to the source using the relayed credential, and flags a `server_id` collision risk **before** committing to a restore — see below. |
| 6 | `migration/restore` | target | Restores the target instance from the exact backup `sourcedb-backup` produced. Point `root_secret_name`/`root_secret_key` at the Secret step 4 wrote so the restored CR's root-password Secret actually matches the physically-restored data. |
| 7 | `migration/setup-replication` | target | Points the target at the source as its GTID replication master, using the Secret step 4 created; verifies the channel actually comes up healthy, not just that `START SLAVE` was accepted. |

Steps 1–3 run against the source's AQSH endpoint; steps 4–7 run against the
target's. A value written to Vault in step 3 is never visible in any task's
JSON result or log — only the Secret step 4 writes in the target namespace
holds it, and that Secret is what steps 5, 6, and 7 all consume.

**Why step 5 runs before restore:** replication identifies servers by
`@@server_id`, and a collision between the target and the source (or one of
the source's own replicas) breaks replication in a way that's easy to miss
until it's already running — `setup-replication` itself has no way to
detect this, since `CHANGE MASTER`/`START SLAVE` succeed regardless.
`check-connection`'s `server_id` check compares `@@server_id` on both sides
(mod 10, assuming at most 8 replicas per source) and `BLOCK`s if they'd
collide — checking this *before* restore (rather than after, as an
afterthought right before step 7) means a doomed migration fails fast,
before spending the time on a physical restore.

**Why step 6 needs `root_secret_name`/`root_secret_key`:** a physical
restore carries over the source's actual database root password (it's baked
into the restored data files, not set by the operator). mariadb-operator
authenticates against the live DB using the Secret referenced by
`rootPasswordSecretKeyRef` as part of computing the restored CR's Ready
condition — if that Secret still holds some other (fresh/default) password
instead of the source's real one, the restored instance can fail to ever
reach Ready. Pointing `root_secret_name`/`root_secret_key` at the Secret
step 4 wrote keeps them in sync from the start.

## Examples

Substitute `SOURCE_AQSH_URL` / `TOKEN_A` for the source cluster's endpoint
and token, `TARGET_AQSH_URL` / `TOKEN_B` for the target's (see the root
README's *Task API Example* for how to obtain a token from `test-client`).
`JOB` below is any caller-chosen identifier for this migration run — it only
needs to be unique enough that its Vault path doesn't collide with another
in-flight migration.

**1. Preflight the source:**

```bash
curl -sX POST "$SOURCE_AQSH_URL/tasks/migration%2Fpreflight" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1" }'
```

**2. Back up the source to the migration MinIO bucket:**

```bash
curl -sX POST "$SOURCE_AQSH_URL/tasks/migration%2Fsourcedb-backup" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d '{
    "namespace": "mariadb-1",
    "minio_endpoint": "http://minio.kind-b.test:30080",
    "minio_access_key": "minioadmin",
    "minio_secret_key": "minioadmin-changeme-prod",
    "minio_bucket": "db-backups",
    "dry_run": "false",
    "confirm": "true"
  }'
```

The result's `backup.prefix` (e.g. `mariadb/mariadb-1`) and `backupName`
(e.g. `mariadb-1-migration-20260809120000`) fields combine as
`<prefix>/<backupName>` — that concatenation is the `backup_file` value step
6 needs.

**3. Relay the source's root password through Vault:**

```bash
curl -sX POST "$SOURCE_AQSH_URL/tasks/migration%2Fexport-db-env-to-vault" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d '{
    "namespace": "mariadb-1",
    "mdb": "mariadb-1",
    "envs": "MARIADB_ROOT_PASSWORD=root_password",
    "vault_path": "migration/JOB/source"
  }'
```

**4. Pull the source's root password back out of Vault, into a target-side Secret:**

Renaming the Vault key `root_password` to the Secret key `password` here
means the *same* secret + key name directly serves steps 5, 6, and 7 below,
with no renaming juggling:

```bash
curl -sX POST "$TARGET_AQSH_URL/tasks/migration%2Fimport-db-env-from-vault" \
  -H "Authorization: Bearer $TOKEN_B" -H 'Content-Type: application/json' \
  -d '{
    "namespace": "mariadb-dest",
    "vault_path": "migration/JOB/source",
    "secret_name": "migration-JOB-source-creds",
    "keys": "root_password=password"
  }'
```

**5. Confirm the target can reach and authenticate to the source (required — gates the restore below):**

```bash
curl -sX POST "$TARGET_AQSH_URL/tasks/migration%2Fcheck-connection" \
  -H "Authorization: Bearer $TOKEN_B" -H 'Content-Type: application/json' \
  -d '{
    "namespace": "mariadb-dest",
    "ip": "<source-reachable-ip-or-hostname>",
    "repl_password_secret": "migration-JOB-source-creds",
    "repl_password_key": "password"
  }'
```

This execs into whatever MariaDB instance is currently running in
`mariadb-dest` (the placeholder — see Scope above), not the not-yet-created
restored instance. Without `repl_password_secret`, this task authenticates
using the *target* pod's own root password — only correct if source and
target happen to share one. A `BLOCK`/`SERVER_ID_COLLISION_RISK` result here
means proceeding would eventually wire up a replication channel that's
liable to break — resolve the collision (a source/target `server_id` policy
is outside this task's scope) before continuing to step 6.

**6. Restore into the target namespace:**

```bash
curl -sX POST "$TARGET_AQSH_URL/tasks/migration%2Frestore" \
  -H "Authorization: Bearer $TOKEN_B" -H 'Content-Type: application/json' \
  -d '{
    "namespace": "mariadb-dest",
    "backup_file": "mariadb/mariadb-1/mariadb-1-migration-20260809120000",
    "minio_endpoint": "http://minio.kind-b.test:30080",
    "minio_access_key": "minioadmin",
    "minio_secret_key": "minioadmin-changeme-prod",
    "minio_bucket": "db-backups",
    "image": "mariadb:11.4",
    "storage_size": "1Gi",
    "root_secret_name": "migration-JOB-source-creds",
    "root_secret_key": "password",
    "dry_run": "false",
    "confirm": "true"
  }'
```

`root_secret_name`/`root_secret_key` point the restored CR's
`rootPasswordSecretKeyRef` at the same Secret step 4 wrote — see "Why step 6
needs `root_secret_name`/`root_secret_key`" above. Omit them to keep the
platform's own default (`mariadb`/`password`), appropriate only when source
and target are known to already share a root password.

**7. Point the restored target at the source as its replication master:**

```bash
curl -sX POST "$TARGET_AQSH_URL/tasks/migration%2Fsetup-replication" \
  -H "Authorization: Bearer $TOKEN_B" -H 'Content-Type: application/json' \
  -d '{
    "namespace": "mariadb-dest",
    "host": "<source-reachable-ip-or-hostname>",
    "repl_password_secret": "migration-JOB-source-creds",
    "repl_password_key": "password",
    "dry_run": "false",
    "confirm": "true"
  }'
```

`repl_user` defaults to `root` here since the relayed credential is the
source's root password. To replicate as a dedicated (non-root) account
instead, write that account's password in step 3 (`--secret-keys` off its
`mariadb-account-<user>` Secret rather than `--envs` off the pod) and pass
`repl_user` in both steps 5 and 7. A result of `ERROR`/`REPLICATION_NOT_HEALTHY`
means `START SLAVE` was accepted but the channel never actually came up
(bad password, unreachable host, `server_id` collision, ...) — check
`slave_status` in the result for `Last_IO_Error`/`Last_SQL_Error`.

## Notes

- **Vault AppRole is deploy-time-only, on both sides.** `VAULT_ADDR` /
  `VAULT_MOUNT` / `VAULT_ROLE_ID` / `VAULT_SECRET_ID` are never task inputs —
  a caller cannot redirect a write to a different Vault identity than the
  one the deployment was provisioned with. If unset, both Vault tasks fail
  clearly with `VAULT_NOT_CONFIGURED` rather than silently doing nothing.
- **Re-running step 4 updates its Secret in place**, not a collision — unlike
  `restore`'s randomly-suffixed *temporary* credential Secret, the Secret
  `import-db-env-from-vault` writes is meant to persist and be re-fetched, so a
  rotated Vault value can be refreshed with a second call before re-running
  step 5.
- **Nothing in this chain is reversible from inside AQSH.** Step 6 never
  overwrites an existing target (same guarantee as `restore`), and step 5
  only ever checks connectivity — it does not delete or drop anything, and
  neither does step 7, which only ever configures a replication channel.
  But there is no single "undo migration" task; treat each step's own
  guardrails (dry-run defaults, `confirm=true` gates) as the safety net.
