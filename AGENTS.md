# db-runbooks

2-cluster sandbox for database operations automation with aqsh, kube-auth-proxy, kube-federated-auth, and mariadb-operator on Kind clusters.

## kubectl Contexts

| Context | Cluster | Purpose |
|---------|---------|---------|
| kind-cluster-a | cluster-a | Server: aqsh, federated auth, Redis, DB instances, Istio gateway |
| kind-cluster-b | cluster-b | Client: test-client, MinIO, Istio gateway |

Always specify `--context` when running kubectl commands.

## Architecture

```text
test-client (cluster-b)
    │ Bearer Token
    ▼
Istio Gateway (cluster-a:30080)
    ├─ aqsh-mariadb.kind-a.test → aqsh (mariadb tasks)
    ├─ aqsh-mongodb.kind-a.test → aqsh (mongodb tasks)
    └─ fedauth.kind-a.test      → kube-federated-auth

Istio Gateway (cluster-b:30080)
    └─ minio.kind-b.test        → MinIO API
```

Cross-cluster DNS: `*.kind-a.test` → cluster-a IP, `*.kind-b.test` → cluster-b IP (via CoreDNS).

## Namespaces

| Namespace | Cluster | Purpose |
|-----------|---------|---------|
| mongo-core | cluster-a, cluster-b | MongoDB control plane (aqsh, fedauth, test-client) |
| db-ops | cluster-a, cluster-b | MariaDB control plane (aqsh, fedauth, test-client) |
| mongo-1 | cluster-a | MongoDB instance |
| mariadb-1 | cluster-a | MariaDB instance (operator-managed) |
| minio | cluster-b | MinIO object storage |

## Container Images

- `ghcr.io/rophy/kube-federated-auth:3.2.0`
- `ghcr.io/rophy/kube-auth-proxy:0.4.1`
- `ghcr.io/null-ptr-exception/aqsh:0.5.0` (base for `aqsh-tasks` custom image)

## aqsh Tasks

Task scripts live in `aqsh-tasks/scripts/` and are baked into the Docker image via `Dockerfile`.

Deploy-time configuration lives in `aqsh-tasks/config/` (e.g., `mongodb.env`, `mariadb.env`) and is mounted into aqsh at `/etc/aqsh/config/` via ConfigMap.

## Configuration Layers

When adding a new task parameter, decide which layer it belongs to:

- **Internal config** (`aqsh-tasks/config/*.env` → ConfigMap → `/etc/aqsh/config/*.env`,
  sourced by scripts) — for values that are fixed for a given deployment but
  vary *across* deployments: secret/StatefulSet naming conventions, credential
  key names, data/mount paths per image type. A given corporate environment
  doesn't change these between calls; they describe how that environment is
  built.
- **API spec** (`input:` in `tasks-*.yaml`) — for values a caller legitimately
  picks differently on different calls within the *same* deployment: target
  namespace/pod, force flags, account usernames, escalation levels.

**Rule of thumb**: if two environments could reasonably want different
values for X, but one environment wants the *same* value of X on every call,
X is internal config, not a task input.

That rule is what belongs here. How each tier actually works, and which
combination a given task family uses, is in
[`docs/internal/resolution-tiers.md`](docs/internal/resolution-tiers.md):

- the three-tier chain for account tasks (task input → internal config →
  library fallback), and why the internal-config variable carries a distinct
  `*_DEFAULT` suffix
- the **Auto-detect tier** used by `recovery/*`, `reconfig/*`, `fcv/*`, `pbm/*`,
  `sts/*`, `oplog/*`, `ops/*`, `profiler/*` and `mql/*` — these query live
  cluster state rather than guessing an image profile, fail *soft* when they
  find no confident signal, and do not expose the resolved fields as task
  inputs at all
- how `wipe`/`recover` patch a missing `data-recovery` init container into the
  StatefulSet rather than failing the gate that checks for it (gate G1 of
  `recovery/*`'s eight pre-flight gates), and revert it afterwards
- the `secrets/*` and `pods/*` contracts, and `blue-green/*` — the one family
  that does expose its resolution fields as task inputs
- a per-family registry table, kept honest by
  `tests/unit/aqsh/resolution_registry_drift.bats`

MariaDB object storage resolves by its own four-tier order, and none of its
fields are public task inputs — see
[`docs/mariadb/object-storage-resolution.md`](docs/mariadb/object-storage-resolution.md).

## Test Suites

Each DB type has its own test suite under `tests/<db>/` with:
- `helmfile.yaml` — defines Helm releases for the suite
- `setup_suite.bash` — builds image, deploys via helmfile, waits for readiness
- `*.bats` — test files using bats-core

```bash
# Run a single suite
bats tests/mongodb/
bats tests/mariadb/

# Shared infra (Istio, Cilium, CoreDNS) is managed by infra/
```

## Infrastructure

Shared infra is in `infra/` and is deployed by each suite's `setup_suite.bash`:
- `infra/ctlptl-infra.yaml` — Kind cluster definitions + local registry
- `infra/helmfile-infra.yaml` — Cilium, Istio, shared gateway
- `infra/deploy.sh` — `setup_infra` function (idempotent)

## Port Allocation

| Service | Port | Notes |
|---------|------|-------|
| Istio HTTP Gateway | 30080 | Both clusters, routes by hostname |
| Istio HTTPS Gateway | 30443 | Both clusters |
| Istio MongoDB | 30090 | Passthrough |
| Istio MariaDB | 30091 | Passthrough |
