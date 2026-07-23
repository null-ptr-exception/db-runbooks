# MariaDB Switch Primary AQSH Runbook

`switch-primary` promotes a replica to primary within one replicated MariaDB
instance, by patching `spec.replication.primary.podIndex`. The caller may name a
`target` replica, or omit it to let the task auto-pick the most caught-up healthy
replica (AWS RDS `FailoverDBCluster` likewise makes the target optional). Before
changing the CR, the task fences writes on the old primary and drains every
replica to the fenced GTID. The mariadb-operator then performs its own
**graceful switchover** (read-lock the old primary → wait for replicas in sync →
promote the target → reconnect replicas → demote the old primary). AWS RDS
analogue: `FailoverDBCluster` (with a target).

> This is the operator's built-in, best-effort switchover. Production-grade HA
> switchover in the mariadb-operator is meant to go through **MaxScale**
> (transparent failover, transaction replay, connection routing); that is a
> larger future item.

## Safety model

The task establishes a safe handoff before the operator sees the new desired
primary, then verifies or recovers the operator-owned switch:

- **Bounded health pre-check** — every replica must be healthy, have known lag,
  and be within `lag_threshold` seconds. This bounds the prospective write
  outage but is not the consistency proof: non-zero lag is allowed. The replica-health
  signal comes from the CR's `status.replication.replicas` on the current-gen
  operator, or from live `SHOW ALL SLAVES STATUS` on the legacy operator (see
  *Operator compatibility*); the output field `replicas_source`
  (`cr_status` | `show_all_slaves_status`) records which was used.
- **Write fence + GTID drain** — on apply, the task sets the old primary
  `read_only=1`, obtains `FLUSH TABLES WITH READ LOCK`, captures
  `@@gtid_binlog_pos` while the lock is held, and releases the table lock while
  keeping `read_only` enabled. It then requires every replica's
  `MASTER_GTID_WAIT` to reach that exact position before patching `podIndex`.
  Any pre-patch failure restores `read_only=0`; an EXIT/TERM/INT trap provides
  the same best-effort recovery if the task is interrupted. Application users
  must not hold privileges that bypass MariaDB `read_only`; administrative root
  access remains reserved for the runbook and operator.
- **Explicit ownership handoff** — after the CR patch succeeds, the operator
  owns the fence and promotion. The task never clears `read_only` on that happy
  path, avoiding a race with the operator's own read-lock / GTID sequence. The
  handoff uses an atomic JSON Patch that tests both `resourceVersion` and the
  old desired podIndex; a different concurrent target is never overwritten.
- **Auto-recovery on a stuck switch** — if the switch doesn't complete within
  `wait_timeout`, the task rolls `podIndex` back, explicitly restores the old
  primary writable, and verifies it is serving again
  (`SWITCH_TIMEOUT_ROLLED_BACK`). If rollback doesn't recover and
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
  task falls back to querying each replica pod directly with
  `SHOW ALL SLAVES STATUS` and synthesizes the same health map, so the bounded
  health pre-check keeps its guarantee. A replica whose status cannot be read
  (unreachable pod, no root password) is treated as **unhealthy**, so the pre-check never blind-switches to
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
| `LAG_THRESHOLD` | `5` | Max pre-fence `secondsBehindMaster` a replica may have to be switch-eligible. Exact catch-up is proven by GTID after fencing. |
| `REPLICATION_DRAIN_TIMEOUT` | `60` | Shared seconds budget for all replicas to reach the fenced GTID before the CR is patched. |
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
  guards, dry_run/confirm, non-zero pre-fence lag, fence → FTWRL/GTID → drain →
  patch ordering, drain/patch/signal recovery, concurrent-target rejection, the happy switch, and the stuck →
  rollback / SWITCH_STUCK ladder — plus the legacy-operator path (no
  `status.replication.replicas`) driving auto-select and Guard 4 off the
  `SHOW ALL SLAVES STATUS` fallback.
- e2e (`tests/mariadb/switch_primary.bats`): real operator on the 2-cluster lab —
  `mariadb-1` runs replicated (helmfile `replicas: 3`); the test switches the
  primary under a continuous writer, asserts `status.currentPrimaryPodIndex`
  flipped, the pre-switch sentinel survived, and writes resume on the new
  primary. It also exercises the live SQL fallback by pausing the controller,
  clearing only the CR's replica-health status map, and asserting a dry-run uses
  `replicas_source=show_all_slaves_status`. A full legacy-operator deployment matrix
  remains tracked in #63.

## Notes / follow-up (see #59)

- The stuck-switch recovery ladder (rollback / gated pod-eviction) is unit-tested
  only; validating it live needs a fault-injection harness, and
  `ALLOW_POD_EVICTION` stays gated until then.
- A MaxScale-based switchover (production-grade) is a larger future item.
