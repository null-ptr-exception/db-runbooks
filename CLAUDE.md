# db-runbooks

2-cluster sandbox for database operations automation with aqsh, kube-auth-proxy, kube-federated-auth, and mariadb-operator on Kind clusters.

> ⛔ **Two Kind clusters are live at the same time. Always pass `--context` to
> every `kubectl` command.** Nothing enforces this — no hook, no lint, no test.
> The wrong context is real damage, not a style nit.

## Quality Gates — who enforces what

Assume nothing is checking you unless this table says so. The expensive mistake
is believing something is enforced when it isn't: you skip it, push, and find
out 30–75 minutes later — or never.

| Owner | Meaning | In this repo |
|-------|---------|--------------|
| 🔧 **hook-enforced** | Blocked mechanically at commit/push time | **Nothing.** No git hooks, no pre-commit, no PreToolUse guards |
| ⚙️ **CI-only** | Runs only in GitHub Actions | ShellCheck · Hadolint · bats (unit + Kind e2e) · image build |
| 🧠 **convention** | Written down, no automation | Configuration Layers (below) · `--context` |
| 👁️ **unenforced** | Config exists but nothing runs it | `yamllint` · `actionlint` · task↔script · task↔docs · reason-code stability |

**Run these three before every push** — seconds each, and they catch most CI
failures:

```bash
find . -type f -name '*.sh' -print0 | xargs -0 shellcheck --severity=warning -x
bats --recursive tests/unit
docker run --rm -i hadolint/hadolint hadolint --ignore DL3008 --ignore DL4006 - < Dockerfile
```

⚠️ Everything else needs real Kind clusters: **30 min** (mariadb, infra, aqsh),
**60 min** (mariadb-legacy), **75 min** (mongodb). One wrong push costs a full
cycle. And the `mongodb` job is sharded by filename in `ci.yaml` with no
auto-discovery — a new `tests/mongodb/*.bats` that isn't added to a shard list
**silently never runs**.

Full inventory, exact commands, and what's uncovered:
[`docs/internal/quality-gates.md`](docs/internal/quality-gates.md).

## kubectl Contexts

| Context | Cluster | Purpose |
|---------|---------|---------|
| kind-cluster-a | cluster-a | Server: aqsh, federated auth, Redis, DB instances, Istio gateway |
| kind-cluster-b | cluster-b | Client: test-client, MinIO, Istio gateway |

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

A task input is a **public API promise**: once it ships you can add fields but
never remove one. So before writing the script, decide which layer a value
belongs to.

| Layer | Where | For values that… |
|-------|-------|------------------|
| **Task input** | `input:` in `tasks-*.yaml` | a caller legitimately picks differently on different calls within the *same* deployment — target namespace/pod, force flags, account usernames, escalation levels |
| **Internal config** | `aqsh-tasks/config/*.env` → ConfigMap → `/etc/aqsh/config/*.env` | are fixed for a given deployment but vary *across* deployments — secret/StatefulSet naming conventions, credential key names, data/mount paths per image type. They describe how an environment is built |
| **Auto-detect** | Live cluster/database state | the cluster can answer better than we can guess |
| **Hardcoded fallback** | A literal in `lib/*.sh` | keep zero-config use working |

**Rule of thumb**: if two environments could reasonably want different values
for X, but one environment wants the *same* value of X on every call, X is
internal config, not a task input.

**Identities are never task inputs, at any tier.** A credential, a Vault
AppRole, a signing key, an endpoint that decides *who we act as* — exposing one
lets a caller redirect the action to an identity the deployment was never
provisioned with. That is a confused-deputy hole, not flexibility.

**`*_DEFAULT` naming is load-bearing.** The internal-config variable must carry
the `_DEFAULT` suffix and must not reuse the task input's env var name —
otherwise sourcing the config file silently clobbers an explicit caller
override, with no error:

```bash
[[ -f /etc/aqsh/config/mongodb.env ]] && source /etc/aqsh/config/mongodb.env
_STS="${MONGO_STS_NAME:-${MONGO_STS_NAME_DEFAULT:-mongodb}}"
```

Corollary: the YAML `default:` for such an input must be `""`, never a literal.

**Detection fails soft, and must say so.** Auto-detect returns nothing when it
has no confident signal, and resolution falls through — it never guesses. But a
permanently-broken detection then looks identical to a working one, so report
the winning tier in the result payload.

**RBAC is coupled to the naming convention.** If a value ends up in
`resourceNames`, template the RBAC chart from the same chart values that produce
the internal config — otherwise a non-default convention is silently denied at
runtime, in a path local tests never reach. See
`tests/chart/templates/mongodb-rbac.yaml`.

**Destructive families expose less than they resolve.** `recovery/*`,
`reconfig/*`, `fcv/*`, `pbm/*`, `pods/*`, `sts/orphan-delete` and friends declare
*no* resolution fields as task inputs — just `namespace` plus the genuinely
per-call operational decisions. MariaDB object storage has its own 4-tier order
and likewise exposes none of it
([object-storage-resolution](docs/mariadb/object-storage-resolution.md)).

→ **Adding or changing a task?** Use the `task-authoring` skill
(`.claude/skills/`) — decision procedure, worked examples, and a checklist.
→ **Need the mechanics or the per-family registry?**
[`docs/internal/resolution-tiers.md`](docs/internal/resolution-tiers.md).

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

## Maintaining this file

This file is read in full at the start of every session, whatever the task —
so its budget is spent on things that apply to *every* task. Keep it to three
kinds of content: the **map** (contexts, namespaces, architecture, ports), the
**rules** whose violation is expensive and unautomated, and **routing** to the
skill or doc that has the detail.

- **The real trigger is content type, not length**: a section that starts
  *enumerating instances* ("these tasks do X, those do Y") has stopped being a
  rule and become a document. Move it to `docs/` and leave a pointer.
- A list of "which tasks are in category X" is a **registry**. It will drift.
  Move it somewhere a test can check it.
- Size is the secondary signal. *Configuration Layers* is the longest section
  here on purpose — it applies to every code change — and it is the intended
  ceiling. A section approaching it that is **not** that load-bearing is asking
  to be split.
- New gotchas go to a skill or `docs/` by default. Promote to this file only
  when they bite across *different kinds* of task.
- Leave pointers, not summaries. A summary drifts from its source, and a reader
  who finds it may not go read the real thing.
