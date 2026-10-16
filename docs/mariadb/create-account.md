# Task: create-account

Create, skip, or recreate a MariaDB account using a deployment-defined privilege
profile and native password expiry. Password generation and delivery use the
same contract as MongoDB create-account.

## Safety defaults

- `dry_run=true`; mutation requires `dry_run=false` and `confirm=true`.
- `account_type=ro` requires an explicit database by default. Omitting a database
  no longer silently exposes all schemas, including system schemas.
- `if_exists=skip` leaves an existing account untouched and returns `SKIPPED` /
  `ACCOUNT_EXISTS`, `mutation_applied=false`, an empty SQL plan and no credential.
  The requested profile is not verified or reconciled when skipped.
- ERROR exits 2 and BLOCKED exits 1, after publishing structured JSON. Successful
  READY/CREATED/RECREATED/SKIPPED results exit 0. `--strict-exit` remains a no-op
  compatibility flag. An execution-query HTTP 200 only means the query succeeded;
  check execution state and the structured task result for operation outcome.
- Dry-run validates the request and deployment policy, but does not contact
  Kubernetes or MariaDB, read a Secret, generate a password, or encrypt anything.
  Its plan contains `<redacted>` and `delivery_payload=null`. Live target,
  account-existence, Secret access, server-version and encryption checks occur
  only during confirmed execution.
- `mutation_applied` becomes true after a successful CREATE/ALTER USER. A later
  revoke, grant, or verification failure remains an ERROR with partial mutation
  explicitly reported and no credential in the error result.

## Endpoint

```text
POST /tasks/create-account
```

The task is served by `aqsh-mariadb`; submission returns 202 and an execution ID.

## Account profiles and scopes

Callers select `account_type=admin|ro|monitor|none`, not arbitrary privileges or
wildcard scopes. `admin` is an allowed username; it does not itself grant any
privileges. Root, mysql, and mariadb.sys remain protected, together with the
additional deployment protection list.

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

Set policy in the mounted `/etc/aqsh/config/mariadb.env`; these settings are not
public task inputs. Each profile except the fixed `none` profile has separate
`MARIADB_ACCOUNT_<ADMIN|RO|MONITOR>_DATABASE_PRIVILEGES_DEFAULT` and
`MARIADB_ACCOUNT_<ADMIN|RO|MONITOR>_GLOBAL_PRIVILEGES_DEFAULT` comma-separated
lists. Unset uses the defaults above; an explicitly empty string means no grants
at that level. An empty profile creates a login without data privileges (USAGE).

For example, a deployment can allow a fixed global read-only profile:

```bash
MARIADB_ACCOUNT_RO_DATABASE_PRIVILEGES_DEFAULT=''
MARIADB_ACCOUNT_RO_GLOBAL_PRIVILEGES_DEFAULT='SELECT'
```

To permit global administrative writes, set ADMIN database privileges empty and
explicitly enumerate the permitted ADMIN global privileges. Global SELECT also
includes system schemas, so it must be a deliberate deployment policy.

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
| `recreate` | ALTER USER, REVOKE ALL PRIVILEGES and GRANT OPTION, apply profile and verify |

All three modes create a missing account. Recreate replaces direct grants and
credentials; it is not DROP USER plus CREATE USER. MariaDB role assignments are
not removed by REVOKE ALL; verification rejects unexpected role grants instead
of claiming profile enforcement. Revoke/grant failures can leave partial state.
Concurrent CREATE races fail rather than returning a password that was never
applied. Serialize recreations of the same account at the caller; this task does
not provide a distributed account lock.

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
| account_type | no | ro | admin, ro, monitor, none |
| if_exists | no | skip | error, skip, recreate |
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

Capture generated credentials from successful delivery, or choose encrypted
payload delivery. No task-owned password Secret is created.
