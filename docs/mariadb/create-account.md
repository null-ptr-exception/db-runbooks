# Task: create-account

Create, skip, recreate, or update the grants of a MariaDB account using a
deployment-defined privilege profile and native password expiry. Password generation and delivery use the
same contract as MongoDB create-account.

## Safety defaults

- `dry_run=true`; mutation requires `dry_run=false` and `confirm=true`.
- `account_type=ro` requires an explicit database by default. Omitting a database
  no longer silently exposes all schemas, including system schemas.
- `if_exists=skip` leaves an existing account untouched and returns `SKIPPED` /
  `ACCOUNT_EXISTS`, `mutation_applied=false`, an empty SQL plan and no credential.
  The requested profile is not verified or reconciled when skipped.
- ERROR exits 2 and BLOCKED exits 1, after publishing structured JSON. Successful
  READY/CREATED/RECREATED/SKIPPED/GRANTS_UPDATED/UNCHANGED results exit 0. `--strict-exit` remains a no-op
  compatibility flag. An execution-query HTTP 200 only means the query succeeded;
  check execution state and the structured task result for operation outcome.
- Dry-run validates the request and deployment policy, but does not contact
  Kubernetes or MariaDB, read a Secret, generate a password, or encrypt anything.
  Its plan contains `<redacted>` and `delivery_payload=null`. Live target,
  account-existence, Secret access, server-version and encryption checks occur
  only during confirmed execution.
- `mutation_applied` becomes true after an acknowledged CREATE/ALTER USER, or a
  successful REVOKE in grants-only mode. A later
  revoke, grant, or verification failure remains an ERROR with partial mutation
  explicitly reported. Its `delivery_payload` retains the prepared credential in
  the selected mode: one-time plaintext, encrypted payload, or Secret reference.
  Preserve error results securely; an ERROR does not imply credential rollback.
  `ACCOUNT_MUTATION_FAILED` also includes the prepared delivery because a client
  error cannot prove whether CREATE/ALTER reached the server. In that case,
  `mutation_applied=false` means success was not acknowledged; inspect the account
  before retrying rather than assuming its old credential still applies.

## Endpoint

```text
POST /tasks/create-account
```

The task is served by `aqsh-mariadb`; submission returns 202 and an execution ID.

## Account profiles and scopes

Each account selects a deployment-defined profile name through `account_type`.
Names contain 1–63 lowercase letters, digits, underscores or dashes and start
with a letter. Callers cannot supply privilege lists, raw SQL or wildcard scopes.
The username and profile name are independent: an account named admin does not
itself gain administrative privileges. Root, mysql and mariadb.sys remain
protected, together with the additional deployment protection list.

When no custom registry is configured, these legacy profiles remain available:

| Profile | Default database privileges | Default global privileges |
|---|---|---|
| `admin` | Explicit database management list below | none |
| `ro` | SELECT | none |
| `monitor` | none | PROCESS, BINLOG MONITOR, SLAVE MONITOR |
| `none` | none | none (native USAGE only) |

The admin database list is SELECT, INSERT, UPDATE, DELETE, CREATE, DROP,
REFERENCES, INDEX, ALTER, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE,
CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, EVENT, TRIGGER, and
DELETE HISTORY. It does not use ALL, SUPER, FILE or grant delegation by default.

A profile may contain both database and global grants. Database privileges require
`database`; global grants always use `*.*` and cannot accidentally be applied to
`database.*`. A profile with no database privileges rejects an unused database
input. Database `_` wildcards are escaped before GRANT. Results expose each
resolved grant in `grants`, plus the selected `account_type` and `if_exists`.
For mixed scopes the compatibility `scope` field has `kind=mixed` and an empty
`grant`; use `grants` for the effective plan.

## Deployment policy

Set policy in the mounted `/etc/aqsh/config/mariadb.env`. The registry is internal
configuration, not a task input:

```bash
MARIADB_ACCOUNT_PROFILES_JSON_DEFAULT='{
  "ro": {"database_privileges": ["SELECT"]},
  "app_writer": {"database_privileges": ["SELECT", "INSERT", "UPDATE"]},
  "report_reader": {"database_privileges": ["SELECT"]},
  "ops_monitor": {"global_privileges": ["PROCESS", "BINLOG MONITOR", "SLAVE MONITOR"]}
}'
```

For example, account_a can select app_writer on orders while account_b selects
report_reader on reports. Adding a new profile does not change existing accounts;
only an explicit create, recreate or grants-only update applies its policy.

