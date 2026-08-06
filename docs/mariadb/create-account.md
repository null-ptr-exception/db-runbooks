# Task: create-account

Create or recreate a MariaDB account with an explicit grant scope, native
password expiry, and the same password-delivery contract as MongoDB
`create-account`.

## Safety defaults

- `dry_run=true`; a mutation requires `dry_run=false` and `confirm=true`.
- Existing accounts fail with `ACCOUNT_ALREADY_EXISTS` unless
  `allow_existing=true`.
- Recreating an account changes its credential, revokes all existing grants,
  applies only the requested effective grant, and verifies it with
  `SHOW GRANTS`.
- Generated credentials are returned once as plaintext or encrypted for the
  caller. They are not persisted to a task-owned Kubernetes Secret.
- A caller-provided Secret is a read-only input. This task never creates,
  patches, or deletes it, and refuses protected machinery/root Secrets.
- Password values never appear in task logs or error results. The only allowed
  plaintext result is `delivery_payload.password` when
  `password_delivery_mode=one_time_plaintext`.
- Every result includes `mutation_applied`. It remains `false` until MariaDB
  accepts the credential change; a later grant or verification error returns
  `mutation_applied=true` so callers can distinguish an explicit partial result
  from a pre-mutation failure.

## Endpoint

```text
POST /tasks/create-account
```

The task is served by `aqsh-mariadb`.

## Scope and privileges

With a database, the task applies database-scoped grants:

```json
{
  "namespace": "mariadb-1",
  "database": "app_db",
  "username": "app_user",
  "privileges": "SELECT,INSERT"
}
```

Without `database`, the only permitted effective grant is `SELECT ON *.*`.
Omitted `privileges` defaults to `SELECT`; any other privilege or privilege
combination fails `INVALID_INPUT`.

```json
{
  "namespace": "mariadb-1",
  "username": "report_reader"
}
```

Important: MariaDB `SELECT ON *.*` includes system schemas. Use this scope only
when the account is allowed to read those schemas too. Pass a specific database
for ordinary application isolation. Explicit `database="*"` or `"*.*"` is
rejected; omit the field to request the guarded all-database read-only scope.

The database-scoped allowlist is `SELECT`, `INSERT`, `UPDATE`, `DELETE`,
`CREATE`, `ALTER`, `INDEX`, `EXECUTE`, and `SHOW VIEW`. Broad/admin privileges
remain gated by `allow_admin_privileges=true`; that gate never relaxes the
all-database SELECT-only rule.

Dry-run and final results expose the effective contract:

```json
{
  "database": null,
  "scope": {"kind": "all_databases_read_only", "grant": "*.*"},
  "privileges": ["SELECT"]
}
```

## Existing accounts

`allow_existing=false` is the default and returns:

```json
{"status":"ERROR","reason_code":"ACCOUNT_ALREADY_EXISTS"}
```

With `allow_existing=true`, the task uses `ALTER USER` to replace the password,
then `REVOKE ALL PRIVILEGES, GRANT OPTION`, applies the requested grant, and
verifies it. A successful replacement returns `RECREATED` /
`ACCOUNT_RECREATED`. Prior broader grants are not retained; a later grant
failure therefore leaves the account fail-closed rather than over-privileged.

## Password generation

| Input | Default | Rule |
|---|---:|---|
| `password_length` | `24` | Minimum `12` |
| `password_special_chars` | `!@#%^*_-+=.` | Quotes, backslash, spaces, and control characters are rejected |
| `password_special_max` | `4` | Non-negative integer |

The shared MongoDB generator guarantees at least one uppercase letter, one
lowercase letter, and one digit. Special characters are drawn only from the
configured set, never exceed `password_special_max`, and are not required to
appear.

## Password delivery

### One-time plaintext (default)

```json
{
  "delivery_payload": {
    "mode": "one_time_plaintext",
    "password": "<generated>"
  }
}
```

Capture this response securely; the task does not retain the generated value.

### Caller-encrypted payload

Set `password_delivery_mode=encrypted_payload` and provide an ASCII-armored or
base64-encoded armored `recipient_pgp_pubkey`:

```json
{
  "delivery_payload": {
    "mode": "encrypted_payload",
    "recipient_key_fingerprint": "...",
    "content_type": "application/pgp-encrypted",
    "ciphertext": "-----BEGIN PGP MESSAGE-----\n..."
  }
}
```

