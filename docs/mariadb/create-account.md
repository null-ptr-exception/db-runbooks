# Task: create-account

Create a MariaDB user and grant scoped privileges through AQSH.

## Description

The task is conservative by default:

- `dry_run=true` by default.
- `dry_run=false` requires `confirm=true`.
- Passwords are never written to logs or task results.
- Generated passwords are stored in a Kubernetes Secret.
- Global grants and admin privileges are blocked unless explicitly allowed.
- Existing accounts return an idempotent `UNCHANGED` result without changing
  grants or password Secrets.

The password Secret is a managed-database internal: for a new account its name
is **derived by convention** (`mariadb-account-<username>`, normalised to a valid
Secret name), not supplied by the caller. The result returns
`password_secret.{name,key}` so the caller can find the credentials. For existing
accounts, the task does not create or backfill a missing password Secret, because
it cannot know the pre-existing account's password.

When `generate_password=true`, the task creates the generated password Secret
before running `CREATE USER`, so the password can be recovered if the task fails
before the account is created. Secret creation is create-only: if the Secret
already exists, the task reads and reuses that password instead of overwriting
it. If `CREATE USER` succeeds but a later step such as `GRANT` or `SHOW GRANTS`
verification fails, the next run sees `ACCOUNT_EXISTS=true` and will not
regenerate or overwrite the Secret.

The derived (or operator-overridden) Secret name must start with
`mariadb-account-`. This keeps the task from reading unrelated Secrets even though
Kubernetes RBAC grants namespace-scoped Secret access for account password
management. Operators can still pin a name via the `ACCOUNT_PASSWORD_SECRET_NAME`
/ `_PREFIX` / `_KEY` environment overrides, but they are no longer task inputs.

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
  "password_secret_name": "mariadb-account-app-user-password",
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
| `mdb` | `MARIADB_NAME` | no | _auto-detect_ | MariaDB CR / StatefulSet name. When omitted, auto-detected from the namespace (single CR, else single StatefulSet); several matches return `MARIADB_AMBIGUOUS`. |
| `container` | `MARIADB_CONTAINER` | no | `mariadb` | MariaDB container name |
| `database` | `ACCOUNT_DATABASE` | yes | - | Database grant scope |
| `username` | `ACCOUNT_USERNAME` | yes | - | User to create |
| `host` | `ACCOUNT_HOST` | no | `%` | MariaDB account host |
| `privileges` | `ACCOUNT_PRIVILEGES` | yes | - | Comma-separated privileges |
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
| `UNCHANGED` | `ACCOUNT_EXISTS` | Account already existed; grants and password Secret were not changed |
| `BLOCKED` | `CONFIRM_REQUIRED` | `dry_run=false` without `confirm=true` |
| `BLOCKED` | `PASSWORD_SECRET_REQUIRED` | New account requested without a password Secret |
| `BLOCKED` | `PASSWORD_SECRET_UNAVAILABLE` | Requested new account but password Secret is missing or unreadable |
| `BLOCKED` | `PASSWORD_SECRET_INVALID` | Password Secret value contains unsupported characters |
| `ERROR` | `INVALID_INPUT` | Validation failed |
| `ERROR` | `KUBECTL_UNAVAILABLE` | `kubectl` or the target cluster API is unavailable |
| `ERROR` | `CURRENT_PRIMARY_EMPTY` | No primary MariaDB pod was found during operation |
| `ERROR` | `ROOT_PASSWORD_UNAVAILABLE` | Root password is not available from target pods |
| `ERROR` | `PASSWORD_SECRET_WRITE_FAILED` | Failed to create password Secret and no existing password Secret could be read |
| `ERROR` | `SQL_FAILED` | SQL execution failed |
| `ERROR` | `SQL_VERIFY_FAILED` | Post-change SQL verification failed |

## Permissions

The task needs the same MariaDB read/exec permissions as `sanity-check`, plus
namespaced Secret access in the target database namespace:

| Resource | Verbs | Purpose |
|----------|-------|---------|
| `pods`, `pods/exec` | `get`, `list`, `watch`, `create` | Resolve primary and execute SQL |
| `statefulsets`, `mariadbs.k8s.mariadb.com` | `get`, `list`, `watch` | Resolve target topology |
| `secrets` | `get`, `create` | Read or create namespace-scoped account password Secrets whose names pass the configured prefix check |

## CLI Example

```bash
LIB_DIR="$PWD/aqsh-tasks/lib" \
  aqsh-tasks/scripts/mariadb/create-account.sh \
  --context kind-cluster-a \
  --namespace mariadb-1 \
  --database app_db \
  --username app_user \
  --privileges SELECT,INSERT \
  --dry-run true \
  --json | jq .
```

The password Secret name is derived automatically (here:
`mariadb-account-app-user`); operators can still override it with
`--password-secret-name` if needed.

Real execution:

```bash
LIB_DIR="$PWD/aqsh-tasks/lib" \
  aqsh-tasks/scripts/mariadb/create-account.sh \
  --context kind-cluster-a \
  --namespace mariadb-1 \
  --database app_db \
  --username app_user \
  --privileges SELECT,INSERT \
  --dry-run false \
  --confirm true \
  --json | jq .
```
