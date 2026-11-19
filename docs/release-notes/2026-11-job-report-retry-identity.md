# Breaking: MariaDB job reporting identity and runtime parameter names

Upgrade reporting deployments in this order:

1. Add the nullable task identity column and full-column unique index to the
   configured report table **before upgrading the runbook image**. For example:

   ```sql
   ALTER TABLE operations.job_history
     ADD COLUMN task_id VARCHAR(191) CHARACTER SET ascii COLLATE ascii_bin NULL,
     ADD UNIQUE KEY job_history_task_id (task_id);
   ```

   Substitute the configured database/table names. Historical rows are left
   unchanged. No automatic migration or backfill runs. aqsh supplies
   `AQSH_TASK_ID` on each execution; without this schema, the upgraded image
   skips reporting with a warning while preserving the task outcome.
2. Update queries and dashboards filtering on `job_name`: the default changes
   from `max_connections` to `set-runtime-param/max_connections`. Other nonempty
   parameter names use `set-runtime-param/<param>`. An explicit per-call
   `job_name: max_connections` preserves the old label for existing callers.
   Ensure the column can hold the longer default names.
3. Upgrade the runbook image and its task configuration together.

Reporting now covers nonempty runtime parameter requests, including unknown
names or typos rejected with `PARAM_NOT_ALLOWED`; rejected requests record
`Failed` without changing parameters. Listing and dry-run remain excluded.
Sequential retries sharing an aqsh task ID reuse one summary row, and successful
rows remain terminal on redelivery. Standalone invocations without a task ID
retain per-invocation identity.

See the [reporting contract and migration](../lib/job-report.md#retry-identity-and-schema-migration)
for schema validation, sequential-retry scope, and best-effort reporting limits.
