# MariaDB Cross-Cluster Migration AQSH Runbook

`migration/*` moves a MariaDB database from a source instance on one cluster
(or platform) to a destination instance on another, via an external MinIO
bucket as the transfer point and a Vault KV-v2 path as the credential relay.
It is a chain of independent tasks rather than one orchestrated task — each
step is individually retryable, and results from an earlier step (a backup
path, a Vault path) are passed explicitly into the next.

Unlike `backup` / `restore` (which resolve MinIO location and credentials
purely from this deployment's own internal config), every `migration/*` task
that touches MinIO or Vault accepts those as **caller-suppliable inputs**,
falling back to `MINIO_*_DEFAULT` / `VAULT_*` deploy-time config
(`/etc/aqsh/config/mariadb.env`) when omitted — a migration source or
destination is legitimately some *other* MinIO/Vault than this deployment's
own.

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
| 3 | `migration/write-db-env-to-vault` | source | Reads the source's root password (or a dedicated account's password) and writes it to a Vault KV-v2 path — never returned in the task result. |
| 4 | `migration/restore` | target | Restores the target instance from the exact backup `sourcedb-backup` produced. |
| 5 | `migration/read-db-env-from-vault` | target | Reads the Vault path step 3 wrote and materializes it as a Kubernetes Secret in the target namespace. |
| 6 | `migration/check-connection` *(optional but recommended)* | target | Confirms the target can actually reach and authenticate to the source using the relayed credential, and flags a `server_id` collision risk **before** wiring up replication — see below. |
| 7 | `migration/setup-replication` | target | Points the target at the source as its GTID replication master, using the Secret step 5 created; verifies the channel actually comes up healthy, not just that `START SLAVE` was accepted. |

Steps 1–3 run against the source's AQSH endpoint; steps 4–7 run against the
target's. A value written to Vault in step 3 is never visible in any task's
JSON result or log — only the Secret step 5 writes in the target namespace
holds it, and that Secret is what steps 6 and 7 both consume.

**Why step 6 matters:** replication identifies servers by `@@server_id`, and
a collision between the target and the source (or one of the source's own
replicas) breaks replication in a way that's easy to miss until it's already
running — `setup-replication` itself has no way to detect this, since
`CHANGE MASTER`/`START SLAVE` succeed regardless. `check-connection`'s
`server_id` check compares `@@server_id` on both sides (mod 10, assuming at
most 8 replicas per source) and `BLOCK`s before step 7 ever runs if they'd
collide.

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
4 needs.

**3. Relay the source's root password through Vault:**

```bash
curl -sX POST "$SOURCE_AQSH_URL/tasks/migration%2Fwrite-db-env-to-vault" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d '{
    "namespace": "mariadb-1",
    "mdb": "mariadb-1",
    "envs": "MARIADB_ROOT_PASSWORD=root_password",
    "vault_path": "migration/JOB/source"
  }'
```

**4. Restore into the target namespace:**

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
    "dry_run": "false",
    "confirm": "true"
  }'
```

**5. Pull the source's root password back out of Vault, into a target-side Secret:**

```bash
curl -sX POST "$TARGET_AQSH_URL/tasks/migration%2Fread-db-env-from-vault" \
  -H "Authorization: Bearer $TOKEN_B" -H 'Content-Type: application/json' \
  -d '{
    "namespace": "mariadb-dest",
    "vault_path": "migration/JOB/source",
    "secret_name": "migration-JOB-source-creds"
  }'
```

**6. Confirm the target can reach and authenticate to the source (optional but recommended):**

```bash
curl -sX POST "$TARGET_AQSH_URL/tasks/migration%2Fcheck-connection" \
  -H "Authorization: Bearer $TOKEN_B" -H 'Content-Type: application/json' \
  -d '{
    "namespace": "mariadb-dest",
    "ip": "<source-reachable-ip-or-hostname>",
    "repl_password_secret": "migration-JOB-source-creds",
    "repl_password_key": "root_password"
  }'
```

Without `repl_password_secret`, this task authenticates using the *target*
pod's own root password — only correct if source and target happen to share
one. Pass the same relayed Secret step 5 wrote so it actually authenticates
to the source as the source. A `BLOCK`/`SERVER_ID_COLLISION_RISK` result here
means step 7 would wire up a replication channel that's liable to break once
running — resolve the collision (a source/target `server_id` policy is
outside this task's scope) before proceeding.

**7. Point the restored target at the source as its replication master:**

```bash
curl -sX POST "$TARGET_AQSH_URL/tasks/migration%2Fsetup-replication" \
  -H "Authorization: Bearer $TOKEN_B" -H 'Content-Type: application/json' \
  -d '{
    "namespace": "mariadb-dest",
    "host": "<source-reachable-ip-or-hostname>",
    "repl_password_secret": "migration-JOB-source-creds",
    "repl_password_key": "root_password",
    "dry_run": "false",
    "confirm": "true"
  }'
```

`repl_user` defaults to `root` here since the relayed credential is the
source's root password. To replicate as a dedicated (non-root) account
instead, write that account's password in step 3 (`--secret-keys` off its
`mariadb-account-<user>` Secret rather than `--envs` off the pod) and pass
`repl_user` in both steps 6 and 7. A result of `ERROR`/`REPLICATION_NOT_HEALTHY`
means `START SLAVE` was accepted but the channel never actually came up
(bad password, unreachable host, `server_id` collision, ...) — check
`slave_status` in the result for `Last_IO_Error`/`Last_SQL_Error`.

## Notes

- **Vault AppRole is deploy-time-only, on both sides.** `VAULT_ADDR` /
  `VAULT_MOUNT` / `VAULT_ROLE_ID` / `VAULT_SECRET_ID` are never task inputs —
  a caller cannot redirect a write to a different Vault identity than the
  one the deployment was provisioned with. If unset, both Vault tasks fail
  clearly with `VAULT_NOT_CONFIGURED` rather than silently doing nothing.
- **Re-running step 5 updates its Secret in place**, not a collision — unlike
  `restore`'s randomly-suffixed *temporary* credential Secret, the Secret
  `read-db-env-from-vault` writes is meant to persist and be re-fetched, so a
  rotated Vault value can be refreshed with a second call before re-running
  step 6.
- **Nothing in this chain is reversible from inside AQSH.** Step 4 never
  overwrites an existing target (same guarantee as `restore`), and step 6
  only ever configures a replication channel — it does not delete or drop
  anything. But there is no single "undo migration" task; treat each step's
  own guardrails (dry-run defaults, `confirm=true` gates) as the safety net.
