# db-runbooks

Multi-cluster sandbox for database operations automation with aqsh, kube-auth-proxy, kube-federated-auth across 2 Kind clusters.

## kubectl Contexts

| Context | Cluster | Purpose |
|---------|---------|---------|
| kind-cluster-a | cluster-a | Server-side: kube-federated-auth, aqsh, Redis, databases, operators |
| kind-cluster-b | cluster-b | Client-side: test-client workloads, MinIO backup target |

Always specify `--context` when running kubectl commands.

## Namespaces

| Namespace | Cluster | Purpose |
|-----------|---------|---------|
| db-ops | cluster-a | Control plane (federated auth, aqsh, Redis) |
| db-ops | cluster-b | Federated auth RBAC |
| istio-system | both | Istio control plane |
| istio-ingress | both | Istio ingress gateway |
| app-a | cluster-b | Test-client workloads |
| mariadb-1 | cluster-a | MariaDB instance (mariadb suites) |
| mariadb-2 | cluster-b | MariaDB instance (mariadb-native replication) |
| mongo-1 | cluster-a | MongoDB instance (mongodb suite) |
| mongo-2 | cluster-b | MongoDB instance (mongodb replication) |
| minio | cluster-b | MinIO backup target (mariadb/mongodb suites) |

## Container Images

- `ghcr.io/rophy/kube-federated-auth:3.2.0`
- `ghcr.io/rophy/kube-auth-proxy:0.4.1`
- `ghcr.io/null-ptr-exception/aqsh:0.4.0` (base for `aqsh-tasks` custom image)

## aqsh Tasks

Task scripts live in `aqsh-tasks/scripts/` and are baked into the `aqsh-tasks` Docker image via `aqsh-tasks/Dockerfile`. Skaffold manages the build lifecycle. Task configs: `aqsh-tasks/tasks-mariadb.yaml`, `aqsh-tasks/tasks-mongodb.yaml`.

## Quick Start

```bash
# Run aqsh test suite (creates clusters + infra automatically)
bats tests/aqsh/

# Run specific suite
bats tests/mongodb/
bats tests/mariadb-native/
bats tests/mariadb-operator/

# Run with teardown
TEARDOWN=true bats tests/aqsh/

# Clean up everything
kind delete cluster --name cluster-a
kind delete cluster --name cluster-b
```

## Test Suites

| Suite | Description | Infra |
|-------|-------------|-------|
| aqsh | Framework, auth, hello tasks | clusters + platform + aqsh |
| mongodb | MongoDB restart, sanity, replication, backup | + MongoDB on both clusters + MinIO |
| mariadb-native | MariaDB (StatefulSet) restart, sanity, replication, backup | + MariaDB on both clusters + MinIO |
| mariadb-operator | MariaDB (operator CRD) restart, sanity, backup | + mariadb-operator + MariaDB CR + MinIO |

Each suite sources the aqsh `setup_suite.bash` for shared infra (Layers 1-3), then adds its own database and MinIO setup.

## Networking

- **DNS**: CoreDNS `template` plugin resolves `*.kind-a.test` → cluster-a Docker IP, `*.kind-b.test` → cluster-b Docker IP
- **HTTP ingress**: Istio Gateway on port 80 (NodePort 30080) with `*.kind-a.test` hosts
- **TCP ingress**: Istio TCP Gateways for MongoDB (27017/30090) and MariaDB (3306/30091)
- **MinIO**: Via Istio HTTP Gateway on cluster-b (minio.kind-b.test:30080)

## Port Allocation

| Service | Cluster | NodePort | Notes |
|---------|---------|----------|-------|
| Istio HTTP Gateway | cluster-a | 30080 | aqsh, fedauth VirtualServices |
| MongoDB TCP Gateway | both | 30090 | Cross-cluster replication |
| MariaDB TCP Gateway | both | 30091 | Cross-cluster replication |
| MinIO (via Istio) | cluster-b | 30080 | S3-compatible backup target (minio.kind-b.test) |
