# lib/logging.sh

Structured logging library. Outputs timestamped, colored lines to stderr.

## Setup

```bash
source /tasks/lib/logging.sh
log_set_level "DEBUG"   # optional; default is INFO
```

## Functions

### `log_set_level <level>`

Set the minimum log level. Messages below this level are suppressed.

| Parameter | Type | Values |
|-----------|------|--------|
| level | string | `DEBUG` `INFO` `ERROR` `CRIT` |

---

### `log_debug <operation> <message>`

Emit a DEBUG-level message (cyan).

| Parameter | Description |
|-----------|-------------|
| operation | Short identifier for the operation (e.g. `"mongo-restart"`) |
| message | Human-readable message |

---

### `log_info <operation> <message>`

Emit an INFO-level message (green).

---

### `log_error <operation> <message>`

Emit an ERROR-level message (yellow).

---

### `log_crit <operation> <message>`

Emit a CRIT-level message (red).

## Output Format

```
[2026-05-11T12:00:00Z] [INFO ] [mongo-restart] Rolling restart in mongo-1
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LOG_LEVEL` | `INFO` | Override minimum level on startup |
| `_LOG_FILE` | (empty) | Optional file path to also write plain-text logs |

## Example

```bash
source /tasks/lib/logging.sh
log_set_level "DEBUG"
log_info  "my-task" "Starting operation"
log_debug "my-task" "namespace=$DB_NAMESPACE"
log_error "my-task" "Something went wrong"
```
