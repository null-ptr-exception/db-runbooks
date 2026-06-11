# MariaDB Blue/Green AQSH Runbook

This runbook demonstrates that `mariadb-operator` 26.6.0 is blue-green capable
through multi-cluster primitives. The operator does not provide a standalone
`BlueGreenDeployment` CRD; db-runbooks exposes the operational steps as AQSH
tasks.

## Task API

Blue/green is driven by four high-level tasks, modelled on AWS RDS Blue/Green
Deployments (Create / Switchover / Delete / Describe):

| Task | Runs on | Behavior |
|------|---------|----------|
| `blue-green/create` | Blue AQSH | Physical backup of Blue → bootstrap Green → optional upgrade → final replication validation. One call. |
| `blue-green/switchover` | Blue AQSH | Guardrails (validate + read-only Green + no long writes + write-probe) → maintenance Blue → wait for Green to catch up to Blue's GTID → demote Blue → promote Green → verify. Bounded by `switchover_timeout`; rolls back Blue on any failure before promotion. |
| `blue-green/delete` | the cluster being retired | Delete one environment's MariaDB CR, its ExternalMariaDB refs, and optional PhysicalBackup. |
| `blue-green/status` | either AQSH | Read multiCluster, version, and replication state for one MariaDB. |

### Cross-cluster orchestration

AQSH is deployed per cluster and each instance only runs `kubectl` against its
own cluster — there is no single control plane spanning Blue and Green. Because
`create` and `switchover` span both clusters, they run on the **Blue** AQSH and
drive the **Green** steps over HTTP against the peer AQSH.

The kube single-cluster boundary is preserved: the orchestrator never holds the
Green cluster's kubeconfig. It only needs the peer AQSH URL and a bearer token
the caller already holds (both clusters validate tokens against the same
TokenReview backend), supplied as `peer_aqsh_url` and `peer_token`.

The granular bootstrap, upgrade, validation, primary switch, gtid-wait, and
write-probe steps are internal orchestration details. The public AQSH task API
intentionally stays at Create / Switchover / Delete / Status so callers cannot
accidentally skip guardrails or run the steps out of order.

> **`internal_step` is for peer orchestration only.** The orchestrators re-enter
> the same task on the peer AQSH with `internal_step` set because the peer only
> registers these four tasks. Calling `internal_step` directly (for example
> `internal_step: "set-primary"`) bypasses every guardrail and the rollback
> logic — never do this manually.

## Prerequisites

Create the dual Kind environment with MinIO and install the latest
`mariadb-operator` from the official Helm repo. Blue/green requires
`mariadb-operator` 26.6.0 or newer.

```bash
DB_MODE=dual ENABLE_MINIO=true USE_MARIADB_OPERATOR=true ./scripts/setup-clusters.sh
DB_MODE=dual ENABLE_MINIO=true USE_MARIADB_OPERATOR=true ./scripts/deploy-infra.sh
```

For local demos, the helper script can create the full sample topology in one
step:

```bash
./scripts/mariadb-blue-green-demo.sh apply
```

Get tokens and endpoint URLs:

```bash
source .env
TOKEN=$(kubectl --context kind-cluster-apps -n app-a create token test-client --duration=30m)
MARIADB_AQSH_A_URL="http://${CLUSTER_DBS_A_IP}:30081"   # Blue cluster
MARIADB_AQSH_B_URL="http://${CLUSTER_DBS_B_IP}:30081"   # Green cluster
```

The same `$TOKEN` works against both AQSH endpoints, so it can be passed to the
orchestrators as `peer_token`.

## Create (provision Green)

Run on the Blue AQSH. `peer_aqsh_url` points at the Green AQSH; the task creates
the Blue physical backup locally, then bootstraps and (optionally) upgrades
Green over the peer connection.

```bash
curl -s -X POST "${MARIADB_AQSH_A_URL}/tasks/blue-green%2Fcreate" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "mariadb-bg",
    "blue_name": "mariadb-blue",
    "green_name": "mariadb-green",
    "green_image": "mariadb:10.6",
    "target_image": "mariadb:10.11",
    "peer_aqsh_url": "'"${MARIADB_AQSH_B_URL}"'",
    "peer_token": "'"${TOKEN}"'",
    "backup_bucket": "multi-cluster",
    "backup_prefix": "mariadb-bg/blue",
    "backup_endpoint": "'"${CLUSTER_MINIO_IP}"':30092",
    "backup_region": "us-east-1",
    "confirm": "true"
  }'
```

The `backup_*` fields describe the shared S3/MinIO location; the orchestrator
forwards them (including `backup_region`, default `us-east-1`) to Green's
bootstrap so both sides use the same backup descriptor.

