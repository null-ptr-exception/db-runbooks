# db-runbooks

Multi-cluster sandbox for database operations automation with aqsh, kube-auth-proxy, kube-federated-auth, and mariadb-operator across 3-4 Kind clusters.

## kubectl Contexts

| Context | Cluster | Purpose |
|---------|---------|---------|
| kind-cluster-a | cluster-a | Server-side: kube-federated-auth, aqsh, Redis, databases, operators |
| kind-cluster-b | cluster-b | Client-side: test-client workloads |

## Namespaces

| Namespace | Clusters | Purpose |
|-----------|----------|---------|
| db-ops | cluster-a, cluster-b | Control plane (federated auth, aqsh, credentials) |
| istio-system | cluster-a, cluster-b | Istio control plane |
| istio-ingress | cluster-a, cluster-b | Istio ingress gateway |
| app-a | cluster-b | Test-client workloads |
| db-1, db-2, db-3 | cluster-a | MariaDB instances (mariadb suite) |
| mongo-1, mongo-2, mongo-3 | cluster-a | MongoDB instances (mongodb suite) |

Always specify `--context` when running kubectl commands.

## Container Images

- `ghcr.io/rophy/kube-federated-auth:3.2.0`
- `ghcr.io/rophy/kube-auth-proxy:0.4.1`
- `ghcr.io/null-ptr-exception/aqsh:0.4.0` (base for `aqsh-tasks` custom image)

## aqsh Tasks

Task scripts live in `aqsh-tasks/scripts/` and are baked into the `aqsh-tasks` Docker image via `aqsh-tasks/Dockerfile`. Skaffold manages the build lifecycle.

## Quick Start

```bash
# Run aqsh test suite (creates clusters + infra automatically)
bats tests/aqsh/

# Run with teardown
TEARDOWN=true bats tests/aqsh/

# Clean up everything
kind delete cluster --name cluster-a
kind delete cluster --name cluster-b
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_MODE` | `single` | Cluster topology: `single` or `dual` |
| `USE_MARIADB_OPERATOR` | `true` | Use mariadb-operator (`true`) or native StatefulSet (`false`) |
| `ENABLE_MINIO` | `false` | Deploy optional MinIO cluster for backups |

## Optional Components

### MinIO Cluster (ENABLE_MINIO=true)

When enabled, creates an independent `cluster-minio` for object storage:
- **Access**: Via nginx HTTP gateway at `http://{cluster-dbs-ip}:30083/minio/*`
- **Direct API**: NodePort 30092 on cluster-minio
- **Console**: NodePort 30093 on cluster-minio
- **Federated Auth**: Integrated with kube-federated-auth (cluster-minio tokens trusted by cluster-auth)
- **Storage**: 5Gi PersistentVolumeClaim
- **Use Cases**: Database backups via aqsh tasks, manual backup storage

**Architecture**:
```
test-client (cluster-apps)
    │ Bearer Token
    ▼
nginx HTTP gateway (cluster-dbs:30083)
    ├─ /mariadb/*  → aqsh-mariadb:4180
    ├─ /mongodb/*  → aqsh-mongodb:4180
    └─ /minio/*    → MinIO API (cluster-minio:30092)
```

## Port Allocation

| Service | Cluster | Port | Mode | Notes |
|---------|---------|------|------|-------|
| kube-federated-auth | cluster-auth | 30080 | All | Auth server |
| aqsh-mariadb | cluster-dbs | 30081 | All | MariaDB task API |
| aqsh-mongodb | cluster-dbs | 30082 | All | MongoDB task API |
| **nginx HTTP gateway** | **cluster-dbs** | **30083** | **ENABLE_MINIO=true** | **HTTP proxy for aqsh + MinIO** |
| MongoDB peer (NodePort) | cluster-dbs-a/b | 30090 | dual | Replication target |
| MariaDB peer (NodePort) | cluster-dbs-a/b | 30091 | dual | Replication target |
| **MinIO API** | **cluster-minio** | **30092** | **ENABLE_MINIO=true** | **S3-compatible API** |
| **MinIO Console** | **cluster-minio** | **30093** | **ENABLE_MINIO=true** | **Web UI** |

**No port conflicts**: MinIO uses 30092-30093 on cluster-minio; dual-mode DB NodePorts use 30090-30091 on cluster-dbs-a/b.
