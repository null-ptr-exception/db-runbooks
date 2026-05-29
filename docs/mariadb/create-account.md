# Task: create-account

Create a MariaDB user and grant scoped privileges through AQSH.

## Description

The task is conservative by default:

- `dry_run=true` by default.
- `dry_run=false` requires `confirm=true`.
- Passwords are never written to logs or task results.
- Generated passwords are stored in a Kubernetes Secret.
- Global grants and admin privileges are blocked unless explicitly allowed.
- Existing accounts return an idempotent `UNCHANGED` result after grants are applied.

For new accounts, `password_secret_name` is conditionally required. For existing
accounts, the task applies grants idempotently and does not create or backfill a
missing password Secret, because it cannot know the pre-existing account's
password.

When `generate_password=true`, the task writes the generated password Secret
before running `CREATE USER` so a successfully created account always has a
recoverable password. If the later SQL step fails, the Secret may temporarily
exist without a matching account; retrying the task regenerates and overwrites
that Secret.

## Endpoint

```text
POST /tasks/create-account
```

Served by **aqsh-mariadb** on NodePort `30081`.

## Request

```json
{
  "namespace": "mariadb-2",
  "resource": "mariadb",
  "mdb": "mariadb",
  "database": "app_db",
  "username": "app_user",
  "host": "%",
  "privileges": "SELECT,INSERT",
  "password_secret_name": "app-user-password",
  "password_secret_key": "password",
  "generate_password": "true",
  "dry_run": "true",
  "confirm": "false",
  "allow_global": "false",
  "allow_admin_privileges": "false"
}
```

## Input Fields

| Field | Env Var | Required | Default | Description |
|-------|---------|----------|---------|-------------|
| `namespace` | `DB_NAMESPACE` | yes | - | Target MariaDB namespace |
| `context` | `K8S_CONTEXT` | no | current / in-cluster | Kubernetes context |
| `resource` | `MARIADB_RESOURCE` | no | `mariadb` | MariaDB CR kind |
| `mdb` | `MARIADB_NAME` | no | `mariadb` | MariaDB CR and StatefulSet name |
| `container` | `MARIADB_CONTAINER` | no | `mariadb` | MariaDB container name |
| `database` | `ACCOUNT_DATABASE` | yes | - | Database grant scope |
| `username` | `ACCOUNT_USERNAME` | yes | - | User to create |
| `host` | `ACCOUNT_HOST` | no | `%` | MariaDB account host |
| `privileges` | `ACCOUNT_PRIVILEGES` | yes | - | Comma-separated privileges |
| `password_secret_name` | `ACCOUNT_PASSWORD_SECRET_NAME` | required for new account | - | Secret that stores or provides the account password |
| `password_secret_key` | `ACCOUNT_PASSWORD_SECRET_KEY` | no | `password` | Secret data key |
| `generate_password` | `GENERATE_PASSWORD` | no | `true` | Generate and write password Secret |
| `dry_run` | `DRY_RUN` | no | `true` | Return redacted SQL plan only |
| `confirm` | `CONFIRM` | no | `false` | Required for real execution |
| `allow_global` | `ALLOW_GLOBAL` | no | `false` | Allow `*.*` grant scope |
| `allow_admin_privileges` | `ALLOW_ADMIN_PRIVILEGES` | no | `false` | Allow broad/admin privileges |

## Allowed Privileges

Default allow list:

- `SELECT`
- `INSERT`
- `UPDATE`
- `DELETE`
- `CREATE`
- `ALTER`
- `INDEX`
- `EXECUTE`
- `SHOW VIEW`

The task rejects `ALL`, `ALL PRIVILEGES`, `SUPER`, `FILE`, `PROCESS`, `RELOAD`,
`SHUTDOWN`, and `GRANT OPTION` unless `allow_admin_privileges=true`.

## Result

Dry-run:

```json
{
  "status": "READY",
  "reason_code": "DRY_RUN_READY",
  "database": "app_db",
  "username": "app_user",
  "host": "%",
  "privileges": ["SELECT", "INSERT"],
  "dry_run": true,
  "sql_plan": [
    "CREATE USER IF NOT EXISTS 'app_user'@'%' IDENTIFIED BY '<redacted>'",
    "GRANT SELECT, INSERT ON `app_db`.* TO 'app_user'@'%'",
    "FLUSH PRIVILEGES",
    "SHOW GRANTS FOR 'app_user'@'%'"
  ]
}
```

Real execution returns one of:

| Status | Reason | Meaning |
|--------|--------|---------|
| `CREATED` | `ACCOUNT_CREATED` | Account was created and grants verified |
| `UNCHANGED` | `ACCOUNT_EXISTS` | Account already existed; grants were applied |
| `BLOCKED` | `CONFIRM_REQUIRED` | `dry_run=false` without `confirm=true` |
| `BLOCKED` | `PASSWORD_SECRET_REQUIRED` | New account requested without a password Secret |
| `ERROR` | `INVALID_INPUT` | Validation failed |
| `ERROR` | `SQL_FAILED` | SQL execution failed |

## Permissions

The task needs the same MariaDB read/exec permissions as `sanity-check`, plus
namespaced Secret access in the target database namespace:

| Resource | Verbs | Purpose |
|----------|-------|---------|
| `pods`, `pods/exec` | `get`, `list`, `watch`, `create` | Resolve primary and execute SQL |
| `statefulsets`, `mariadbs.k8s.mariadb.com` | `get`, `list`, `watch` | Resolve target topology |
| `secrets` | `get`, `create`, `patch` | Read or store account password Secret |

## CLI Example

```bash
LIB_DIR="$PWD/aqsh-tasks/lib" \
  aqsh-tasks/scripts/mariadb/create-account.sh \
  --context kind-cluster-dbs \
  --namespace mariadb-2 \
  --database app_db \
  --username app_user \
  --privileges SELECT,INSERT \
  --password-secret-name app-user-password \
  --dry-run true \
  --json | jq .
```

Real execution:

```bash
LIB_DIR="$PWD/aqsh-tasks/lib" \
  aqsh-tasks/scripts/mariadb/create-account.sh \
  --context kind-cluster-dbs \
  --namespace mariadb-2 \
  --database app_db \
  --username app_user \
  --privileges SELECT,INSERT \
  --password-secret-name app-user-password \
  --dry-run false \
  --confirm true \
  --json | jq .
```
