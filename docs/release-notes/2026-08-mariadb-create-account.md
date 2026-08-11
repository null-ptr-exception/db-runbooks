# MariaDB create-account contract alignment

MariaDB `create-account` now aligns its password generation and delivery API
with MongoDB `create-account`. This is an intentional breaking change.

## Changed

- `database` is optional. Omission means the guarded read-only grant
  `SELECT ON *.*`; this includes MariaDB system schemas.
- Existing accounts fail by default. `allow_existing=true` rotates the
  credential and replaces all prior grants, returning
  `RECREATED/ACCOUNT_RECREATED` after `SHOW GRANTS` verification.
- Generated passwords use the shared length/special-character policy and are
  returned through `delivery_payload` as one-time plaintext or recipient-PGP
  ciphertext.
- Existing caller-owned Secrets can supply a fixed password and are read-only.
- MariaDB-native `first_login`, `interval`, `never`, and `default` password
  expiry modes are available. No policy reconciler was added.

## Removed

- Request fields `generate_password` and `allow_global`.
- Generated `password_secret` result and task-owned password Secret writes.

See [the migration table](../mariadb/create-account.md#breaking-change-migration)
for request and result replacements.