`green_image` is the image Green is bootstrapped with (match Blue's version so
restore is compatible). `target_image`, if set and different, triggers an
in-place upgrade of Green after bootstrap. The task only succeeds once Green
validates as a healthy replica of Blue caught up within `lag_threshold`
(default `0`), mirroring AWS create completing with green in sync. Poll the
returned task ID; the result includes the backup descriptor, bootstrap,
upgrade, and final replication-validation sub-results.

## Switchover

Run on the Blue AQSH. The task enforces guardrails before mutating anything,
then executes in the same order as an AWS RDS switchover: stop writes on Blue
(maintenance: cordon, drain, read-only) → capture Blue's GTID position → wait
for Green to apply everything up to that GTID → demote Blue → promote Green →
verify. Demoting Blue before promoting Green avoids a dual-primary intent, and
the GTID wait guarantees no committed write is left behind on Blue — the
guardrail lag check alone cannot, because writes keep landing between that
check and the moment read-only takes effect.

The execute phase up to and including Green's promotion is bounded by
`switchover_timeout` (default `300` seconds, like AWS). If the timeout expires
or any step before promotion fails, the task rolls Blue back (re-promote,
clear maintenance) and returns an error ending with `(rolled back Blue)`. If
post-promotion verification fails, Green remains primary and the task reports
the failure for manual inspection.

```bash
curl -s -X POST "${MARIADB_AQSH_A_URL}/tasks/blue-green%2Fswitchover" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "mariadb-bg",
    "blue_name": "mariadb-blue",
    "green_name": "mariadb-green",
    "peer_aqsh_url": "'"${MARIADB_AQSH_B_URL}"'",
    "peer_token": "'"${TOKEN}"'",
    "expected_green_version": "10.11",
    "confirm": "true"
  }'
```

Guardrails that must pass before any change:

- Green validates as a healthy replica caught up within `lag_threshold` (default `0`).
- Green is read-only (`@@read_only=1`) — writes must not have landed on Green
  before promotion. Set `expect_green_read_only: "false"` to skip.
- Blue validates as the current `multiCluster` primary.
- No statement has been running on Blue for `long_tx_threshold` seconds or more
  (default `60`) — long writes/DDL inflate replica lag and stretch the
  write-outage window. Set `long_tx_threshold: "0"` to disable.
- A write probe through Blue succeeds (proves the primary accepts writes and
  replication is live). Set `skip_write_probe: "true"` to skip it.

## Delete

Single-cluster task: it deletes one environment's MariaDB CR (plus its
ExternalMariaDB refs and optional PhysicalBackup) **on the cluster you run it
against**. Pick the AQSH endpoint and `mdb` for the environment you are
retiring — running it against the wrong cluster deletes the wrong database.

Retire the old Blue after a successful switchover (run on the **Blue** AQSH):

```bash
curl -s -X POST "${MARIADB_AQSH_A_URL}/tasks/blue-green%2Fdelete" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "mariadb-bg",
    "mdb": "mariadb-blue",
    "blue_name": "mariadb-green",
    "confirm": "true"
  }'
```

Clean up a failed or abandoned Green bootstrap (run on the **Green** AQSH):

```bash
curl -s -X POST "${MARIADB_AQSH_B_URL}/tasks/blue-green%2Fdelete" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "mariadb-bg",
    "mdb": "mariadb-green",
    "blue_name": "mariadb-blue",
    "confirm": "true"
  }'
```

`delete_external` (default `true`) also removes the ExternalMariaDB references
created by bootstrap (`blue_name` names the peer reference to remove). Pass
`backup_name` to also delete the PhysicalBackup CR.

## Traffic cutover (difference from AWS)

AWS RDS finishes a switchover by **renaming the green endpoints to the blue
ones**, so applications reconnect to the new primary without any configuration
change. This runbook has no equivalent: promoting Green flips the
`multiCluster` primary intent and replication direction, but **does not
reroute application traffic**. After a successful switchover, repointing
applications — DNS records, load balancers, MaxScale, or Kubernetes Service
routing — is the caller's responsibility. Until that happens, applications
still connected to Blue see a read-only, cordoned database.

## Status

Read either cluster's state:

```bash
curl -s -X POST "${MARIADB_AQSH_A_URL}/tasks/blue-green%2Fstatus" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mariadb-bg", "mdb": "mariadb-blue"}'

curl -s -X POST "${MARIADB_AQSH_B_URL}/tasks/blue-green%2Fstatus" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mariadb-bg", "mdb": "mariadb-green"}'
```

Successful switchover has these properties:

- Blue is in maintenance/cordoned state.
- Blue `currentMultiClusterPrimary` is `mariadb-green`.
- Green is running and `currentMultiClusterPrimary` is `mariadb-green`.
- The post-switchover write probe inside `blue-green/switchover` succeeds.
