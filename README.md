# db-runbooks

**2-cluster sandbox for database operations automation** with federated authentication and async task queues.

Built with [aqsh](https://github.com/null-ptr-exception/aqsh), [kube-auth-proxy](https://github.com/rophy/kube-auth-proxy), [kube-federated-auth](https://github.com/rophy/kube-federated-auth), and [mariadb-operator](https://github.com/mariadb-operator/mariadb-operator).

---

## 🚀 Quick Start

```bash
# 1. Install prerequisites (kind, kubectl, helm, helmfile, ctlptl, bats, ...)
./scripts/preflight.sh

# 2. Run a suite — setup_suite.bash brings up the Kind clusters, shared infra
#    (Cilium + Istio + CoreDNS), builds/deploys the aqsh image, and runs the
#    tests, all in one shot. Each suite is independent and self-contained.
bats tests/mongodb/
bats tests/mariadb/

# Teardown: delete the Kind clusters + local registry
kind delete cluster --name cluster-a
kind delete cluster --name cluster-b
docker rm -f registry
```

There is no separate "deploy then test" step — `setup_suite()`/`teardown_suite()`
in each suite's `setup_suite.bash` own the full lifecycle for that bats run.

---

## 📐 Architecture

```
test-client (cluster-b)
    │ Bearer Token
    ▼
Istio Gateway (cluster-a:30080)
    ├─ aqsh-mariadb.kind-a.test → aqsh (mariadb tasks)
    ├─ aqsh-mongodb.kind-a.test → aqsh (mongodb tasks)
    └─ fedauth.kind-a.test      → kube-federated-auth

Istio Gateway (cluster-b:30080)
    └─ minio.kind-b.test        → MinIO API

Namespace-local database gateway (cluster-a / mariadb-1)
    ├─ :3306 → mariadb-operator primary Service
    └─ :3307 → mariadb-operator secondary Service
```

The database gateway is a separate Envoy Deployment and Service owned by the
MariaDB namespace. It models database-namespace lifecycle and ownership; it
does not add MariaDB routes to the shared control-plane gateway.

Cross-cluster DNS: `*.kind-a.test` → cluster-a IP, `*.kind-b.test` → cluster-b
IP (via CoreDNS) — this only resolves *inside* the clusters, so API calls are
made from a pod (e.g. `test-client`), not from the host.

| Context | Cluster | Purpose |
|---------|---------|---------|
| `kind-cluster-a` | cluster-a | Server: aqsh, federated auth, Redis, DB instances, Istio gateway |
| `kind-cluster-b` | cluster-b | Client: test-client, MinIO, Istio gateway |

| Namespace | Cluster | Purpose |
|-----------|---------|---------|
| `mongo-core` | cluster-a, cluster-b | MongoDB control plane (aqsh, fedauth, test-client) |
| `db-ops` | cluster-a, cluster-b | MariaDB control plane (aqsh, fedauth, test-client) |
| `mongo-1` | cluster-a | MongoDB instance |
| `mariadb-1` | cluster-a | MariaDB instance (operator-managed) |
| `minio` | cluster-b | MinIO object storage |

See [CLAUDE.md](CLAUDE.md) for the full architecture reference, including the
configuration-layers convention (task input vs. internal config vs. live
auto-detection) used by the MongoDB account/recovery tasks.

---

## 🔐 Request Flow

1. **Client** (`test-client` in cluster-b) sends `POST /tasks/<task>` through the Istio gateway, with a ServiceAccount Bearer token
2. **kube-auth-proxy** (sidecar in front of aqsh) intercepts the request and sends a TokenReview to **kube-federated-auth**
3. **kube-federated-auth** detects the token's issuing cluster via JWKS and forwards the TokenReview to that cluster's API server
4. **kube-auth-proxy** receives the validated identity, injects `X-Forwarded-User`/`X-Forwarded-Groups` headers, and proxies to **aqsh**
5. **aqsh** checks `allowed_groups` and runs the task script asynchronously, polled via `GET /executions/<id>`

---

## 🧩 Components

| Component | Cluster | Role |
|-----------|---------|------|
| **kube-federated-auth** | cluster-a | Cross-cluster token validator (JWKS + TokenReview forwarding) |
| **kube-auth-proxy** | cluster-a | Auth sidecar in front of aqsh (injects identity headers) |
| **aqsh-mariadb** | cluster-a | Async task queue for MariaDB (restart, status, create-account, blue-green/\*, backup) |
| **aqsh-mongodb** | cluster-a | Async task queue for MongoDB (restart, sanity-check, account lifecycle, recovery/\*, backup) |
| **Redis** | cluster-a | Shared task queue broker for aqsh |
| **MariaDB** | cluster-a | Single instance via mariadb-operator (`mariadb-1`) |
| **Database gateway** | cluster-a | Namespace-local Envoy gateway for MariaDB primary/secondary TCP routing |
| **MongoDB** | cluster-a | Single StatefulSet instance (`mongo-1`) |
| **MinIO** | cluster-b | S3-compatible object storage for backup tasks |
| **test-client** | cluster-b | curl pod with a projected ServiceAccount token, used to call aqsh through the gateway |

---

## 📋 Available Tasks

Submit via `POST /tasks/<name>` (URL-encode `/` as `%2F` for namespaced task
names) with a Bearer token + JSON body; poll `GET /executions/<id>`.

**MariaDB** (`aqsh-mariadb.kind-a.test:30080`):

| Task | Description | Docs |
|------|-------------|------|
| `common/hello` | Smoke test | — |
| `restart` | Operator-driven restart via the MariaDB CR's restart annotation | [docs/mariadb/restart.md](docs/mariadb/restart.md) |
| `status` | Read-only operator/StatefulSet/pod/SQL status summary | [docs/mariadb/status.md](docs/mariadb/status.md) |
| `sanity-check` | Operator → service/pods → SQL → replication → semi-sync health check | [docs/mariadb/sanity-check.md](docs/mariadb/sanity-check.md) |
| `create-account` | Create a user and grant scoped database privileges | [docs/mariadb/create-account.md](docs/mariadb/create-account.md) |
| `blue-green/status`, `/create`, `/switchover`, `/delete` | Blue/green deployment lifecycle on top of mariadb-operator | [docs/mariadb/blue-green.md](docs/mariadb/blue-green.md) |
| `backup` | Backup to MinIO | — |

**MongoDB** (`aqsh-mongodb.kind-a.test:30080`):

| Task | Description | Docs |
|------|-------------|------|
| `common/hello` | Smoke test | — |
| `restart` | Rolling restart of the MongoDB StatefulSet | [docs/mongodb/restart.md](docs/mongodb/restart.md) |
| `sanity-check` | Kubernetes infra → connectivity → MongoDB-internals health check | [docs/mongodb/sanity-check.md](docs/mongodb/sanity-check.md) |
| `create-account`, `delete-account`, `ban-account`, `extend-expiry`, `update-account-roles`, `force-permanent`, `reset-password`, `reconcile-expiry` | Run-account lifecycle management | [docs/mongodb/account-lifecycle.md](docs/mongodb/account-lifecycle.md) |
| `recovery/pre-check`, `/wipe`, `/reset`, `/status`, `/fix-no-primary`, `/recover` | Replica-set member recovery (gate checks, wipe + resync, no-primary diagnosis) | [docs/mongodb/recovery.md](docs/mongodb/recovery.md) |
| `reconfig/plan`, `/apply`, `/force-dr`, `/freeze` | Gated replica-set reconfig (risk report → CAS apply, break-glass DR, change freeze) | [docs/mongodb/reconfig.md](docs/mongodb/reconfig.md) |
| `fcv/status`, `fcv/set` | featureCompatibilityVersion report + gated upgrade/downgrade validated against the binary version | [docs/mongodb/fcv.md](docs/mongodb/fcv.md) |
| `backup` | Backup to MinIO | — |

### Task API Example

API calls must originate from inside the cluster (the `*.kind-a.test` /
`*.kind-b.test` hostnames only resolve via the clusters' own CoreDNS), so
real usage runs them from the `test-client` pod:

```bash
TOKEN=$(kubectl --context kind-cluster-b -n mongo-core create token test-client --duration=10m)

# Submit
RESPONSE=$(kubectl --context kind-cluster-b -n mongo-core exec deploy/test-client -- \
  curl -s -X POST "http://aqsh-mongodb.kind-a.test:30080/tasks/restart" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mongo-1"}')
echo "$RESPONSE"
# → {"id": "abc123", "status": "pending"}

TASK_ID=$(echo "$RESPONSE" | jq -r '.id')

# Poll
kubectl --context kind-cluster-b -n mongo-core exec deploy/test-client -- \
  curl -s "http://aqsh-mongodb.kind-a.test:30080/executions/$TASK_ID" \
  -H "Authorization: Bearer $TOKEN" | jq .
```

---

## 🛠️ Development

### Project Structure

```
Dockerfile                  # Base: aqsh + kubectl + mongosh + mariadb-client
aqsh-tasks/
├── task-mariadb.yaml       # Main config (AQSH_TASKS_CONFIG): defaults + include tasks-mariadb.yaml
├── task-mongodb.yaml       # Main config (AQSH_TASKS_CONFIG): defaults + include tasks-mongodb.yaml
├── tasks-mariadb.yaml      # Task definitions: restart, status, create-account, blue-green/*, backup, ...
├── tasks-mongodb.yaml      # Task definitions: restart, sanity-check, account lifecycle, recovery/*, backup, ...
├── config/                 # Deploy-time internal config (*.env), mounted at /etc/aqsh/config/
│   ├── mariadb.env
│   └── mongodb.env
├── lib/                    # Shared Bash libraries (logging, response, k8s, mariadb, mongodb, mongodb-recovery, ...)
└── scripts/
    ├── common/hello.sh
    ├── mariadb/             # restart, status, create-account, sanity-check, blue-green/*
    ├── mongodb/             # restart, sanity-check, account lifecycle, recovery/*
    └── backup/

infra/
├── ctlptl-infra.yaml        # Kind cluster definitions + local registry
├── helmfile-infra.yaml      # Cilium, Istio, shared gateway
└── deploy.sh                # setup_infra() — idempotent, shared by every suite

tests/
├── chart/                   # Shared Helm chart used by every suite's helmfile.yaml
├── mariadb/                 # helmfile.yaml + setup_suite.bash + *.bats
├── mongodb/                 # helmfile.yaml + setup_suite.bash + *.bats
├── unit/                    # Mocked-kubectl unit tests for aqsh-tasks/lib
└── test_helper/             # bats-support / bats-assert / bats-mock (cloned by preflight.sh)

scripts/
└── preflight.sh              # Installs/checks all required tooling (kind, mise-managed kubectl/helm/helmfile/ctlptl, bats, helm-diff)

docs/
├── lib/                      # aqsh-tasks/lib/*.sh API reference
├── mariadb/                  # Per-task runbooks
└── mongodb/                  # Per-task runbooks
```

### Writing a New Task Script

Every task script receives inputs as environment variables (declared in
`tasks-mariadb.yaml` / `tasks-mongodb.yaml`) and writes its JSON result to
`$AQSH_RESULT_FILE`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source /tasks/lib/logging.sh

log_info "Running against namespace: $DB_NAMESPACE"
# ... do work ...

jq -n --arg ns "$DB_NAMESPACE" '{"namespace": $ns, "status": "done"}' \
  > "$AQSH_RESULT_FILE"
```

1. Add the script under `aqsh-tasks/scripts/<db>/my-task.sh`.
2. Declare it in `tasks-<db>.yaml`:
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
3. Keep the task's input surface small — see CLAUDE.md "Configuration Layers"
   for when a value belongs in `input:` vs. `aqsh-tasks/config/*.env` vs. a
   hardcoded library fallback.
4. See [docs/lib/](docs/lib/) for the full `aqsh-tasks/lib/*.sh` API reference.

### Iterating

Each suite's `setup_suite.bash` rebuilds and pushes the aqsh image to the
local registry (`localhost:5005/db-runbooks:latest`) on every run, so editing
a script or task YAML just means re-running `bats tests/<db>/`.

---

## 🧪 Testing

```bash
bats tests/mongodb/
bats tests/mariadb/
bats --recursive tests/unit   # mocked-kubectl unit tests for aqsh-tasks/lib
```

CI (`.github/workflows/ci.yaml`) runs ShellCheck + Hadolint + unit tests in a
`lint` job, builds the task image, and runs the `mariadb` and `mongodb` bats
suites against fresh Kind clusters per job.

---

## 📦 Prerequisites

- **Docker**
- **[mise](https://mise.jdx.dev/)** (manages `kubectl`/`helm`/`helmfile`/`ctlptl`/`skaffold` versions per `.mise.toml`)
- **[Kind](https://kind.sigs.k8s.io/)**, **[BATS](https://bats-core.readthedocs.io/)**, `jq`

Run `./scripts/preflight.sh` — it installs everything above (plus the
`helm-diff` plugin helmfile needs) into `~/.local/bin` / mise, and clones the
bats test helpers.

### CI

CI runs on self-hosted runners with prerequisites pre-installed; `preflight.sh`
runs anyway at the start of the `lint` job to keep them current.

---

## 🐳 Image Versions

| Image | Version | Source |
|-------|---------|--------|
| kube-federated-auth | 3.2.0 | `ghcr.io/rophy/kube-federated-auth` |
| kube-auth-proxy | 0.4.1 | `ghcr.io/rophy/kube-auth-proxy` |
| aqsh (base) | 0.5.0 | `ghcr.io/null-ptr-exception/aqsh` |
| db-runbooks | local `latest` tag for tests; `main` publishes `ghcr.io/<repo>:yyyymmdd-short_sha` | Built from this repo's `Dockerfile` |
| mariadb | 10.6 | Official MariaDB image, via mariadb-operator |
| mongodb | 7.0.21 | Official MongoDB image |
| minio | latest | Official MinIO image |

---

## 📄 License

MIT

---

## 🤝 Contributing

1. Follow existing code style (ShellCheck + yamllint pass)
2. Add `.bats` coverage for new tasks
3. Update `docs/` for user-facing changes, and CLAUDE.md for architecture/convention changes

---

## 🔗 Related Projects

- [aqsh](https://github.com/null-ptr-exception/aqsh) - Kubernetes-native async task queue
- [kube-auth-proxy](https://github.com/rophy/kube-auth-proxy) - Cross-cluster auth sidecar
- [kube-federated-auth](https://github.com/rophy/kube-federated-auth) - Multi-cluster OIDC validator
- [mariadb-operator](https://github.com/mariadb-operator/mariadb-operator) - Kubernetes MariaDB operator
