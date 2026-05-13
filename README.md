# db-runbooks

A multi-cluster sandbox for database operations automation. Uses [aqsh](https://github.com/null-ptr-exception/aqsh) to execute runbook tasks against MariaDB and MongoDB, with cross-cluster authentication via [kube-auth-proxy](https://github.com/rophy/kube-auth-proxy) and [kube-federated-auth](https://github.com/rophy/kube-federated-auth).

## Overview

A test-client in **cluster-apps** submits tasks to aqsh in **cluster-dbs**, authenticating with its own Kubernetes ServiceAccount token. The token is validated across clusters via kube-federated-auth in **cluster-auth**.

```
cluster-apps                  cluster-dbs                                      cluster-auth
┌──────────────┐             ┌──────────────────────────────────────────────┐  ┌──────────────────────┐
│  test-client │──Bearer──▶  │  ┌──────────────────────────────────────┐   │  │  kube-federated-auth │
│  (SA token)  │  :30081     │  │ kube-auth-proxy :4180                │   │  │   ├─ cluster-auth     │
│              │             │  │   └─▶ aqsh-mariadb :8080             │───┼─▶│   ├─ cluster-dbs      │
│              │             │  │        tasks: restart, common/hello  │   │  │   └─ cluster-apps     │
│              │             │  └──────────────────────────────────────┘   │  └──────────────────────┘
│              │             │                                              │
│              │──Bearer──▶  │  ┌──────────────────────────────────────┐   │
│              │  :30082     │  │ kube-auth-proxy :4180                │───┼─▶ (same kube-federated-auth)
│              │             │  │   └─▶ aqsh-mongodb :8080             │   │
│              │             │  │        tasks: restart, sanity-check,  │   │
│              │             │  │               common/hello           │   │
│              │             │  └──────────────────────────────────────┘   │
│              │             │                                              │
└──────────────┘             │  Redis  MariaDB×3  MongoDB×3                │
                             └──────────────────────────────────────────────┘
```

## Components

| Cluster | Component | Role |
|---------|-----------|------|
| cluster-auth | [kube-federated-auth](https://github.com/rophy/kube-federated-auth) | Validates SA tokens from all 3 clusters via JWKS detection + TokenReview forwarding |
| cluster-dbs | [aqsh-mariadb](https://github.com/null-ptr-exception/aqsh) | Async task queue for MariaDB runbooks — exposes `restart` task on NodePort 30081 |
| cluster-dbs | [aqsh-mongodb](https://github.com/null-ptr-exception/aqsh) | Async task queue for MongoDB runbooks — exposes `restart` + `sanity-check` tasks on NodePort 30082 |
| cluster-dbs | [kube-auth-proxy](https://github.com/rophy/kube-auth-proxy) | Sidecar (one per aqsh) that authenticates requests and injects identity headers |
| cluster-dbs | Redis | Shared message broker for both aqsh task queues |
| cluster-dbs | MariaDB (via mariadb-operator) | Three MariaDB instances (10.6, 10.11, 11.4) managed by operator |
| cluster-dbs | MongoDB | Three MongoDB 7 instances as StatefulSets |
| cluster-apps | test-client | Pod (curlimages/curl) that sends authenticated requests to aqsh |

## Request Flow

1. **test-client** (cluster-apps) sends `POST /tasks/<task>` with its SA token as Bearer
2. **kube-auth-proxy** intercepts and sends a TokenReview to kube-federated-auth
3. **kube-federated-auth** detects the token belongs to cluster-apps via JWKS, forwards the TokenReview to cluster-apps API server, returns the validated identity
4. **kube-auth-proxy** sets `X-Forwarded-User` / `X-Forwarded-Groups` / `X-Forwarded-Extra-Cluster-Name`, strips `Authorization`, proxies to aqsh
5. **aqsh** checks `allowed_groups`, accepts the task, and executes the script asynchronously

## Namespaces

| Namespace | Cluster | Purpose |
|-----------|---------|---------|
| `db-ops` | cluster-auth, cluster-dbs, cluster-apps | Control plane — federated auth, aqsh, credentials |
| `mariadb-1` (10.6), `mariadb-2` (10.11), `mariadb-3` (11.4) | cluster-dbs | MariaDB instances |
| `mongo-1`, `mongo-2`, `mongo-3` | cluster-dbs | MongoDB 7 instances |
| `app-a`, `app-b` | cluster-apps | Per-application client workloads |

## Cross-Cluster Networking

Kind clusters share the `kind` Docker bridge network. Services are exposed via NodePort:

| Service | Cluster | NodePort |
|---------|---------|----------|
| kube-federated-auth | cluster-auth | 30080 |
| aqsh-mariadb (via kube-auth-proxy) | cluster-dbs | 30081 |
| aqsh-mongodb (via kube-auth-proxy) | cluster-dbs | 30082 |

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) — must be installed manually
- [kind](https://kind.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) (`v1.30.0` recommended — matches the in-pod version)
- [Helm](https://helm.sh/)
- [Skaffold](https://skaffold.dev/)
- `jq`, `curl`, `python3`, `envsubst` (from `gettext-base`)

> **`scripts/preflight.sh` auto-installs everything except Docker.** It downloads `kind`, `kubectl`, `helm`, and `skaffold` to `/usr/local/bin` if missing, and installs apt packages (`jq`, `curl`, `python3`, `gettext-base`) automatically. `setup.sh` runs it as Phase 0.

## Quick Start

```bash
# Create clusters, deploy everything, and run tests
# (runs preflight automatically — installs missing tools)
./scripts/setup.sh

# Check/install prerequisites only
./scripts/preflight.sh

# Step by step:
./scripts/setup-clusters.sh      # Create 3 Kind clusters
./scripts/deploy.sh              # Deploy all components
./scripts/test.sh                # Run all tests
```

## Available Tasks

Tasks are submitted to `POST /tasks/<name>` with a JSON body. All tasks require a valid Kubernetes ServiceAccount token as Bearer.

| Task | Endpoint | Description | Input | Docs |
|------|----------|-------------|-------|------|
| `common/hello` | aqsh-mariadb `:30081` or aqsh-mongodb `:30082` | Greeting smoke test | `name` (string, required) | — |
| `restart` | aqsh-mariadb `:30081` | Rolling restart of a MariaDB StatefulSet | `namespace` — `^mariadb-[0-9]+$` | [docs/mariadb/restart.md](docs/mariadb/restart.md) |
| `restart` | aqsh-mongodb `:30082` | Rolling restart of a MongoDB StatefulSet | `namespace` — `^mongo-[0-9]+$` | [docs/mongodb/restart.md](docs/mongodb/restart.md) |
| `sanity-check` | aqsh-mongodb `:30082` | 3-layer health check (K8s + connectivity + internals) | `namespace` — `^mongo-[0-9]+$` | [docs/mongodb/sanity-check.md](docs/mongodb/sanity-check.md) |

### Task API

```bash
TOKEN=$(kubectl --context kind-cluster-apps -n app-a create token test-client --duration=10m)
MARIADB_AQSH_URL="http://<cluster-dbs-ip>:30081"
MONGODB_AQSH_URL="http://<cluster-dbs-ip>:30082"

# Submit a MariaDB restart task
curl -s -X POST "$MARIADB_AQSH_URL/tasks/restart" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mariadb-1"}'
# → {"id": "abc123", "status": "pending"}

# Submit a MongoDB sanity-check task
curl -s -X POST "$MONGODB_AQSH_URL/tasks/sanity-check" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mongo-1"}'

# Poll for status
curl -s "$MARIADB_AQSH_URL/tasks/abc123" -H "Authorization: Bearer $TOKEN"
# → {"id": "abc123", "status": "completed", "result": {...}}

# Stream logs
curl -s "$MARIADB_AQSH_URL/tasks/abc123/logs?follow=false" -H "Authorization: Bearer $TOKEN"
```

## Development

### Project Structure

```
aqsh-tasks/
├── Dockerfile              # Installs kubectl + mongosh + mariadb-client; ARG TASKS_YAML selects config
├── tasks-mariadb.yaml      # MariaDB task definitions (restart, common/hello)
├── tasks-mongodb.yaml      # MongoDB task definitions (restart, sanity-check, common/hello)
├── lib/                    # Shared Bash libraries (vendored from mongodb-manager)
│   ├── logging.sh          # Structured logging with levels
│   ├── response.sh         # Standard JSON response builder
│   ├── k8s.sh              # 40+ kubectl helper functions
│   ├── mongodb.sh          # 30+ mongosh helper functions
│   └── sanity_check.sh     # 3-layer MongoDB health check
└── scripts/
    ├── common/hello.sh
    ├── mariadb/restart.sh
    └── mongodb/
        ├── restart.sh
        └── sanity-check.sh
```

### Shared Libraries

Scripts source libraries from `/tasks/lib/`:

```bash
source /tasks/lib/logging.sh   # log_info / log_error / log_debug
source /tasks/lib/response.sh  # response_ok / response_err (JSON)
source /tasks/lib/k8s.sh       # k8s_get_pods / k8s_rollout_restart / ...
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
skaffold build --tag=latest
kind load docker-image aqsh-mariadb:latest --name cluster-dbs
kind load docker-image aqsh-mongodb:latest --name cluster-dbs
kubectl --context kind-cluster-dbs -n db-ops rollout restart deployment/aqsh-mariadb
kubectl --context kind-cluster-dbs -n db-ops rollout restart deployment/aqsh-mongodb
```

## Testing

```bash
./scripts/test.sh              # Run all tests (common + mariadb + mongodb)
```

> **Note:** `tests/common/test.sh`, `tests/mariadb/test.sh`, and `tests/mongodb/test.sh` are not standalone scripts — they are sourced by `scripts/test.sh` and depend on env vars and helper functions (`pass()`, `fail()`, `run_cmd()`) provided by the parent script. Always use `./scripts/test.sh` to run tests.

Tests 1, 2a–2b cover infrastructure and unauthenticated checks. Tests 3–5b cover `common/hello` (both aqsh instances) + log streaming. Test 6 covers in-pod requests to both NodePorts. Tests 7–9 cover `restart` via aqsh-mariadb. Tests 10–12 cover `sanity-check` and `restart` via aqsh-mongodb.

## Teardown

```bash
./scripts/teardown.sh
```

## Project Structure

```
aqsh-tasks/
  Dockerfile                # Custom image: aqsh base + kubectl + mongosh + mariadb-client; ARG TASKS_YAML
  tasks-mariadb.yaml        # MariaDB task definitions
  tasks-mongodb.yaml        # MongoDB task definitions
  lib/                      # Shared Bash libraries
  scripts/
    common/hello.sh
    mariadb/restart.sh
    mongodb/
      restart.sh
      sanity-check.sh

scripts/
  preflight.sh              # Check and auto-install host prerequisites
  setup.sh                  # Orchestrator (runs preflight → clusters → deploy → test)
  setup-clusters.sh         # Create Kind clusters, extract IPs → .env
  setup-credentials.sh      # Bootstrap cross-cluster CA certs + tokens
  deploy.sh                 # Build image + deploy manifests in dependency order
  test.sh                   # End-to-end validation
  teardown.sh               # Delete clusters

k8s/
  cluster-auth/             # kube-federated-auth manifests
  cluster-dbs/              # aqsh + kube-auth-proxy + Redis + MariaDB + MongoDB manifests
  cluster-apps/             # test-client manifests
```

## Image Versions

| Image | Version |
|-------|---------|
| ghcr.io/rophy/kube-federated-auth | 3.2.0 |
| ghcr.io/rophy/kube-auth-proxy | 0.4.1 |
| ghcr.io/null-ptr-exception/aqsh | 0.4.0 |
| aqsh-mariadb | local build (Skaffold, TASKS_YAML=tasks-mariadb.yaml) |
| aqsh-mongodb | local build (Skaffold, TASKS_YAML=tasks-mongodb.yaml) |
| mariadb-operator (Helm) | latest |
| mariadb | 10.6, 10.11, 11.4 |
| mongodb | 7.0 |
| redis | 7-alpine |
