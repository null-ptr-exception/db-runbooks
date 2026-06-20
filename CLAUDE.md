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
X is internal config, not a task input. `credential_secret`, `credential_user`,
`credential_user_key`, `credential_pass_key`, `sts_name`, `recovery_configmap`,
`data_path`, `mount_path` (MongoDB recovery/account/sanity-check tasks) follow
this pattern.

**Resolution order** (3 tiers, implemented per-script — see
`aqsh-tasks/scripts/mongodb/recovery/pre-check.sh` for a worked example):

1. Task input — only non-empty if the caller explicitly passed it (YAML
   `default: ""`, not a literal)
2. Internal config — sourced into a `*_DEFAULT`-suffixed env var
   (e.g. `MONGO_STS_NAME_DEFAULT`), set once per deployment
3. Library hardcoded fallback — keeps zero-config use working

```bash
[[ -f /etc/aqsh/config/mongodb.env ]] && source /etc/aqsh/config/mongodb.env
_STS="${MONGO_STS_NAME:-${MONGO_STS_NAME_DEFAULT:-mongodb}}"
```

A distinct `*_DEFAULT` variable name (rather than reusing the task-input env
var name) is deliberate: sourcing the internal config file can never silently
clobber an explicit caller override, because it writes to a different name.

If a value like this also gates RBAC (e.g. `resourceNames` pinned to a
StatefulSet/Secret/ConfigMap name), template the RBAC chart from the same
chart values that produce the internal config, so a non-default convention
doesn't get silently denied — see `tests/chart/templates/mongodb-rbac.yaml`.

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
