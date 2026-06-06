# MariaDB Blue/Green AQSH Runbook

This runbook demonstrates that `mariadb-operator` 26.6.0 is blue-green capable
through multi-cluster primitives. The operator does not provide a standalone
`BlueGreenDeployment` CRD; db-runbooks exposes the operational steps as AQSH
tasks.

## Prerequisites

Create the dual Kind environment with MinIO and install the latest
`mariadb-operator` from the official Helm repo. Blue/green requires
`mariadb-operator` 26.6.0 or newer.

```bash
DB_MODE=dual ENABLE_MINIO=true USE_MARIADB_OPERATOR=true ./scripts/setup-clusters.sh
DB_MODE=dual ENABLE_MINIO=true USE_MARIADB_OPERATOR=true ./scripts/deploy-infra.sh
```

The API runbook provisions Green through AQSH tasks. For local demos, the helper
script can still create the full sample topology in one step:

```bash
./scripts/mariadb-blue-green-demo.sh apply
```

The script is only a scenario bootstrap helper. The API flow below uses AQSH
tasks for provisioning, validation, and switchover.

Get tokens and endpoint URLs:

```bash
source .env
TOKEN=$(kubectl --context kind-cluster-apps -n app-a create token test-client --duration=30m)
MARIADB_AQSH_A_URL="http://${CLUSTER_DBS_A_IP}:30081"
MARIADB_AQSH_B_URL="http://${CLUSTER_DBS_B_IP}:30081"
```

## Provision Green

Create a physical backup from Blue on cluster A. This is different from the
generic backup task: it creates a `PhysicalBackup` CR and returns the S3
descriptor that Green will use for bootstrap.

```bash
curl -s -X POST "${MARIADB_AQSH_A_URL}/tasks/blue-green%2Fcreate-physical-backup" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "mariadb-bg",
    "mdb": "mariadb-blue",
    "backup_name": "physicalbackup-blue",
    "backup_bucket": "multi-cluster",
    "backup_prefix": "mariadb-bg/blue",
    "backup_endpoint": "172.19.0.16:30092",
    "confirm": "true"
  }'
```

Poll the returned task ID. The completed result includes the contract that links
Green to Blue:

```json
{
  "source": "mariadb-blue",
  "backupName": "physicalbackup-blue",
  "bucket": "multi-cluster",
  "prefix": "mariadb-bg/blue",
  "endpoint": "172.19.0.16:30092",
  "backupContentType": "Physical"
}
```

Bootstrap Green on cluster B from that descriptor. `blue_name`, `backup_bucket`,
`backup_prefix`, and `backup_endpoint` are how Green knows which Blue backup to
use.

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

## Validate Before Switchover

Validate Blue on cluster A:

```bash
curl -s -X POST "${MARIADB_AQSH_A_URL}/tasks/blue-green%2Fvalidate" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "mariadb-bg",
    "mdb": "mariadb-blue",
    "expected_version": "10.6",
    "expected_primary": "mariadb-blue"
  }'
```

Validate Green on cluster B:

```bash
curl -s -X POST "${MARIADB_AQSH_B_URL}/tasks/blue-green%2Fvalidate" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "mariadb-bg",
    "mdb": "mariadb-green",
    "expected_version": "10.11",
    "expected_primary": "mariadb-blue"
  }'
```

Poll the returned task IDs with `GET /tasks/<id>` until each task completes.

## Switchover

The switchover order avoids a temporary dual-primary intent. After Blue is in
maintenance/read-only mode, update Blue to follow Green before promoting Green.
The tasks are not a cross-cluster atomic transaction, so callers must wait for
each task to complete before starting the next step.

Put Blue into maintenance/read-only mode:

```bash
curl -s -X POST "${MARIADB_AQSH_A_URL}/tasks/blue-green%2Fmaintenance" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "mariadb-bg",
    "mdb": "mariadb-blue",
    "confirm": "true"
  }'
```

Demote Blue so it follows Green:

```bash
curl -s -X POST "${MARIADB_AQSH_A_URL}/tasks/blue-green%2Fset-primary" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "mariadb-bg",
    "mdb": "mariadb-blue",
    "primary": "mariadb-green",
    "confirm": "true"
  }'
```

Promote Green:

```bash
curl -s -X POST "${MARIADB_AQSH_B_URL}/tasks/blue-green%2Fset-primary" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "mariadb-bg",
    "mdb": "mariadb-green",
    "primary": "mariadb-green",
    "confirm": "true"
  }'
```

Validate that both clusters now point to Green:

```bash
curl -s -X POST "${MARIADB_AQSH_A_URL}/tasks/blue-green%2Fvalidate" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "mariadb-bg",
    "mdb": "mariadb-blue",
    "expected_primary": "mariadb-green"
  }'

curl -s -X POST "${MARIADB_AQSH_B_URL}/tasks/blue-green%2Fvalidate" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "mariadb-bg",
    "mdb": "mariadb-green",
    "expected_version": "10.11",
    "expected_primary": "mariadb-green"
  }'
```

Verify Green accepts writes after switchover:

```bash
curl -s -X POST "${MARIADB_AQSH_B_URL}/tasks/blue-green%2Fwrite-probe" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "mariadb-bg",
    "mdb": "mariadb-green",
    "confirm": "true",
    "id": "2",
    "note": "written-after-switchover"
  }'
```

## Status

Read either cluster status:

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
