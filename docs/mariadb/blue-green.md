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
| `blue-green/create` | Blue AQSH | Physical backup of Blue → bootstrap Green → optional upgrade. One call. |
| `blue-green/switchover` | Blue AQSH | Guardrails (validate + write-probe) → maintenance Blue → demote Blue → promote Green → verify. Rolls back Blue if promotion/verification fails. |
| `blue-green/delete` | Green AQSH | Delete the Green MariaDB CR, its ExternalMariaDB refs, and optional PhysicalBackup. |
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

The granular tasks that span clusters (`bootstrap-green`, `upgrade-green`,
`set-primary`, `validate`, `write-probe`) remain registered as the low-level
substrate the orchestrators call over HTTP, and are documented under
[Low-level tasks](#low-level-tasks) for recovery and debugging. The two
purely-local steps (physical backup, maintenance) are not separate tasks — they
are folded into `create` and `switchover` respectively.

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
    "confirm": "true"
  }'
```

`green_image` is the image Green is bootstrapped with (match Blue's version so
restore is compatible). `target_image`, if set and different, triggers an
in-place upgrade of Green after bootstrap. Poll the returned task ID; the
result includes the backup descriptor, bootstrap, and upgrade sub-results.

## Switchover

Run on the Blue AQSH. The task enforces guardrails before mutating anything,
performs the switchover in the safe order (demote Blue before promoting Green to
avoid a dual-primary intent), and rolls Blue back if promotion or verification
fails.

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
- Blue validates as the current `multiCluster` primary.
- A write probe through Blue succeeds (proves the primary accepts writes and
  replication is live). Set `skip_write_probe: "true"` to skip it.

If a step in the execute phase fails, the task restores Blue (re-promote Blue,
clear maintenance) and returns an error whose message ends with
`(rolled back Blue)`.

## Delete

Run on the Green AQSH (single cluster). Use after a successful switchover to
retire the old Blue deployment, or to clean up a failed bootstrap.

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
created by bootstrap. Pass `backup_name` to also delete the PhysicalBackup CR.

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
- Green accepts the `blue-green/write-probe` task.

---

## Low-level tasks

The orchestrators above are built from these granular tasks. They are the same
single-cluster building blocks and can be called directly for recovery,
debugging, or step-by-step runs. Each step must complete before the next is
started; they are not a cross-cluster atomic transaction.

### Provision Green, step by step

Provisioning the Blue physical backup is folded into `blue-green/create` (it
runs on the Blue cluster as the first step). To bootstrap Green by hand, point
`backup_bucket` / `backup_prefix` / `backup_endpoint` at an existing Blue
physical backup, then call bootstrap on cluster B:

```bash
curl -s -X POST "${MARIADB_AQSH_B_URL}/tasks/blue-green%2Fbootstrap-green" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "mariadb-bg",
    "mdb": "mariadb-green",
    "blue_name": "mariadb-blue",
    "green_image": "mariadb:10.6",
    "backup_bucket": "multi-cluster",
    "backup_prefix": "mariadb-bg/blue",
    "backup_endpoint": "172.19.0.16:30092",
    "confirm": "true"
  }'
```

Upgrade Green after bootstrap:

```bash
curl -s -X POST "${MARIADB_AQSH_B_URL}/tasks/blue-green%2Fupgrade-green" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "mariadb-bg",
    "mdb": "mariadb-green",
    "target_image": "mariadb:10.11",
    "confirm": "true"
  }'
```

### Switchover, step by step

Validate Blue and Green before switchover:

```bash
curl -s -X POST "${MARIADB_AQSH_A_URL}/tasks/blue-green%2Fvalidate" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mariadb-bg", "mdb": "mariadb-blue", "expected_version": "10.6", "expected_primary": "mariadb-blue"}'

curl -s -X POST "${MARIADB_AQSH_B_URL}/tasks/blue-green%2Fvalidate" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mariadb-bg", "mdb": "mariadb-green", "expected_version": "10.11", "expected_primary": "mariadb-blue"}'
```

Putting Blue into maintenance/read-only mode is folded into
`blue-green/switchover` (with automatic rollback). When running by hand, demote
Blue so it follows Green, then promote Green:

```bash
curl -s -X POST "${MARIADB_AQSH_A_URL}/tasks/blue-green%2Fset-primary" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mariadb-bg", "mdb": "mariadb-blue", "primary": "mariadb-green", "confirm": "true"}'

curl -s -X POST "${MARIADB_AQSH_B_URL}/tasks/blue-green%2Fset-primary" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mariadb-bg", "mdb": "mariadb-green", "primary": "mariadb-green", "confirm": "true"}'
```

Verify Green accepts writes after switchover:

```bash
curl -s -X POST "${MARIADB_AQSH_B_URL}/tasks/blue-green%2Fwrite-probe" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mariadb-bg", "mdb": "mariadb-green", "confirm": "true", "id": "2", "note": "written-after-switchover"}'
```
