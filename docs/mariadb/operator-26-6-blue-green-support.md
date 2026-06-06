# MariaDB Operator 26.6 Blue/Green Support Evidence

## Bottom line

`mariadb-operator` 26.6.0 is blue-green capable, but it is not a packaged
one-click blue-green workflow.

The precise statement is:

> MariaDB operator 26.6.0 supports blue-green deployments through multi-cluster
> topology, physical-backup bootstrap, maintenance mode, and cluster switchover
> primitives. It does not introduce a standalone `BlueGreenDeployment` CRD.

This distinction matters when discussing the release. Saying "26.6 supports
blue-green" is accurate when we mean the operator provides the required
building blocks and documented switchover flow. Saying "26.6 does not have
blue-green" is only accurate if we mean there is no dedicated, fully automated
blue-green API.

## Official evidence

Official release:

- <https://github.com/mariadb-operator/mariadb-operator/releases/tag/26.6.0>

The 26.6.0 release notes introduce multi-cluster topology and describe it as a
capability for "zero-downtime blue-green deployments". The same release also
introduces maintenance mode, which is explicitly positioned for safe switchover
windows.

Official multi-cluster docs:

- <https://github.com/mariadb-operator/mariadb-operator/blob/26.6.0/docs/multi-cluster.md>

The multi-cluster docs list "Blue-green deployments" as a use case. They also
describe the required lifecycle:

- provision a primary MariaDB cluster;
- take a `PhysicalBackup`;
- bootstrap a replica cluster from that backup;
- keep the replica cluster replicating from the primary;
- put the primary into maintenance/read-only mode;
- promote the replica cluster by changing `spec.multiCluster.primary`;
- update external application traffic manually.

Official maintenance docs:

- <https://github.com/mariadb-operator/mariadb-operator/blob/26.6.0/docs/maintenance.md>

Maintenance mode provides the operational guardrails needed before promotion:
cordon new connections, drain existing connections, and set the database to
read-only.

## What is not in 26.6.0

The 26.6.0 examples catalog contains generic multi-cluster examples:

- `examples/manifests/multi-cluster/replication/`
- `examples/manifests/multi-cluster/replication-maxscale/`
- `examples/manifests/multi-cluster/galera/`
- `examples/manifests/multi-cluster/galera-maxscale/`

It does not include a dedicated `replication-blue-green` or
`replication-blue-green-cross-cluster` example.

The branch
<https://github.com/yangminglintw/mariadb-operator/tree/test/aws-blue-green-scenario>
adds that missing scenario layer. It does not add operator implementation code;
it documents and demonstrates how to combine the 26.6 primitives into an
AWS-style blue/green upgrade:

- Blue runs MariaDB 10.6.
- Green restores Blue's physical backup.
- Green is upgraded to MariaDB 10.11.
- Green stays in sync through multi-cluster replication.
- Switchover uses maintenance mode and `spec.multiCluster.primary` patches.

## db-runbooks runbook

This repository turns the upstream primitives into AQSH tasks documented in
[blue-green.md](blue-green.md).

Expected setup:

```bash
DB_MODE=dual ENABLE_MINIO=true ./scripts/setup-clusters.sh
DB_MODE=dual ENABLE_MINIO=true ./scripts/deploy-infra.sh
```

Create the demo scenario:

```bash
./scripts/mariadb-blue-green-demo.sh apply
```

The bootstrap script creates the sample Blue/Green MariaDB resources. Runbook
actions are then performed through `aqsh-mariadb` tasks:

- `blue-green/status`
- `blue-green/validate`
- `blue-green/create-physical-backup`
- `blue-green/bootstrap-green`
- `blue-green/upgrade-green`
- `blue-green/maintenance`
- `blue-green/set-primary`
- `blue-green/write-probe`

## Acceptance criteria

The demo proves the blue-green path when all of the following are true:

- Blue reports MariaDB `10.6.x`.
- Green restores from Blue's `PhysicalBackup`.
- Green reports MariaDB `10.11.x` after upgrade.
- A write through Blue replicates to Green before switchover.
- Green replication reports `slaveIORunning=true`, `slaveSQLRunning=true`, and
  `secondsBehindMaster=0`.
- Switchover puts Blue into maintenance/read-only mode, updates Blue to follow
  Green, promotes Green, and verifies that Green accepts writes.
