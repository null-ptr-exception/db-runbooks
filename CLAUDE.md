# db-runbooks

Multi-region sandbox for database operations automation with aqsh, kube-auth-proxy, kube-federated-auth, mariadb-operator, and MinIO across 3 Kind clusters.

## kubectl Contexts

| Context | Cluster | Purpose |
|---------|---------|---------|
| kind-cluster-region-a | cluster-region-a | Primary region: kube-federated-auth + mariadb-operator + aqsh + nginx + Redis |
| kind-cluster-region-b | cluster-region-b | Secondary region: same stack, replicates from region-a (multi mode only) |
| kind-cluster-apps-minio | cluster-apps-minio | MinIO backup target + test-client workloads |

## Namespaces

| Namespace | Clusters | Purpose |
|-----------|----------|---------|
| db-ops | cluster-region-a, cluster-region-b | Control plane (federated auth, aqsh, Redis, nginx) |
| mariadb-1 (10.6), mariadb-2 (10.11), mariadb-3 (11.4) | cluster-region-a, cluster-region-b | MariaDB instances |
| mongo-1, mongo-2, mongo-3 | cluster-region-a, cluster-region-b | MongoDB replica sets |
| minio | cluster-apps-minio | MinIO S3-compatible backup storage |
| app-a, app-b | cluster-apps-minio | Per-application test-client workloads |

Always specify `--context` when running kubectl commands.

## NodePort Reference

| Service | NodePort | Cluster(s) |
|---------|---------|------------|
| nginx HTTP gateway (`/mariadb/*`, `/mongodb/*`) | 30080 | region-a, region-b |
| kube-federated-auth | 30081 | region-a, region-b |
| aqsh-mariadb (direct) | 30082 | region-a, region-b |
| aqsh-mongodb (direct) | 30083 | region-a, region-b |
| nginx stream → mongodb.mongo-1 | 30092 | region-a, region-b |
| nginx stream → mariadb.mariadb-1 | 30093 | region-a, region-b |
| nginx stream → mongodb.mongo-2 | 30094 | region-a, region-b |
| nginx stream → mariadb.mariadb-2 | 30095 | region-a, region-b |
| nginx stream → mongodb.mongo-3 | 30096 | region-a, region-b |
| nginx stream → mariadb.mariadb-3 | 30097 | region-a, region-b |
| MinIO API | 30090 | apps-minio |
| MinIO console | 30091 | apps-minio |

## Container Images

- `ghcr.io/rophy/kube-federated-auth:3.2.0`
- `ghcr.io/rophy/kube-auth-proxy:0.4.1`
- `ghcr.io/null-ptr-exception/aqsh:0.4.0` (base for `aqsh-tasks` custom image)
- `minio/minio:latest`
- `nginx:alpine` (HTTP gateway + TCP stream proxy)

## aqsh Tasks

Task scripts live in `aqsh-tasks/scripts/` and are baked into the `aqsh-tasks` Docker image via `aqsh-tasks/Dockerfile`. Skaffold manages the build lifecycle.

Cross-region aqsh calls use `REMOTE_AQSH_URL` env var:
- region-a aqsh → `http://${REGION_B_IP}:30080/mariadb` (via region-b nginx)
- region-b aqsh → `http://${REGION_A_IP}:30080/mariadb` (via region-a nginx)

## Quick Start

```bash
# Single region (region-a + apps-minio)
make single

# Multi region (region-a + region-b + apps-minio, with cross-region replication)
make multi
# make multi MONGO_REPLICATION_MODE=3+1

# Tear everything down
make down

# Run tests
make test-unit          # BATS unit tests only (no cluster)
make test-mariadb       # spin up → test → tear down
make test-mongodb       # spin up → test → tear down
make test-quick-mariadb # assumes cluster is running
```

## Environment Variables (.env)

| Variable | Description |
|----------|-------------|
| `MODE` | `single` or `multi` |
| `REGION_A_IP` | Kind node IP for cluster-region-a |
| `REGION_B_IP` | Kind node IP for cluster-region-b (multi only) |
| `APPS_MINIO_IP` | Kind node IP for cluster-apps-minio |
| `ISSUER_REGION_A` | OIDC issuer URL of cluster-region-a |
| `ISSUER_REGION_B` | OIDC issuer URL of cluster-region-b (multi only) |
| `ISSUER_APPS_MINIO` | OIDC issuer URL of cluster-apps-minio |
| `MONGO_FLAVOR` | `official` (mongo:7) or `percona` (PSMDB + PBM) |
| `MONGO_REPLICATION_MODE` | Mongo RS expansion mode in multi: `3+3` (default) or `3+1` |

## MongoDB Replica Sets

Each namespace (mongo-1/2/3) forms its own RS:
- `rs-mongo-1` in mongo-1 namespace
- `rs-mongo-2` in mongo-2 namespace
- `rs-mongo-3` in mongo-3 namespace

In single mode: 1-member RS per namespace (region-a only).
In multi mode:
- `MONGO_REPLICATION_MODE=3+3` (default): region-b secondary is added to mongo-1/2/3
- `MONGO_REPLICATION_MODE=3+1`: only mongo-1 adds region-b secondary; mongo-2/3 stay single-member in region-a

Cross-cluster RS connectivity: region-a's RS members reach region-b members via region-b's nginx TCP proxy (NodePorts 30092/30094/30096).

## MariaDB Replication

Region-a is primary; region-b is async replica. Replication is managed by mariadb-operator (`spec.replication`) with region-b `externalPrimary` pointing to region-a nginx NodePort (30093/30095/30097). If operator version lacks `externalPrimary`, setup falls back to script `CHANGE MASTER TO` with operator-managed replication prerequisites enabled by CR patch.

Failover: `scripts/mariadb-failover.sh` promotes region-b to writable primary.
