# db-runbooks

Multi-cluster sandbox for database operations automation with aqsh, kube-auth-proxy, kube-federated-auth, and mariadb-operator across 3 Kind clusters.

## kubectl Contexts

| Context | Cluster | Purpose |
|---------|---------|---------|
| kind-cluster-auth | cluster-auth | kube-federated-auth server |
| kind-cluster-dbs | cluster-dbs | mariadb-operator + aqsh-mariadb + aqsh-mongodb + kube-auth-proxy + Redis |
| kind-cluster-apps | cluster-apps | test-client workloads |

## Namespaces

| Namespace | Clusters | Purpose |
|-----------|----------|---------|
| db-ops | cluster-auth, cluster-dbs, cluster-apps | Control plane (federated auth, aqsh, credentials) |
| db-1 (10.6), db-2 (10.11), db-3 (11.4) | cluster-dbs | MariaDB instances |
| app-a, app-b | cluster-apps | Per-application client workloads |

Always specify `--context` when running kubectl commands.

## Container Images

- `ghcr.io/rophy/kube-federated-auth:3.2.0`
- `ghcr.io/rophy/kube-auth-proxy:0.4.1`
- `ghcr.io/null-ptr-exception/aqsh:0.4.0` (base for `aqsh-tasks` custom image)

## aqsh Tasks

Task scripts live in `aqsh-tasks/scripts/` and are baked into the `aqsh-tasks` Docker image via `aqsh-tasks/Dockerfile`. Skaffold manages the build lifecycle.

## Quick Start

```bash
scripts/setup.sh    # Create clusters, deploy, test
scripts/teardown.sh # Clean up everything
```