A configured registry is an authoritative allowlist, not an overlay. Include all
permitted names, including `ro` if callers rely on the default input. Legacy
ADMIN/RO/MONITOR privilege variables are ignored when a registry is configured.
An undefined name, invalid name or malformed registry fails with INVALID_INPUT
before cluster access. An explicitly empty registry `{}` permits only `none`;
an empty string is invalid and does not fall back to defaults.

Each entry accepts only `database_privileges` and `global_privileges` arrays of
privilege names; omitted arrays mean no grants at that level. Empty entries are
valid zero-grant profiles. `none` is reserved, always has native USAGE only, and
cannot be redefined in the registry. Profile names are case-sensitive. Privilege
names are normalized to uppercase.

With the registry **unset**, the existing
`MARIADB_ACCOUNT_<ADMIN|RO|MONITOR>_DATABASE_PRIVILEGES_DEFAULT` and
`MARIADB_ACCOUNT_<ADMIN|RO|MONITOR>_GLOBAL_PRIVILEGES_DEFAULT` comma-separated
lists retain their behavior. Unset variables use the legacy defaults above;
explicitly empty lists disable grants at that level.

Global administrative privileges remain explicit deployment policy. A global
SELECT profile includes system schemas; a database-scoped profile requires the
caller to select a database and never silently grants access to every schema.

Only fixed, recognized privilege names are accepted; environment values are never
raw SQL. Global-only privileges at database scope and SQL injection text are
rejected. ALL/ALL PRIVILEGES are intentionally unsupported in policy; enumerate
the privileges. GRANT OPTION is supported explicitly and emitted as WITH GRANT
OPTION. Confirmed execution checks SHOW PRIVILEGES before credential mutation;
a missing privilege returns UNSUPPORTED_PRIVILEGE. REPLICATION CLIENT is matched
as the BINLOG MONITOR alias for version compatibility.

`MARIADB_ACCOUNT_PROTECTED_USERS_DEFAULT` adds/replaces the additional protected
username list (default mariadb,system,sys); the core root/mysql/mariadb.sys block
cannot be removed. Matching is case-insensitive.

## Existing accounts

| `if_exists` | Existing account behavior |
|---|---|
| `skip` (default) | No credential or grant changes, no password generation/delivery |
| `error` | ERROR / ACCOUNT_ALREADY_EXISTS, exit 2 |
| `recreate` | Check existing grants, then ALTER USER, REVOKE ALL PRIVILEGES and GRANT OPTION, apply profile and verify |
| `update_grants` | Existing accounts only; replace direct grants and preserve authentication/expiry, or return UNCHANGED if already matched |

The error, skip and recreate modes create a missing account. The update_grants
mode returns ERROR / ACCOUNT_NOT_FOUND, exit 2, for a missing account. Recreate
replaces direct grants and credentials; it is not DROP USER plus CREATE USER. MariaDB role assignments are
not removed by REVOKE ALL. Existing role, PROXY, or unrecognized grant statements
return BLOCKED / `UNSUPPORTED_EXISTING_GRANTS`, exit 1, before reading or generating
an account password or changing credentials/grants. Failure to read existing
grants returns ERROR / `SQL_VERIFY_FAILED`, exit 2, with no mutation. Resolve
non-revocable grants separately before requesting recreation or a grants-only
update. Revoke/grant failures after credential changes can leave partial state;
error results retain
the selected password delivery payload for recovery.
Concurrent CREATE races return ERROR; a recovery payload does not prove that its
password was applied. Serialize all changes to the same user/host account at the
caller; this task does not provide a distributed account lock.

### Update grants while preserving credentials

`if_exists=update_grants` reconciles the selected profile by replacing **all direct
grants**, including grants on other databases. It does not merge privileges into
the old set. It never issues CREATE/ALTER/DROP USER or authentication clauses,
and ignores password generation, Secret, delivery and expiry inputs. The result
has `delivery_payload=null`, `password_expire_mode=null` and `validity_days=null`.

The task validates existing grants and server privilege support before mutation.
If effective grants already match, it returns UNCHANGED /
ACCOUNT_GRANTS_UNCHANGED, exit 0, with `mutation_applied=false` and an empty plan.
Otherwise it reads SHOW CREATE USER, revokes direct privileges, applies the
profile, then verifies both grants and the unchanged account definition. Success
returns GRANTS_UPDATED / ACCOUNT_GRANTS_UPDATED, exit 0. If the account definition
changes during the operation, it returns ERROR / ACCOUNT_STATE_CHANGED rather
than claiming credentials were preserved. Account definitions and password hashes
are never included in results.

