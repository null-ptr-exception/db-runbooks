# Kind Cluster Consolidation Design

## Goal

Consolidate from 3-4 Kind clusters to 2 generic clusters, pin infrastructure versions to match corporate environments, replace NodePort+nginx-proxy with Istio Gateway for ingress, and reorganize tests into independent per-target suites with idempotent setup and opt-in teardown.

## Cluster Topology

Two Kind clusters with fixed roles:

| Cluster | Purpose | Host Ports |
|---------|---------|------------|
| cluster-a | Server-side: databases, operators, aqsh, kube-federated-auth, Redis | 38001 (HTTP), 38443 (HTTPS) |
| cluster-b | Client-side: test-client workloads | 38002 (HTTP), 38444 (HTTPS) |

Both clusters run:
- Kubernetes 1.31 (`kindest/node:v1.31.6`)
- Cilium 1.16 as CNI (`disableDefaultCNI: true` in Kind config)
- Istio 1.24 (base + istiod + ingress gateway)

Kind configs declare `extraPortMappings` mapping NodePort 30080/30443 to the host ports above. Istio ingress gateway is configured as `NodePort` on 30080 (HTTP) and 30443 (HTTPS).

Wildcard domains `*.kind-a.localhost` and `*.kind-b.localhost` resolve to 127.0.0.1 (RFC 6761) and route through the respective Istio gateways.

## Infrastructure Layers

### Layer 1 — Clusters (Kind + shell script)

Plain Kind config files in `infra/` and a shell script that runs `kind create cluster` for each. Idempotent — skips if cluster already exists.

Files:
- `infra/kind-cluster-a.yaml`
- `infra/kind-cluster-b.yaml`
- `infra/create-clusters.sh`

### Layer 2 — Shared Platform (helmfile)

Cilium and Istio deployed on both clusters via a single helmfile. Includes the Istio Gateway resource with wildcard host matching.

File: `infra/helmfile-platform.yaml`

Contents:
- Cilium 1.16.7 on both clusters (ipam: kubernetes, hubble: disabled)
- Istio base 1.24.3 on both clusters
- istiod 1.24.3 on both clusters
- Istio ingress gateway 1.24.3 on both clusters (NodePort, ports 30080/30443)
- Gateway resource with `*.kind-a.localhost` / `*.kind-b.localhost`

Requires `helmDefaults.skipSchemaValidation: true` due to Istio chart schema incompatibility with Helm v4.

### Layer 3 — Suite-Specific Infra (helmfile per suite)

Each test suite has its own helmfile declaring the charts and VirtualService resources it needs.

Files: `tests/<suite>/helmfile.yaml`

### Layer 4 — Tests (BATS)

Each suite is a directory under `tests/` with `.bats` files, run by BATS with bats-support and bats-assert.

## Test Suites

### aqsh — Authentication & Framework

Tests aqsh auth mechanisms, kube-federated-auth, kube-auth-proxy.

Components on cluster-a (`db-ops` namespace):
- kube-federated-auth
- Redis
- aqsh (with kube-auth-proxy sidecar)

Components on cluster-b:
- test-client (curl pod) in `app-a` namespace

Connection flow: test-client → `aqsh.kind-a.localhost:38001` → Istio Gateway → VirtualService → aqsh service

No database operators needed. Lightest suite.

### mariadb — MariaDB aqsh Tasks

Tests mariadb-specific aqsh tasks (restart, backup, etc.).

Components: everything from aqsh suite + mariadb-operator + MariaDB instances on cluster-a.

Sub-suites for different topologies (single, dual/replication) as separate `.bats` files with their own `setup_file`/`teardown_file`.

### mongodb — MongoDB aqsh Tasks

Tests mongodb-specific aqsh tasks (restart, backup, etc.).

Components: everything from aqsh suite + MongoDB instances on cluster-a.

Same sub-suite pattern as mariadb.

## Setup/Teardown Lifecycle

Each suite's BATS `setup_suite` runs the full idempotent stack:

```bash
setup_suite() {
  # Layer 1: ensure clusters exist
  kind create cluster --config infra/kind-cluster-a.yaml --name cluster-a 2>/dev/null || true
  kind create cluster --config infra/kind-cluster-b.yaml --name cluster-b 2>/dev/null || true

  # Layer 2: shared platform
  helmfile sync -f infra/helmfile-platform.yaml

  # Layer 3: suite-specific infra
  helmfile sync -f tests/<suite>/helmfile.yaml

  # Wait for readiness
  kubectl wait --for=condition=ready ...
}
```

Teardown is opt-in:

```bash
teardown_suite() {
  if [[ "${TEARDOWN:-}" == "true" ]]; then
    helmfile destroy -f tests/<suite>/helmfile.yaml
    # Optionally: kind delete clusters
  fi
}
```

Key behaviors:
- **Local dev**: infra stays up between runs, no teardown by default
- **CI**: sets `TEARDOWN=true` to clean up after each suite
- **Idempotent**: `kind create cluster` no-ops if exists, `helmfile sync` no-ops if unchanged
- **Shared layers 1-2**: created once by the first suite, reused by subsequent suites in sequential runs

## CI Integration

GitHub Actions workflow runs suites as parallel matrix jobs:

```yaml
strategy:
  matrix:
    suite: [aqsh, mariadb, mongodb]
  fail-fast: false
  max-parallel: 3
```

Each matrix job:
1. Installs tools (kind, kubectl, helm, helmfile, bats + libs)
2. Tunes kernel (`fs.inotify.max_user_watches=524288`, `max_user_instances=512`)
3. Runs `bats tests/${{ matrix.suite }}/` with `TEARDOWN=true`

Each job gets its own runner — fully isolated clusters, no shared state.

Compared to the current CI:
- No more `DB_MODE` / `USE_MARIADB_OPERATOR` matrix combinations
- MongoDB no longer runs redundantly across all combinations
- Each suite is self-contained and independently extensible

## Validated Assumptions

Hands-on testing confirmed (2026-05-29):
- Kind clusters with `disableDefaultCNI: true` + Cilium 1.16 via helmfile: works
- Istio 1.24 (base + istiod + gateway) via helmfile: works with `skipSchemaValidation: true`
- Istio Gateway with NodePort 30080/30443 + Kind extraPortMappings: works
- Wildcard domain `*.kind-a.localhost` routing through Istio Gateway: works (200 for matching hosts, 404 for non-matching)
- helmfile multi-cluster deployment with `kubeContext` per release and `needs` ordering: works
