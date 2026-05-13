# lib/mongodb.sh

MongoDB helper functions using `mongosh`. Every function returns a JSON string via `response_ok` / `response_err`.

## Setup

```bash
source /tasks/lib/logging.sh
source /tasks/lib/response.sh
source /tasks/lib/mongodb.sh
```

## Connection Modes

### Mode A — URI (default)

```bash
MONGO_URI="mongodb://localhost:27017"
# Special chars in password MUST be percent-encoded, or use mongo_build_uri:
MONGO_URI=$(mongo_build_uri "10.0.0.5" 27017 "alice" 'p@ss#w0rd!')
```

### Mode B — Split credentials (recommended; no encoding needed)

```bash
MONGO_HOST="10.0.0.5"
MONGO_PORT=27017
MONGO_USER="alice"
MONGO_PASS='p@ss#w0rd!'   # special chars are safe here
MONGO_AUTHDB="admin"
```

## Common Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `MONGO_TLS` | (empty) | Set to `"--tls"` to enable TLS |
| `MONGO_EXTRA_ARGS` | (empty) | Additional `mongosh` flags |
| `MONGO_TIMEOUT` | `10000` | Server selection timeout (ms) |

---

## Helper Functions

### `mongo_build_uri <host> <port> [username] [password] [authdb]`

Build a properly percent-encoded MongoDB URI. Sets `MONGO_URI` and returns it on stdout.

```bash
MONGO_URI=$(mongo_build_uri "10.0.0.5" 27017 "alice" 'p@ss#w0rd!' "admin")
```

---

## Connection & Health

### `mongo_check`

Verify `mongosh` is installed and a connection can be established.

**Returns**: `data.connection` — masked connection label (password hidden).

---

## Database Functions

### `mongo_list_databases`

**Returns**: `data` — raw `listDatabases` result.

### `mongo_list_collections <database>`

**Returns**: `data.database`, `data.collections` — array of collection names.

### `mongo_create_collection <database> <collection>`

### `mongo_drop_collection <database> <collection>`

### `mongo_drop_database <database>`

---

## Document Functions (CRUD)

### `mongo_insert_one <database> <collection> <json_doc>`

| Parameter | Example |
|-----------|---------|
| json_doc | `'{"name":"Alice","age":30}'` |

**Returns**: `data.result` — raw `insertOne` result with `insertedId`.

### `mongo_insert_many <database> <collection> <json_array>`

**Returns**: `data.result.insertedCount`.

### `mongo_find <database> <collection> [filter] [projection] [limit]`

| Parameter | Default | Description |
|-----------|---------|-------------|
| filter | `{}` | MongoDB filter document |
| projection | `{}` | Field projection |
| limit | `50` | Max documents to return |

**Returns**: `data.documents` — array of matching documents.

### `mongo_find_one <database> <collection> [filter]`

### `mongo_count <database> <collection> [filter]`

**Returns**: `data.count`.

### `mongo_update_one <database> <collection> <filter> <update>`

### `mongo_update_many <database> <collection> <filter> <update>`

### `mongo_upsert_one <database> <collection> <filter> <update>`

### `mongo_delete_one <database> <collection> <filter>`

### `mongo_delete_many <database> <collection> <filter>`

---

## Aggregation

### `mongo_aggregate <database> <collection> <pipeline>`

| Parameter | Example |
|-----------|---------|
| pipeline | `'[{"$group":{"_id":"$status","count":{"$sum":1}}}]'` |

**Returns**: `data` — aggregation result array.

---

## Index Functions

### `mongo_create_index <database> <collection> <keys> [options]`

| Parameter | Example |
|-----------|---------|
| keys | `'{"email":1}'` |
| options | `'{"unique":true}'` |

### `mongo_list_indexes <database> <collection>`

### `mongo_drop_index <database> <collection> <index_name>`

---

## Server & Admin

### `mongo_server_status`

Get server status (uptime, connections, memory, WiredTiger cache, global lock).

**Returns**: `data` — raw `serverStatus` document.

### `mongo_current_op [max_time_ms]`

List currently running operations.

---

## Replica Set Functions

### `mongo_rs_status`

Get replica set member states.

**Returns**: `data` — raw `rs.status()` document. `data.ok == 1` means RS is active.

### `mongo_rs_config`

Get replica set configuration.

### `mongo_rs_is_primary`

**Returns**: `data.isPrimary` — boolean.

### `mongo_rs_lag`

Get replication lag per secondary member.

**Returns**: `data` — array of `{member, stateStr, lagSeconds}` objects.

### `mongo_oplog_status`

**Returns**: `data.sizeMB`, `data.usedMB`, `data.windowDays` — oplog window in days.

---

## Example

```bash
source /tasks/lib/logging.sh
source /tasks/lib/response.sh
source /tasks/lib/mongodb.sh

MONGO_HOST="10.96.0.5"
MONGO_USER="admin"
MONGO_PASS="secret"
MONGO_AUTHDB="admin"

mongo_check
mongo_rs_status
mongo_list_databases
```