Each GRANT session enables NO_AUTO_CREATE_USER, so a concurrently removed target
cannot be implicitly recreated without authentication. See the
[MariaDB GRANT contract](https://mariadb.com/docs/server/reference/sql-statements/account-management-sql-statements/grant#implicit-account-creation).
Grant replacement is not transactional and can temporarily remove access. A
failed REVOKE acknowledgement leaves the grant state uncertain; later errors
can leave a partial profile. `mutation_applied` records acknowledged mutations,
not rollback or atomicity. Grants-only errors never return password material.

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

A separate read policy, `MARIADB_ACCOUNT_PASSWORD_SECRET_REFS_DEFAULT`, accepts
comma/space-separated exact `secret-name/key` references. When configured, only
those pairs may be read, including an application key co-located in a Secret
protected against writes. This does not change secrets/* write/delete protection.
Do not list root credential keys as account-password sources.

When unset or empty, the previous default applies: non-protected Secrets may be
read; the target name, mariadb, and the secrets/* protected list are refused.
Secret values are never returned for caller-provided sources; delivery returns
only the reference. For example:

```bash
MARIADB_ACCOUNT_PASSWORD_SECRET_REFS_DEFAULT='shared-db-credentials/monitor.password,orders-credentials/password'
```

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
| namespace | yes | — | Target namespace |
| resource | no | mariadb | MariaDB CR kind |
| mdb | no | auto-detect | CR/StatefulSet name |
| container | no | mariadb | Database container |
| database | profile-dependent | empty | Target of database-scoped profile grants |
| username | yes | — | MariaDB username |
| host | no | % | MariaDB account host |
| account_type | no | ro | Named deployment profile; legacy admin/ro/monitor/none when registry is unset |
| if_exists | no | skip | error, skip, recreate, update_grants |
| password_length | no | 24 | Generated length |
| password_special_chars | no | !@#%^*_-+=. | Generated special-character set |
| password_special_max | no | 4 | Generated special-character maximum |
| password_delivery_mode | no | one_time_plaintext | Generated delivery mode |
| recipient_pgp_pubkey | conditional | empty | Required for encrypted delivery |
| password_secret_name | no | empty | Existing fixed-password Secret |
| password_secret_key | no | password | Password data key |
| password_expire_mode | no | first_login | Native expiry mode |
| validity_days | conditional | empty | Required only for interval |
| dry_run | no | true | Return redacted plan only |
| confirm | no | false | Required for mutation |

## Examples

Create a database administrator named admin:

```json
{
  "namespace": "mariadb-1",
  "database": "orders",
  "username": "admin",
  "account_type": "admin",
  "dry_run": "false",
  "confirm": "true"
}
```

Create or recreate a non-interactive monitoring account using an existing Secret:

```json
{
  "namespace": "mariadb-1",
  "username": "metrics",
  "account_type": "monitor",
  "if_exists": "recreate",
  "password_secret_name": "metrics-credentials",
  "password_expire_mode": "never",
  "dry_run": "false",
  "confirm": "true"
}
```

Update only the grants of an existing account without changing its password:

```json
{
  "namespace": "mariadb-1",
  "database": "orders",
  "username": "account_a",
  "account_type": "app_writer",
  "if_exists": "update_grants",
  "dry_run": "false",
  "confirm": "true"
}
```

The named profile must exist in the deployment registry. Repeating the same
request returns UNCHANGED once the profile is applied. For an existing account,
use this mode instead of recreate when its credential must remain unchanged.

## Breaking-change migration

| Previous contract | New contract |
|---|---|
| Caller-selected privileges / allow_admin_privileges | account_type with deployment-defined policy |
| allow_existing=false | if_exists=error |
| allow_existing=true | if_exists=recreate |
| Omitted existing-account option | if_exists=skip; no password or grant changes |
| Omitted database implies global SELECT | Default ro requires a database; global read requires deployment policy |
| allow_global / explicit wildcard database | Removed; global grants come only from profile configuration |
| Error JSON with exit 0 unless --strict-exit | Errors always exit nonzero |
| generate_password / task-owned password_secret result | Still removed; use delivery mode or existing Secret reference |

Legacy CLI flags are rejected as unknown options. Legacy environment inputs are
rejected with INVALID_INPUT. Removed fields are not declared in AQSH's schema;
callers must migrate and must not rely on unknown JSON fields being rejected by
the gateway. API input validation behavior belongs to the deployed AQSH version.

For creates and recreations, capture generated credentials from delivery, or
choose encrypted payload delivery. Grants-only updates have no password payload. No task-owned password Secret is created.
