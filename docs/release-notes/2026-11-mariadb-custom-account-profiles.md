# Custom MariaDB account profiles and grants-only updates

Deployments can define named privilege profiles through
`MARIADB_ACCOUNT_PROFILES_JSON_DEFAULT` in `mariadb.env`. Each request selects a
profile using the existing `account_type` input, so different accounts can use
different privilege combinations without exposing raw SQL or privilege lists
as public inputs.

A configured registry is authoritative: list every permitted profile, including
`ro` if callers use the default input. Unknown names and malformed registry
entries fail before cluster access. The reserved `none` profile remains a login
without data privileges. When the registry is unset, the existing admin, ro,
monitor and none profiles and their deployment settings retain their behavior.

For an existing account, `if_exists=update_grants` replaces direct grants with
the selected profile, verifies effective grants, and compares SHOW CREATE USER
before and after to verify authentication and expiry were preserved. Password
and expiry inputs are ignored; no password is generated, read from an account
Secret, encrypted or returned. Missing accounts fail with ACCOUNT_NOT_FOUND.
Role, PROXY and unrecognized grants remain blocked before mutation.

Callers must recognize GRANTS_UPDATED and UNCHANGED as successful results. The
password_expire_mode and validity_days result fields are null in update_grants
mode because this mode does not apply those settings. A matching profile is a
verified no-op with an empty SQL plan and mutation_applied=false.

Grant replacement is not transactional. Errors can leave partial grants and do
not imply rollback. Serialize changes to the same account; GRANT sessions disable
implicit account creation if another operation removes the target account.

Update the task image, task YAML, deployment configuration and callers together.
See [the task contract](../mariadb/create-account.md) for registry examples,
status codes and migration details.
