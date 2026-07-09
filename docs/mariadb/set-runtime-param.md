# MariaDB Set Runtime Param AQSH Runbook

`set-runtime-param` applies a MariaDB global variable **online** with
`SET GLOBAL` — a break-glass knob for incidents (e.g. bump `max_connections`
during connection exhaustion). AWS RDS analogue: `ModifyDBParameterGroup` for a
**dynamic** (ApplyType) parameter.

> **Ephemeral by design.** It does **not** write `my.cnf` / `spec.myCnf`. A
> restart or failover reverts the change. Durable config is owned by the
> declarative source — change it with a **config PR / GitOps**. This task is only
> the runtime escape hatch, which is also why it never touches the CR (no
> imperative-vs-declarative drift).

## What it will / won't do

- **Dynamic params** → applied via `SET GLOBAL` on the targeted pods.
- **Static (restart-only) params** → `BLOCKED` (`PARAM_STATIC`), redirected to the
  config-PR path. Whether a param is dynamic is asked of the live server
  (`information_schema.SYSTEM_VARIABLES.READ_ONLY`), not hardcoded.
- Only params on the curated **allow-list** are accepted (`PARAM_NOT_ALLOWED`
  otherwise). Run with no `param` to list them.

## Inputs

| Input | Env | Required | Default | Notes |
|-------|-----|:--:|---------|-------|
| `namespace` | `DB_NAMESPACE` | ✓ | — | Target MariaDB namespace |
| `param` | `RUNTIME_PARAM` | | — | Variable to set; **omit to list** supported params + current values |
| `value` | `RUNTIME_VALUE` | | — | Target value: absolute (`500` / `ON` / bytes) or **relative** to the live value (`*1.5`, `+100`, `-25%`) — relative works both directions and numeric params only |
| `scope` | `RUNTIME_SCOPE` | | `all` | `all` \| `primary` \| `<pod-name>` |
| `mdb` | `MARIADB_NAME` | | (auto) | Which MariaDB CR |
| `context` | `K8S_CONTEXT` | | `""` | Reachability hook |
| `dry_run` | `DRY_RUN` | | `true` | Plan-only by default |
| `confirm` | `CONFIRM` | | `false` | Must be `true` to apply |

## Allow-list & risk tiers

The script owns a curated allow-list; each param has a **risk tier** that drives
the warning shown:

- **safe** — `max_connections`, `max_statement_time`, `slow_query_log`,
  `long_query_time`, `wait_timeout`, `interactive_timeout`.
- **memory** — `innodb_buffer_pool_size`, `tmp_table_size`, `max_heap_table_size`,
  `sort_buffer_size`, `join_buffer_size`. ⚠️ raising these can **OOM a
  memory-limited pod** — often you actually want `scale` (more pod RAM), not this.
- **durability** — `innodb_flush_log_at_trx_commit`, `sync_binlog`. ⚠️ opens a
  **data-loss window** on crash.
- **protect** — `read_only`, `super_read_only`. Use `scope` carefully.

## Examples

```bash
# discover what's tunable (+ current values)
curl -sX POST "$MARIADB_AQSH_URL/tasks/set-runtime-param" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1" }'

# plan bumping max_connections
curl -sX POST "$MARIADB_AQSH_URL/tasks/set-runtime-param" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1", "param": "max_connections", "value": "500" }'

# apply it on every member
curl -sX POST "$MARIADB_AQSH_URL/tasks/set-runtime-param" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1", "param": "max_connections", "value": "500", "dry_run": "false", "confirm": "true" }'
```

## Relative values

For numeric params, `value` may be relative to the current live value — handy in
an incident ("just bump it") without computing the exact number, and it works
**both directions**:

| form | meaning | example |
|------|---------|---------|
| `*F`   | multiply | `*1.5` → current × 1.5 |
| `+N` / `-N` | add / subtract | `+100`, `-50` |
| `+P%` / `-P%` | percentage | `+25%` (up), `-25%` (down, e.g. shrink `wait_timeout` to shed idle conns) |

The computed absolute value is validated and shown in `dry_run` (with the
original expression in `value_expr`) before you confirm — so a memory-tier `*2`
still surfaces the concrete target + OOM warning. Relative is rejected for
non-numeric params (`slow_query_log`, `read_only`, …).

## Notes

- Size params (`innodb_buffer_pool_size`, …) take **bytes** online (no `K/M/G`
  suffix — that's a my.cnf-only convenience).
- Batch (several params atomically) is a possible v2; today it's one param/call so
  each change gets its own tier-appropriate confirm and a clean audit trail.
