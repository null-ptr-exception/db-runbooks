# MariaDB Switch Primary AQSH Runbook

`switch-primary` promotes a chosen replica to primary within one replicated
MariaDB instance, by patching `spec.replication.primary.podIndex`. The
mariadb-operator then performs a **graceful switchover** (read-lock the old
primary → wait for replicas in sync → promote the target → reconnect replicas →
demote the old primary). AWS RDS analogue: `FailoverDBCluster` (with a target).

> This is the operator's built-in, best-effort switchover. Production-grade HA
> switchover in the mariadb-operator is meant to go through **MaxScale**
> (transparent failover, transaction replay, connection routing); that is a
> larger future item.

## Safety model

The **operator** guarantees data safety: it blocks the switchover on lagged
replicas and won't promote until they are in sync. This task's job is to avoid a
*self-inflicted write outage* and to self-heal a stuck switchover:

- **Strict lag pre-check** — the task only switches when every replica is healthy
  and within `lag_threshold` seconds. A synced replica makes the operator's
  sync-wait instant, so the current primary never sits in a stuck `read_only`
  window. A lagging replica → `BLOCKED` before any change.
- **Auto-recovery on a stuck switch** — if the switch doesn't complete within
  `wait_timeout`, the task rolls `podIndex` back and verifies the primary is
  serving again (`SWITCH_TIMEOUT_ROLLED_BACK`). If rollback doesn't recover and
  pod eviction is enabled, it evicts the stuck primary pod (the mariadb-operator
  #363 recovery) and re-verifies. Only if all recovery fails does it return
  `SWITCH_STUCK`.

## Version compatibility

The task probes the CRD with `kubectl explain
mariadb.spec.replication.primary.podIndex` (like `restart` probes `podMetadata` /
`inheritMetadata`). If the field is absent → `BLOCKED SWITCH_UNSUPPORTED`.

## Inputs

| Input | Env | Required | Default | Notes |
|-------|-----|:--:|---------|-------|
| `namespace` | `DB_NAMESPACE` | ✓ | — | Target MariaDB namespace |
| `target` | `TARGET_POD_INDEX` | ✓ | — | The replica podIndex to promote |
| `mdb` | `MARIADB_NAME` | | (auto) | Which MariaDB CR (auto-detected if one) |
| `context` | `K8S_CONTEXT` | | `""` | Reachability hook |
| `lag_threshold` | `LAG_THRESHOLD` | | `0` | Max `secondsBehindMaster` allowed to switch |
| `wait_timeout` | `WAIT_TIMEOUT` | | `300` | Seconds to wait for the switch to complete |
| `rollback_on_timeout` | `ROLLBACK_ON_TIMEOUT` | | `true` | Auto-roll-back if the switch gets stuck |
| `dry_run` | `DRY_RUN` | | `true` | Plan-only by default |
| `confirm` | `CONFIRM` | | `false` | Must be `true` to switch |

`ALLOW_POD_EVICTION` (env only, default `false`) gates the eviction recovery step
until an e2e proves it reliable — auto-deleting a primary pod on an unproven
sequence could turn a hiccup into an outage.

## Example

```bash
# plan
curl -sX POST "$MARIADB_AQSH_URL/tasks/switch-primary" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1", "target": "1" }'

# switch
curl -sX POST "$MARIADB_AQSH_URL/tasks/switch-primary" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1", "target": "1", "dry_run": "false", "confirm": "true" }'
```

## Notes / follow-up (see #59)

- e2e coverage needs a **replicated** MariaDB (replicas ≥ 2) — including a
  deliberately-induced stuck switchover — to validate the recovery ladder before
  `ALLOW_POD_EVICTION` is enabled by default.
- A MaxScale-based switchover (production-grade) is a larger future item.
