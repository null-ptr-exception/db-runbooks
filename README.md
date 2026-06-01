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
| **aqsh-mariadb** | cluster-dbs | Async task queue for MariaDB (restart, sanity-check, create-account, backup*) | 30081 |
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

> **Dual-mode**: Set `DB_MODE=dual` to create `cluster-dbs-a` and `cluster-dbs-b` instead of single `cluster-dbs`, enabling peer-to-peer replication testing.

---

## 🔌 Port Allocation

| Service | Cluster | Port | Mode | Notes |
|---------|---------|------|------|-------|
| kube-federated-auth | cluster-auth | **30080** | All | Auth server |
| aqsh-mariadb | cluster-dbs | **30081** | All | MariaDB tasks |
| aqsh-mongodb | cluster-dbs | **30082** | All | MongoDB tasks |
| nginx HTTP gateway | cluster-dbs | **30083** | `ENABLE_MINIO=true` | HTTP proxy |
| MongoDB peer | cluster-dbs-a/b | 30090 | `DB_MODE=dual` | Replication |
| MariaDB peer | cluster-dbs-a/b | 30091 | `DB_MODE=dual` | Replication |
| MinIO API | cluster-minio | **30092** | `ENABLE_MINIO=true` | S3 API |
| MinIO Console | cluster-minio | **30093** | `ENABLE_MINIO=true` | Web UI |

---

## ⚙️ Environment Variables

| Variable | Default | Options | Description |
|----------|---------|---------|-------------|
| `DB_MODE` | `single` | `single`, `dual` | Cluster topology (1 or 2 DB clusters) |
| `USE_MARIADB_OPERATOR` | `true` | `true`, `false` | Use operator or native StatefulSet |
| `ENABLE_MINIO` | `false` | `true`, `false` | Deploy optional MinIO cluster |

**Examples**:
```bash
# Dual-mode with native MariaDB + MinIO
DB_MODE=dual USE_MARIADB_OPERATOR=false ENABLE_MINIO=true ./scripts/setup.sh
```

---

## 📋 Available Tasks

Submit tasks via `POST /tasks/<name>` with Bearer token + JSON body.

| Task | Endpoint | Description | Input | Docs |
|------|----------|-------------|-------|------|
| `common/hello` | `:30081` or `:30082` | Smoke test (greeting) | `name` (string) | — |
| `restart` | `:30081` (MariaDB) | Rolling restart StatefulSet | `namespace` (e.g., `mariadb-1`) | [docs/mariadb/restart.md](docs/mariadb/restart.md) |
| `status` | `:30081` (MariaDB) | Read-only operator/StatefulSet/pod/SQL status summary | `namespace`, optional `context`, `resource`, `mdb`, `container`, `include_sql` | [docs/mariadb/status.md](docs/mariadb/status.md) |
| `sanity-check` | `:30081` (MariaDB) | Read-only health check (operator + service + SQL + replication + semi-sync) | `namespace`, optional `context`, `resource`, `mdb`, thresholds | [docs/mariadb/sanity-check.md](docs/mariadb/sanity-check.md) |
| `create-account` | `:30081` (MariaDB) | Create a new user and grant scoped database privileges | `namespace`, `database`, `username`, `privileges`, `password_secret_name` when creating a new account | [docs/mariadb/create-account.md](docs/mariadb/create-account.md) |
| `restart` | `:30082` (MongoDB) | Rolling restart StatefulSet | `namespace` (e.g., `mongo-1`) | [docs/mongodb/restart.md](docs/mongodb/restart.md) |
| `sanity-check` | `:30082` (MongoDB) | 3-layer health check | `namespace` | [docs/mongodb/sanity-check.md](docs/mongodb/sanity-check.md) |
| `backup`* | `:30081` or `:30082` | Backup to MinIO | `namespace`, `bucket` (optional) | — |

\* Only available when `ENABLE_MINIO=true` and Phase 5 is implemented

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
├── tasks-mariadb.yaml      # Task definitions: restart, sanity-check, common/hello, backup*
├── tasks-mongodb.yaml      # Task definitions: restart, sanity-check, common/hello, backup*
├── lib/                    # Shared Bash libraries
│   ├── logging.sh          # log_info / log_error / log_debug
│   ├── response.sh         # response_ok / response_err (JSON helpers)
│   ├── k8s.sh              # kubectl wrappers with retry/wait
│   ├── mariadb.sh          # MariaDB SQL / replication helper functions
│   ├── mongodb.sh          # mongosh wrappers, RS status helpers
│   ├── mongodb_constant.sh # Sanity-check scoring constants
│   ├── minio-client.sh*    # MinIO client setup (when ENABLE_MINIO=true)
│   └── custom.sh           # Extensible custom check hooks
└── scripts/
    ├── common/hello.sh
    ├── mariadb/
    │   ├── restart.sh
    │   ├── sanity-check.sh
    │   ├── create-account.sh
    │   └── operator-sanity-check.sh
    ├── mongodb/
    │   ├── restart.sh
    │   └── sanity-check.sh
    └── backup/             # Created in Phase 5
        ├── backup-mariadb.sh*
        └── backup-mongodb.sh*

