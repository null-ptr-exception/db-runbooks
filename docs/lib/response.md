# lib/response.sh

Standard JSON response builder. Every public function in `k8s.sh` and `mongodb.sh` returns a JSON string built with these helpers.

## Setup

```bash
source /tasks/lib/response.sh
```

## JSON Schema

```json
{
  "status":    "success" | "error",
  "code":      0,
  "operation": "operation_name",
  "message":   "Human readable message",
  "data":      { ... } | null,
  "timestamp": "2026-05-11T12:00:00Z"
}
```

## Functions

### `response_ok <operation> <message> [data]`

Build a success response (`status: "success"`, `code: 0`).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| operation | string | yes | Operation identifier |
| message | string | yes | Human-readable message |
| data | JSON or string | no | Payload; omit for `null` |

**Returns**: JSON string on stdout.

**Example**

```bash
resp=$(response_ok "restart" "Rollout complete" '{"replicas":1}')
echo "$resp"
# {"status":"success","code":0,"operation":"restart","message":"Rollout complete","data":{"replicas":1},"timestamp":"..."}
```

---

### `response_err <operation> <message> [data] [code]`

Build an error response (`status: "error"`).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| operation | string | yes | Operation identifier |
| message | string | yes | Human-readable error message |
| data | JSON or string | no | Error detail payload |
| code | integer | no | Exit/error code (default `1`) |

**Example**

```bash
resp=$(response_err "restart" "StatefulSet not found" '{"sts":"mongodb"}' 1)
```

## Notes

- Automatically escapes backslashes, double-quotes, newlines, tabs in string values.
- Detects whether `data` is already valid JSON and embeds it verbatim; otherwise wraps it as a JSON string.