Encryption is completed before the account is mutated, so an unusable recipient
key fails with `DELIVERY_ENCRYPT_FAILED` without changing the account.

### Caller-provided Secret

Set `password_secret_name` and optionally `password_secret_key` (default
`password`) to use a fixed password already stored in the target namespace:

```json
{
  "delivery_payload": {
    "mode": "caller_provided_secret",
    "secret_name": "svc-account-credentials",
    "secret_key": "password"
  }
}
```

`password_secret_name` is mutually exclusive with encrypted/generated delivery
options. The task requires only Secret `get` for this path. The gateway's shared
Role may still have `create`, `patch`, and `delete` because the separate
`secrets/*` family needs them; `create-account` does not use those verbs.

## Native MariaDB password expiry

| `password_expire_mode` | Additional SQL | `validity_days` |
|---|---|---|
| `first_login` (default) | `PASSWORD EXPIRE` | forbidden |
| `interval` | `PASSWORD EXPIRE INTERVAL <n> DAY` | required, positive integer |
| `never` | `PASSWORD EXPIRE NEVER` | forbidden |
| `default` | `PASSWORD EXPIRE DEFAULT` | forbidden |

This is native MariaDB state. There is no MongoDB-style policy collection,
scheduled reconciliation, or deletion on expiry.

Non-interactive service accounts—especially accounts using caller-provided
Secrets—normally need `password_expire_mode=never`. An expired-password login
requires a client and server configuration compatible with MariaDB's
`disconnect_on_expired_password` flow; otherwise the client may be disconnected
before it can change the password.

## Inputs

| Field | Required | Default | Purpose |
|---|---|---|---|
| `namespace` | yes | — | Target namespace |
| `resource` | no | `mariadb` | MariaDB CR kind |
| `mdb` | no | auto-detect | CR/StatefulSet name |
| `container` | no | `mariadb` | Database container |
| `database` | no | omitted | Database scope; omission means guarded `*.*` read-only |
| `username` | yes | — | MariaDB username |
| `host` | no | `%` | MariaDB account host |
| `privileges` | no | `SELECT` | Comma-separated privileges |
| `allow_existing` | no | `false` | Replace credential and grants |
| `password_length` | no | `24` | Generated length |
| `password_special_chars` | no | `!@#%^*_-+=.` | Generated special-character set |
| `password_special_max` | no | `4` | Generated special-character maximum |
| `password_delivery_mode` | no | `one_time_plaintext` | Generated delivery mode |
| `recipient_pgp_pubkey` | conditional | empty | Required for encrypted delivery |
| `password_secret_name` | no | empty | Existing fixed-password Secret |
| `password_secret_key` | no | `password` | Password data key |
| `password_expire_mode` | no | `first_login` | Native expiry mode |
| `validity_days` | conditional | empty | Required only for `interval` |
| `dry_run` | no | `true` | Return redacted plan only |
| `confirm` | no | `false` | Required for mutation |
| `allow_admin_privileges` | no | `false` | Database-scoped admin privilege gate |

## Examples

Database-scoped service account using an existing Secret:

```json
{
  "namespace": "mariadb-1",
  "database": "orders",
  "username": "orders_service",
  "privileges": "SELECT,INSERT,UPDATE",
  "password_secret_name": "orders-db-credentials",
  "password_expire_mode": "never",
  "dry_run": "false",
  "confirm": "true"
}
```

Recreate a global reporting account and encrypt the new password:

```json
{
  "namespace": "mariadb-1",
  "username": "report_reader",
  "allow_existing": "true",
  "password_delivery_mode": "encrypted_payload",
  "recipient_pgp_pubkey": "-----BEGIN PGP PUBLIC KEY BLOCK-----\n...",
  "password_expire_mode": "interval",
  "validity_days": "30",
  "dry_run": "false",
  "confirm": "true"
}
```

## Breaking-change migration

This contract intentionally replaces the old generated-Secret API:

| Removed old field/result | Replacement |
|---|---|
| `generate_password=true` | Omit `password_secret_name`; choose a delivery mode |
| `generate_password=false` | Set `password_secret_name` / `password_secret_key` |
| `allow_global=true` with `database="*.*"` | Omit `database`; only `SELECT` is accepted |
| result `password_secret` | result `delivery_payload` |
| existing result `UNCHANGED/ACCOUNT_EXISTS` | error by default, or `allow_existing=true` replacement |

Callers must capture `one_time_plaintext` exactly once or use
`encrypted_payload`. No task-owned password Secret is created after migration.