scripts/
├── preflight.sh            # Auto-install prerequisites (kind, kubectl, helm, skaffold)
├── setup.sh                # Orchestrator (preflight → clusters → infra → databases)
├── setup-clusters.sh       # Create Kind clusters, extract IPs → .env
├── setup-credentials.sh    # Bootstrap cross-cluster CA certs + tokens
├── deploy-infra.sh         # Deploy federated-auth, aqsh, nginx, MinIO
├── deploy.sh               # Deploy databases (MariaDB + MongoDB)
├── test.sh                 # End-to-end validation
└── teardown.sh             # Delete all clusters

k8s/
├── cluster-auth/           # kube-federated-auth + ConfigMaps (4 variants for dual/minio combos)
├── cluster-dbs/            # aqsh + kube-auth-proxy + Redis + MariaDB + MongoDB + nginx
├── cluster-apps/           # test-client pod
├── cluster-minio/          # MinIO deployment + PVC + RBAC (when ENABLE_MINIO=true)
└── nginx-proxy/            # nginx HTTP+stream configs

tests/
├── common/                 # Auth + hello task tests
├── mariadb/                # MariaDB restart tests
├── mongodb/                # MongoDB restart + sanity-check tests
└── minio/                  # MinIO deployment + backup tests (Phase 6)
```

### Iterating on Task Scripts

Scripts source libraries from `/tasks/lib/`:

```bash
source /tasks/lib/logging.sh   # log_info / log_error / log_debug
source /tasks/lib/response.sh  # response_ok / response_err (JSON)
source /tasks/lib/k8s.sh       # k8s_get_pods / k8s_rollout_restart / ...
source /tasks/lib/mariadb.sh   # MariaDB operator SQL / replication helpers
source /tasks/lib/mongodb.sh   # mongo_check / mongo_rs_status / ...
```

See [docs/lib/](docs/lib/) for full API reference.

### Writing a New Task Script

Every task script receives inputs as environment variables (declared in `tasks-mariadb.yaml` / `tasks-mongodb.yaml`) and must write its JSON result to `$AQSH_RESULT_FILE`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Inputs injected by aqsh (declared in tasks-mariadb.yaml / tasks-mongodb.yaml)
echo "Running against namespace: $DB_NAMESPACE"

# ... do work ...

jq -n --arg ns "$DB_NAMESPACE" '{"namespace": $ns, "status": "done"}' \
  > "$AQSH_RESULT_FILE"
```

### Iterating on Tasks

After editing scripts or `tasks-mariadb.yaml` / `tasks-mongodb.yaml`:

```bash
# Rebuild and redeploy aqsh task image
./scripts/deploy-infra.sh
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
- MinIO (optional): deployment, nginx proxy routing, backup tasks

---

## 📦 Prerequisites

- **Docker**
- **[Kind](https://kind.sigs.k8s.io/)** (v0.31.0+)
- **[BATS](https://bats-core.readthedocs.io/)** (test runner)
- **[mise](https://mise.jdx.dev/)** (runtime version manager)

Run `./scripts/preflight.sh` to install all tools. If prerequisites are already installed, `mise trust && mise install` refreshes tool versions only.

### CI

CI runs on [self-hosted aws-runners](https://github.com/null-ptr-exception/aws-runners) with all prerequisites pre-installed.

---

## 🐳 Image Versions

| Image | Version | Source |
|-------|---------|--------|
| kube-federated-auth | 3.2.0 | ghcr.io/rophy/kube-federated-auth |
| kube-auth-proxy | 0.4.1 | ghcr.io/rophy/kube-auth-proxy |
| aqsh (base) | 0.4.0 | ghcr.io/null-ptr-exception/aqsh |
| db-runbooks | local / main tag | Single task image built via Skaffold for Kind; main publishes `ghcr.io/null-ptr-exception/db-runbooks:yyyymmdd-short_sha` |
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
