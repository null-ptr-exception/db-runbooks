# MariaDB account profiles and existing-account behavior

MariaDB create-account now accepts deployment-defined account_type profiles
(admin, ro, monitor, none) and if_exists modes (error, skip, recreate). This is an
intentional API contract change; migrate task YAML, image, deployment policy and
callers together. Privilege strings, allow_admin_privileges, allow_existing and
allow_global are no longer task inputs.

Default ro requires a database. Global grants are deployment policy, not an
arbitrary wildcard input. Existing accounts now skip by default without changing
credentials or grants. Explicit recreate rotates credentials and replaces direct
grants. Failures always exit nonzero while publishing structured JSON.

The admin username is allowed. System accounts remain protected. An optional
exact Secret/key read allowlist supports application credentials co-located in
Secrets protected against writes. Dry-run returns only a redacted plan and no
password; regressions cover no Kubernetes/Secret/generator calls.

See [the task contract and migration table](../mariadb/create-account.md).
