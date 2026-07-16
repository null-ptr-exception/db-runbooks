# MariaDB Switch Primary AQSH Runbook

`switch-primary` promotes a replica to primary within one replicated MariaDB
instance, by patching `spec.replication.primary.podIndex`. The caller may name a
`target` replica, or omit it to let the task auto-pick the most caught-up healthy
replica (AWS RDS `FailoverDBCluster` likewise makes the target optional). The
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
  window. A lagging replica → `BLOCKED` before any change. The replica-health
  signal comes from the CR's `status.replication.replicas` on the current-gen
  operator, or from live `SHOW SLAVE STATUS` on the legacy operator (see
  *Operator compatibility*); the output field `replicas_source`
  (`cr_status` | `show_slave_status`) records which was used.
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

## Operator compatibility

`switch-primary` works on **both** operator generations:

- **Current gen (`k8s.mariadb.com`)** — reads per-replica health from the CR's
  `status.replication.replicas` (keyed by pod name, with `slaveIORunning` /
  `slaveSQLRunning` / `secondsBehindMaster`).
- **Legacy gen (`mariadb.*.mmontes.io`)** — the switchover primitive
  (`spec.replication.primary.podIndex`) and `status.currentPrimaryPodIndex`
  exist, but the operator **never populates `status.replication.replicas`**. The
  task falls back to querying each replica pod directly with `SHOW SLAVE STATUS`
  and synthesizes the same health map, so the strict lag pre-check keeps its
  guarantee. A replica whose status cannot be read (unreachable pod, no root
  password) is treated as **unhealthy**, so the pre-check never blind-switches to
  a replica it couldn't verify; if nothing can be resolved the task simply
  `BLOCKED`s exactly as it would for a lagging replica.

The fallback triggers on an empty/absent `status.replication.replicas`, so it is
generation-agnostic — any operator that omits the map gets the SQL path
automatically. `replicas_source` in the output tells you which source was used.

## Inputs

| Input | Env | Required | Default | Notes |
|-------|-----|:--:|---------|-------|
| `namespace` | `DB_NAMESPACE` | ✓ | — | Target MariaDB namespace |
| `target` | `TARGET_POD_INDEX` | | (auto) | Replica podIndex to promote; **omit to auto-pick** the most caught-up healthy replica (like RDS `FailoverDBCluster`) |
| `mdb` | `MARIADB_NAME` | | (auto) | Which MariaDB CR (auto-detected if one) |
| `wait_timeout` | `WAIT_TIMEOUT` | | `300` | Seconds to wait for the switch to complete |
| `dry_run` | `DRY_RUN` | | `true` | Plan-only by default |
| `confirm` | `CONFIRM` | | `false` | Must be `true` to switch |

### Internal config (policy / safety — NOT task inputs)

These are per-deployment policy, env-overridable only, deliberately kept off the
caller-facing API:

| Env | Default | Purpose |
|-----|---------|---------|
| `LAG_THRESHOLD` | `0` | Max `secondsBehindMaster` a replica may have to be switch-eligible. The acceptable lag is a deployment policy, not a per-call choice. |
| `ROLLBACK_ON_TIMEOUT` | `true` | Auto-roll-back a stuck switch to restore write capability. A safety behaviour, not something a caller should disable per call. |
| `ALLOW_POD_EVICTION` | `false` | Gates the pod-eviction recovery step until an e2e proves it reliable — auto-deleting a primary pod on an unproven sequence could turn a hiccup into an outage. |

## Example

```bash
# plan — auto-pick the target (omit "target")
curl -sX POST "$MARIADB_AQSH_URL/tasks/switch-primary" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1" }'

# switch to a specific replica
curl -sX POST "$MARIADB_AQSH_URL/tasks/switch-primary" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{ "namespace": "mariadb-1", "target": "1", "dry_run": "false", "confirm": "true" }'
```

## Testing

- Unit (`tests/unit/mariadb/switch-primary.bats`): mocked kubectl covering the
  guards, dry_run/confirm, the happy switch, and the stuck → rollback / SWITCH_STUCK
  ladder — plus the legacy-operator path (no `status.replication.replicas`) driving
  auto-select and Guard 4 off the `SHOW SLAVE STATUS` fallback.
- e2e (`tests/mariadb/switch_primary.bats`): real operator on the 2-cluster lab —
  `mariadb-1` runs replicated (helmfile `replicas: 3`); the test switches the
  primary, asserts `status.currentPrimaryPodIndex` flipped and the new primary
  is writable, and exercises the live SQL fallback by pausing the controller,
  clearing only the CR's replica-health status map, and asserting a dry-run uses
  `replicas_source=show_slave_status`. A full legacy-operator deployment matrix
  remains tracked in #63.

## Notes / follow-up (see #59)

- The stuck-switch recovery ladder (rollback / gated pod-eviction) is unit-tested
  only; validating it live needs a fault-injection harness, and
  `ALLOW_POD_EVICTION` stays gated until then.
- A MaxScale-based switchover (production-grade) is a larger future item.
