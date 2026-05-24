# BATS-Managed Setup/Teardown

Add layered setup/teardown to the BATS test framework so each test file deploys and cleans up only the resources it needs.

## Goals

- Tests are self-contained: `bats tests/mariadb/` works without MongoDB deployed
- No external setup/teardown steps: `scripts/test.sh` is the single entry point
- Per-file namespace isolation with cleanup via `kubectl delete ns`
- CI simplifies to: install deps → run test.sh

## Three Layers

### Layer 1: Global (`setup_suite` / `teardown_suite`)

Runs once per `bats --recursive tests/` invocation.

**Setup:**
1. Create Kind clusters (`scripts/setup-clusters.sh`)
2. Deploy shared infrastructure (`scripts/deploy-infra.sh`):
   - `db-ops` namespace + RBAC on all clusters
   - `app-a`, `app-b` namespaces + RBAC on cluster-apps
   - Credentials bootstrap (`scripts/setup-credentials.sh`)
   - kube-federated-auth on cluster-auth
   - mariadb-operator (helm) on cluster-dbs
   - Build + load aqsh Docker images
   - Deploy aqsh-mariadb, aqsh-mongodb, Redis on cluster-dbs

**Teardown:**
1. Delete Kind clusters (`scripts/teardown.sh`)

**File:** `tests/setup_suite.bash`

```bash
setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  "${ROOT_DIR}/scripts/setup-clusters.sh"
  "${ROOT_DIR}/scripts/deploy-infra.sh"
}

teardown_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  "${ROOT_DIR}/scripts/teardown.sh"
}
```

### Layer 2: Per-file (`setup_file` / `teardown_file`)

Each `.bats` file deploys the specific resources it needs.

| File | setup_file deploys | teardown_file deletes |
|------|-------------------|----------------------|
| `common/auth.bats` | (nothing extra) | (nothing) |
| `common/hello_task.bats` | TOKEN | (nothing) |
| `common/in_pod.bats` | test-client in app-a | ns app-a (recreate) |
| `mariadb/restart.bats` | ns mariadb-1 + MariaDB CR | ns mariadb-1 |
| `mongodb/sanity_check.bats` | ns mongo-1 + credentials + MongoDB | ns mongo-1 |
| `mongodb/restart.bats` | ns mongo-1 + credentials + MongoDB | ns mongo-1 |

### Layer 3: Per-test (`setup` / `teardown`)

Not needed currently. Available for future tests that mutate shared state within a file.

## File Changes

### New: `scripts/deploy-infra.sh`

Extracted from `scripts/deploy.sh`. Contains steps 1-4 and 7-8 from the current deploy.sh:

1. Deploy `db-ops` namespace + RBAC (cluster-auth, cluster-dbs)
2. Deploy app namespaces + RBAC (cluster-apps)
3. Bootstrap credentials
4. Deploy kube-federated-auth (cluster-auth)
5. Install mariadb-operator via helm (cluster-dbs)
6. Build + load aqsh images (skaffold + kind load)
7. Deploy Redis, aqsh-mariadb, aqsh-mongodb (cluster-dbs)

Does NOT deploy: MariaDB instances, MongoDB instances, test-client.

### New: `tests/setup_suite.bash`

BATS discovers this automatically when running from the `tests/` directory. Calls `setup-clusters.sh` + `deploy-infra.sh` in setup, `teardown.sh` in teardown.

### Modified: `k8s/cluster-dbs/namespace.yaml`

Remove per-DB namespaces (mariadb-1/2/3, mongo-1/2/3). Keep only `db-ops`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: db-ops
```

Per-DB namespaces are created dynamically in `setup_file` via `kubectl create ns`.

### New helper functions in `tests/test_helper/common_setup.bash`

```bash
deploy_mariadb <namespace>
```
- `kubectl create ns <namespace>`
- `kubectl apply` the MariaDB CR for that namespace
- `kubectl wait --for=condition=Ready mariadb/mariadb --timeout=180s`

```bash
deploy_mongodb <namespace>
```
- `kubectl create ns <namespace>`
- Create `mongodb-credentials` secret
- `kubectl apply` the MongoDB manifest for that namespace
- `kubectl wait --for=condition=Ready pod -l app=mongodb --timeout=180s`

```bash
deploy_test_client <namespace>
```
- Apply test-client deployment + wait for ready

These functions need to know which manifest to apply. The mapping:
- `mariadb-1` → `k8s/cluster-dbs/mariadb/mariadb-1.yaml`
- `mongo-1` → `k8s/cluster-dbs/mongodb/mongo-1.yaml`

The functions use `ROOT_DIR` (set by `common_setup`) to locate manifests.

### Modified: `scripts/test.sh`

Simplified — no separate setup/teardown calls:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
"${SCRIPT_DIR}/install-bats-libs.sh"
bats --recursive "${ROOT_DIR}/tests/"
```

(Same as current — already correct.)

### Modified: `scripts/deploy.sh`

Keep it as a convenience script for manual full deployment (outside of tests). No code changes needed — it still works standalone. But it is no longer called by the test pipeline.

### Modified: `.github/workflows/ci.yaml`

The integration job simplifies. Remove separate setup/deploy/teardown steps:

```yaml
- name: Install BATS helper libraries
  run: ./scripts/install-bats-libs.sh

- name: Run integration tests
  run: ./scripts/test.sh

- name: Tear down clusters
  if: always()
  run: ./scripts/teardown.sh
```

Keep the `Tear down clusters` step with `if: always()` as a safety net — if `setup_suite` succeeds but the bats run is killed (timeout, OOM), teardown_suite won't run. The teardown script is idempotent so running it twice is safe.

### Updated .bats files

All 6 `.bats` files updated to add `teardown_file` and deploy helpers in `setup_file` where needed. Example for `mariadb/restart.bats`:

```bash
setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  deploy_mariadb "mariadb-1"
}

teardown_file() {
  kubectl --context kind-cluster-dbs delete ns mariadb-1 --ignore-not-found
}
```

### What about common/in_pod.bats?

The test-client pod lives in namespace `app-a` which is created by `deploy-infra.sh` (global). The `in_pod.bats` setup_file just waits for the pod to be ready — it doesn't need to deploy or teardown the namespace since it's shared infrastructure.

Actually, looking more carefully: `deploy-infra.sh` creates the `app-a`/`app-b` namespaces and deploys the test-client. So `in_pod.bats` only needs to wait for readiness in `setup_file`, with no `teardown_file`.

### MongoDB credential handling

The `deploy_mongodb` helper creates a credentials secret with a random password, matching the current logic in `deploy.sh`:

```bash
kubectl --context kind-cluster-dbs -n "$namespace" create secret generic mongodb-credentials \
  --from-literal="MONGO_ROOT_USER=${namespace}-admin" \
  --from-literal="MONGO_ROOT_PASS=$(openssl rand -base64 16 | tr -d '=+/')"
```

## Summary of scripts after changes

| Script | Purpose | Called by |
|--------|---------|-----------|
| `scripts/setup-clusters.sh` | Create Kind clusters, write .env | `setup_suite` |
| `scripts/deploy-infra.sh` | Deploy shared infrastructure | `setup_suite` |
| `scripts/deploy.sh` | Full deployment (manual use) | Users directly |
| `scripts/teardown.sh` | Delete Kind clusters | `teardown_suite`, CI safety net |
| `scripts/test.sh` | Run bats | CI, users |
| `scripts/install-bats-libs.sh` | Clone bats-support/bats-assert | `test.sh` |
