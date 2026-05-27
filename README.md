# db-runbooks

**Multi-cluster database operations automation sandbox** with federated authentication, async task queues, and optional object storage for backups.

Built with [aqsh](https://github.com/null-ptr-exception/aqsh), [kube-auth-proxy](https://github.com/rophy/kube-auth-proxy), [kube-federated-auth](https://github.com/rophy/kube-federated-auth), and [mariadb-operator](https://github.com/mariadb-operator/mariadb-operator).

---

## 🚀 Quick Start

```bash
# Standard setup (3 clusters: auth + dbs + apps)
./scripts/setup.sh

# With MinIO for backups (4 clusters: auth + dbs + apps + minio)
ENABLE_MINIO=true ./scripts/setup.sh

# Teardown everything
./scripts/teardown.sh
```

<details>
<summary>Step-by-step setup</summary>

```bash
# 1. Create clusters
./scripts/setup-clusters.sh
# or with MinIO:
ENABLE_MINIO=true ./scripts/setup-clusters.sh

# 2. Deploy infrastructure
./scripts/deploy-infra.sh

# 3. Deploy databases
./scripts/deploy.sh

# 4. Run tests
./scripts/test.sh
```

</details>

---

## 📐 Architecture

### Standard Mode (3 clusters)

```
┌─────────────────────┐   Bearer Token    ┌──────────────────────────────────┐   TokenReview   ┌─────────────────────┐
│   cluster-apps      │ ─────────────────▶│      cluster-dbs                 │ ───────────────▶│   cluster-auth      │
│                     │                   │                                  │                 │                     │
│  test-client pod    │  :30081 MariaDB   │  kube-auth-proxy :4180           │                 │  kube-federated-   │
│  (ServiceAccount)   │  :30082 MongoDB   │    └─▶ aqsh-mariadb :8080        │◀────────────────│  auth :30080        │
│                     │                   │    └─▶ aqsh-mongodb :8080        │   Validated     │                     │
│  Namespaces:        │                   │                                  │   Identity      │  Trusts 3 clusters  │
│  - app-a            │                   │  Redis (shared task queue)       │                 │  via JWKS + CA      │
│  - app-b            │                   │  MariaDB×3 (10.6, 10.11, 11.4)   │                 │                     │
└─────────────────────┘                   │  MongoDB×3 (7.0)                 │                 └─────────────────────┘
                                          └──────────────────────────────────┘
```

### With MinIO Enabled (4 clusters)

```
┌─────────────────────┐                   ┌──────────────────────────────────┐                 ┌─────────────────────┐
│   cluster-apps      │                   │      cluster-dbs                 │                 │   cluster-minio     │
│                     │   Bearer Token    │                                  │                 │                     │
│  test-client pod    │ ─────────────────▶│  nginx HTTP gateway :30083       │ ──────────────▶ │  MinIO :9000        │
│  (ServiceAccount)   │                   │    /mariadb/* → aqsh-mariadb     │   Proxy         │  (S3-compatible)    │
│                     │                   │    /mongodb/* → aqsh-mongodb     │   /minio/*      │                     │
│  Submit tasks +     │                   │    /minio/*   → MinIO API        │                 │  NodePort:          │
│  backup requests    │                   │                                  │                 │  - API: 30092       │
└─────────────────────┘                   │  aqsh-mariadb/mongodb            │                 │  - Console: 30093   │
                                          │    └─ backup tasks               │                 │                     │
                                          │    └─ mc (MinIO client)          │                 │  Storage: 5Gi PVC   │
                                          └──────────────────────────────────┘                 └─────────────────────┘
                                                        │
                                                        │ TokenReview
                                                        ▼
                                          ┌──────────────────────────────────┐
                                          │   cluster-auth                   │
                                          │  kube-federated-auth :30080      │
                                          │  Trusts 4 clusters (incl. minio) │
                                          └──────────────────────────────────┘
```

---

## 🔐 Request Flow

1. **Client** (`test-client` in cluster-apps) sends `POST /tasks/<task>` with ServiceAccount token
2. **nginx** (optional, if MinIO enabled) routes `/mariadb/*`, `/mongodb/*`, `/minio/*` to respective backends
3. **kube-auth-proxy** intercepts, sends TokenReview to kube-federated-auth
4. **kube-federated-auth** detects issuer via JWKS, forwards TokenReview to origin cluster API server
5. **kube-auth-proxy** receives validated identity, injects headers (`X-Forwarded-User`, `X-Forwarded-Groups`), proxies to aqsh
6. **aqsh** validates `allowed_groups`, executes task script asynchronously

---

## 🧩 Components

| Component | Cluster | Role | Port |
|-----------|---------|------|------|
| **kube-federated-auth** | cluster-auth | Cross-cluster token validator (JWKS + TokenReview forwarding) | 30080 |
| **aqsh-mariadb** | cluster-dbs | Async task queue for MariaDB (restart, backup*) | 30081 |
| **aqsh-mongodb** | cluster-dbs | Async task queue for MongoDB (restart, sanity-check, backup*) | 30082 |
| **nginx HTTP gateway** | cluster-dbs | HTTP reverse proxy (aqsh + MinIO routes) | 30083* |
| **kube-auth-proxy** | cluster-dbs | Auth sidecar (injects identity headers) | 4180 |
| **Redis** | cluster-dbs | Shared message broker for aqsh queues | — |
| **MariaDB** | cluster-dbs | 3 instances (10.6, 10.11, 11.4) via mariadb-operator | — |
| **MongoDB** | cluster-dbs | 3 instances (7.0) as StatefulSets | — |
| **MinIO** | cluster-minio | S3-compatible object storage for backups | 30092*, 30093* |
| **test-client** | cluster-apps | Test pod (curlimages/curl) with SA token | — |

\* Only when `ENABLE_MINIO=true`

---

## 🌐 Cluster Topology

| Cluster | Contexts | Namespaces | Purpose |
|---------|----------|------------|---------|
| **cluster-auth** | `kind-cluster-auth` | `db-ops` | Federated authentication server |
| **cluster-dbs** | `kind-cluster-dbs` | `db-ops`, `mariadb-1/2/3`, `mongo-1/2/3` | Databases + task automation + nginx gateway |
| **cluster-apps** | `kind-cluster-apps` | `db-ops`, `app-a`, `app-b` | Client workloads |
| **cluster-minio** | `kind-cluster-minio` | `db-ops`, `minio` | Object storage (optional) |

> **Dual-mode**: Set `DB_MODE=dual` to create `cluster-dbs-a` and `cluster-dbs-b` instead of single `cluster-dbs`, enabling cross-cluster GTID replication (MariaDB) and Replica Set formation (MongoDB).

### Dual Mode (4 clusters)

```
┌──────────────────────────────────────────────────────────────────────────┐
│  cluster-dbs-a                         cluster-dbs-b                    │
│                                                                          │
│  MariaDB (GTID primary) ◀──────────────▶ MariaDB (GTID replica)         │
│  MongoDB (RS member)   ◀──────────────▶ MongoDB (RS member)             │
│  aqsh + nginx-proxy                    aqsh + nginx-proxy               │
│  NodePort: 30081/30082                 NodePort: 30081/30082            │
│  Peer NodePort: 30091 (MariaDB)        Peer NodePort: 30091 (MariaDB)   │
│                 30090 (MongoDB-0)                       30090 (MongoDB-0)│
└──────────────────────────────────────────────────────────────────────────┘
```

> **Topology variables**: `MONGO_TOPOLOGY` and `MARIADB_TOPOLOGY` control how many replicas are deployed. Defaults: `2+1` (dual mode), `standalone` (single mode).

---

## 🔌 Port Allocation

| Service | Cluster | Port | Mode | Notes |
|---------|---------|------|------|-------|
| kube-federated-auth | cluster-auth | **30080** | All | Auth server |
| aqsh-mariadb | cluster-dbs | **30081** | All | MariaDB tasks |
| aqsh-mongodb | cluster-dbs | **30082** | All | MongoDB tasks |
| nginx HTTP gateway | cluster-dbs | **30083** | `ENABLE_MINIO=true` | HTTP proxy |
| MongoDB-0 peer NodePort | cluster-dbs-a/b | 30090 | `DB_MODE=dual` | RS member 0 (cross-cluster) |
| MariaDB-0 peer NodePort | cluster-dbs-a/b | 30091 | `DB_MODE=dual` | GTID primary/replica |
| MinIO API | cluster-minio | **30092** | `ENABLE_MINIO=true` | S3 API |
| MinIO Console | cluster-minio | **30093** | `ENABLE_MINIO=true` | Web UI |
| MongoDB-1 per-pod NodePort | cluster-dbs-a/b | 30094 | `DB_MODE=dual` | RS member 1 |
| MariaDB-1 per-pod NodePort | cluster-dbs-a/b | 30095 | `DB_MODE=dual` | In-cluster replica 1 |
| MongoDB-2 per-pod NodePort | cluster-dbs-a/b | 30096 | `DB_MODE=dual` | RS member 2 |
| MariaDB-2 per-pod NodePort | cluster-dbs-a/b | 30097 | `DB_MODE=dual` | In-cluster replica 2 |

---

## ⚙️ Environment Variables

| Variable | Default | Options | Description |
|----------|---------|---------|-------------|
| `DB_MODE` | `single` | `single`, `dual` | Cluster topology (1 or 2 DB clusters) |
| `USE_MARIADB_OPERATOR` | `true` | `true`, `false` | Use operator or native StatefulSet |
| `ENABLE_MINIO` | `false` | `true`, `false` | Deploy optional MinIO cluster |
| `MONGO_TOPOLOGY` | `standalone` (single) / `2+1` (dual) | `standalone`, `2+1`, `1+2`, `3+0` | MongoDB replica count per cluster (local+remote) |
| `MARIADB_TOPOLOGY` | `standalone` (single) / `2+1` (dual) | `standalone`, `2+1`, `1+2`, `3+0` | MariaDB replica count per cluster (local+remote) |

> Topology format `X+Y`: `X` = in-cluster replicas, `Y` = cross-cluster (remote) replicas.

**Examples**:
```bash
# Dual-mode with native MariaDB + MinIO
DB_MODE=dual USE_MARIADB_OPERATOR=false ENABLE_MINIO=true ./scripts/setup.sh

# Dual-mode with custom topology (3 local MongoDB members, no cross-cluster)
DB_MODE=dual MONGO_TOPOLOGY=3+0 ./scripts/setup.sh
```

---

## 📋 Available Tasks

Submit tasks via `POST /tasks/<name>` with Bearer token + JSON body.

| Task | Endpoint | Description | Input | Docs |
|------|----------|-------------|-------|------|
| `common/hello` | `:30081` or `:30082` | Smoke test (greeting) | `name` (string) | — |
| `restart` | `:30081` (MariaDB) | Rolling restart StatefulSet | `namespace` (e.g., `mariadb-1`) | [docs/mariadb/restart.md](docs/mariadb/restart.md) |
| `restart` | `:30082` (MongoDB) | Rolling restart StatefulSet | `namespace` (e.g., `mongo-1`) | [docs/mongodb/restart.md](docs/mongodb/restart.md) |
| `sanity-check` | `:30082` (MongoDB) | 3-layer health check | `namespace` | [docs/mongodb/sanity-check.md](docs/mongodb/sanity-check.md) |
| `rs-init` | `:30082` (MongoDB) | Initialize (or verify) MongoDB Replica Set | `namespace`, `topology`, `cluster_a_ip`, `cluster_b_ip` | — |
| `setup-replication` | `:30081` (MariaDB) | Configure GTID replication between clusters | `namespace`, `topology`, `cluster_a_ip`, `cluster_b_ip` | — |
| `backup`* | `:30081` or `:30082` | Backup to MinIO | `namespace`, `bucket` (optional) | — |

\* Only available when `ENABLE_MINIO=true`

> `rs-init` and `setup-replication` are **idempotent** — safe to call multiple times. Both skip already-configured members automatically.

### Task API Example

```bash
# Get token
TOKEN=$(kubectl --context kind-cluster-apps -n app-a create token test-client --duration=10m)

# Get cluster IP
CLUSTER_DBS_IP=$(docker inspect cluster-dbs-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

# Submit MariaDB restart
curl -X POST "http://${CLUSTER_DBS_IP}:30081/tasks/restart" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mariadb-1"}'
# → {"id": "abc123", "status": "pending"}

# Poll status
curl "http://${CLUSTER_DBS_IP}:30081/tasks/abc123" -H "Authorization: Bearer $TOKEN"
# → {"id": "abc123", "status": "completed", "result": {...}}

# Stream logs
curl "http://${CLUSTER_DBS_IP}:30081/tasks/abc123/logs?follow=false" -H "Authorization: Bearer $TOKEN"
```

### Access MinIO (when enabled)

```bash
# Via nginx proxy
curl "http://${CLUSTER_DBS_IP}:30083/minio/health/live"

# Direct API (30092) or Console (30093)
CLUSTER_MINIO_IP=$(docker inspect cluster-minio-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
curl "http://${CLUSTER_MINIO_IP}:30092/minio/health/live"
open "http://${CLUSTER_MINIO_IP}:30093"  # Web UI
```

---

## 🛠️ Development

### Project Structure

```
aqsh-tasks/
├── Dockerfile              # Base: aqsh + kubectl + mongosh + mariadb-client (+ mc if ENABLE_MINIO)
├── tasks-mariadb.yaml      # Task definitions: restart, setup-replication, common/hello, backup*
├── tasks-mongodb.yaml      # Task definitions: restart, rs-init, sanity-check, common/hello, backup*
├── lib/                    # Shared Bash libraries
│   ├── logging.sh          # log_info / log_error / log_debug
│   ├── response.sh         # response_ok / response_err (JSON helpers)
│   ├── k8s.sh              # kubectl wrappers with retry/wait
│   ├── mongodb.sh          # mongosh wrappers, RS status helpers
│   ├── mongodb_constant.sh # Sanity-check scoring constants
│   ├── minio-client.sh*    # MinIO client setup (when ENABLE_MINIO=true)
│   └── custom.sh           # Extensible custom check hooks
└── scripts/
    ├── common/hello.sh
    ├── mariadb/
    │   ├── restart.sh
    │   └── setup-replication.sh  # GTID replication setup (idempotent)
    ├── mongodb/
    │   ├── restart.sh
    │   ├── rs-init.sh            # RS initialization (idempotent, multi-topology)
    │   └── sanity-check.sh
    └── backup/
        ├── backup-mariadb.sh*
        └── backup-mongodb.sh*

scripts/
├── preflight.sh            # Auto-install prerequisites (kind, kubectl, helm, skaffold)
├── setup.sh                # Orchestrator (preflight → clusters → infra → databases)
├── setup-clusters.sh       # Create Kind clusters, extract IPs + TOPOLOGY vars → .env
├── setup-credentials.sh    # Bootstrap cross-cluster CA certs + tokens
├── deploy-infra.sh         # Deploy federated-auth, aqsh, nginx, MinIO
│                           # Also preloads mongo:7 + mariadb:10.6 images (Step 5.5)
├── deploy.sh               # Deploy databases (MariaDB + MongoDB)
├── test.sh                 # End-to-end validation
└── teardown.sh             # Delete all clusters

k8s/
├── cluster-auth/           # kube-federated-auth + ConfigMaps (4 variants for dual/minio combos)
├── cluster-dbs/
│   ├── mariadb/
│   │   ├── statefulset.yaml          # GTID binlog + dynamic server-id via pod ordinal
│   │   ├── nodeport-service.yaml     # Targets pod-name=mariadb-0
│   │   ├── nodeport-pod1.yaml        # Port 30095 (pod 1)
│   │   └── nodeport-pod2.yaml        # Port 30097 (pod 2)
│   └── mongodb/
│       ├── mongo-1-rs.yaml.tpl       # RS-mode StatefulSet (--replSet rs0)
│       ├── nodeport-pod0.yaml        # Port 30090 (pod 0)
│       ├── nodeport-pod1.yaml        # Port 30094 (pod 1)
│       └── nodeport-pod2.yaml        # Port 30096 (pod 2)
├── cluster-apps/           # test-client pod
├── cluster-minio/          # MinIO deployment + PVC + RBAC (when ENABLE_MINIO=true)
└── nginx-proxy/            # nginx HTTP+stream configs

tests/
├── setup_suite.bash        # Suite-level DB deployment (deploy once, not per-file)
├── test_helper/
│   └── common_setup.bash   # skip_unless_*_topology, assert_*_ready, deploy_*_with_topology
├── common/                 # Auth + hello task + in-pod tests
├── mariadb/
│   ├── restart.bats
│   └── replication.bats    # GTID setup-replication + correctness (REQUIRED_TOPOLOGY=2+1)
├── mongodb/
│   ├── restart.bats
│   ├── rs_init.bats         # RS init idempotency (skips if MONGO_TOPOLOGY=standalone)
│   ├── replication.bats    # RS formation + peer connectivity (REQUIRED_TOPOLOGY=2+1)
│   └── sanity_check.bats
└── minio/                  # MinIO deployment + backup tests
```

### Iterating on Task Scripts

After editing `aqsh-tasks/scripts/` or `tasks-*.yaml`:

```bash
# Rebuild images
skaffold build --tag=latest

# Load into cluster
kind load docker-image aqsh-mariadb:latest --name cluster-dbs
kind load docker-image aqsh-mongodb:latest --name cluster-dbs

# Restart deployments
kubectl --context kind-cluster-dbs -n db-ops rollout restart deployment/aqsh-mariadb
kubectl --context kind-cluster-dbs -n db-ops rollout restart deployment/aqsh-mongodb
```

### Writing New Tasks

1. Create script in `aqsh-tasks/scripts/<db>/my-task.sh`
2. Add task definition to `tasks-<db>.yaml`:
   ```yaml
   my-task:
     script: <db>/my-task.sh
     description: "What this task does"
     timeout: 5m
     allowed_groups: ["system:serviceaccounts"]
     input:
       - name: namespace
         env: DB_NAMESPACE
         required: true
   ```
3. Use libraries:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   source /tasks/lib/logging.sh
   source /tasks/lib/response.sh
   
   log_info "Starting task for $DB_NAMESPACE"
   # ... do work ...
   response_ok '{"status": "done"}' > "$AQSH_RESULT_FILE"
   ```

See [docs/lib/](docs/lib/) for library API reference.

---

## 🧪 Testing

```bash
# Run all tests
./scripts/test.sh

# With MinIO tests (if ENABLE_MINIO=true)
ENABLE_MINIO=true ./scripts/test.sh
```

**Test Coverage**:
- Infrastructure: federated-auth health, unauthenticated requests → 401
- Task execution: `common/hello`, `restart`, `sanity-check`
- Log streaming: `/tasks/<id>/logs`
- In-pod requests: test-client → aqsh via NodePort
- Replication (dual mode, `MONGO_TOPOLOGY=2+1`): MongoDB RS init, RS correctness, MongoDB peer-proxy connectivity
- Replication (dual mode, `MARIADB_TOPOLOGY=2+1`): MariaDB GTID setup-replication, data written on primary readable on replica (30s lag window)
- MinIO (optional): deployment, nginx proxy routing, backup tasks

**Topology-aware skipping**: Tests declare `REQUIRED_MONGO_TOPOLOGY` / `REQUIRED_MARIADB_TOPOLOGY` and are automatically skipped when the deployed topology doesn't match (e.g., replication tests skip in `standalone` mode).

---

## 📦 Prerequisites

- **Docker** (required, install manually)
- kind, kubectl, helm, skaffold, jq, curl, python3, envsubst

> **Auto-install**: Run `./scripts/preflight.sh` or `./scripts/setup.sh` (includes preflight as Phase 0). Everything except Docker is installed automatically.

---

## 🐳 Image Versions

| Image | Version | Source |
|-------|---------|--------|
| kube-federated-auth | 3.2.0 | ghcr.io/rophy/kube-federated-auth |
| kube-auth-proxy | 0.4.1 | ghcr.io/rophy/kube-auth-proxy |
| aqsh (base) | 0.4.0 | ghcr.io/null-ptr-exception/aqsh |
| aqsh-mariadb | local | Built via Skaffold (TASKS_YAML=tasks-mariadb.yaml) |
| aqsh-mongodb | local | Built via Skaffold (TASKS_YAML=tasks-mongodb.yaml) |
| mariadb-operator | latest | Deployed via Helm |
| mariadb | 10.6, 10.11, 11.4 | Official MariaDB images |
| mongodb | 7.0 | Official MongoDB image |
| minio | latest | Official MinIO image |
| redis | 7-alpine | Official Redis image |

---

## 📄 License

MIT

---

## 🤝 Contributing

Contributions welcome! Please:
1. Follow existing code style (shellcheck + yamllint pass)
2. Add tests for new tasks
3. Update docs for user-facing changes

---

## 🔗 Related Projects

- [aqsh](https://github.com/null-ptr-exception/aqsh) - Kubernetes-native async task queue
- [kube-auth-proxy](https://github.com/rophy/kube-auth-proxy) - Cross-cluster auth sidecar
- [kube-federated-auth](https://github.com/rophy/kube-federated-auth) - Multi-cluster OIDC validator
- [mariadb-operator](https://github.com/mariadb-operator/mariadb-operator) - Kubernetes MariaDB operator
