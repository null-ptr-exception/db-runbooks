# BATS-Managed Setup/Teardown — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add layered BATS setup/teardown so each test file deploys and cleans up only the resources it needs, with global bootstrap for shared infrastructure.

**Architecture:** `tests/setup_suite.bash` handles global lifecycle (Kind clusters + shared infra). Per-file `setup_file`/`teardown_file` deploy specific DB instances and delete their namespaces. Deploy helpers (`deploy_mariadb`, `deploy_mongodb`) in `common_setup.bash` encapsulate the per-DB deployment logic. RBAC is split: ClusterRoles are global, RoleBindings are per-namespace.

**Tech Stack:** BATS (setup_suite/teardown_suite), kubectl, helm, kind, skaffold

**Spec:** `docs/superpowers/specs/2026-05-24-bats-setup-teardown-design.md`

---

### Task 1: Trim namespace.yaml to db-ops only

**Files:**
- Modify: `k8s/cluster-dbs/namespace.yaml`

Per-DB namespaces (mariadb-1/2/3, mongo-1/2/3) are now created dynamically by test setup_file. Only `db-ops` stays in the static manifest.

- [ ] **Step 1: Replace `k8s/cluster-dbs/namespace.yaml`**

Replace the entire file contents with:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: db-ops
```

- [ ] **Step 2: Commit**

```bash
git add k8s/cluster-dbs/namespace.yaml
git commit -m "refactor: remove per-DB namespaces from static manifest"
```

---

### Task 2: Split RBAC — ClusterRoles stay global, RoleBindings become dynamic

**Files:**
- Modify: `k8s/cluster-dbs/mariadb/rbac.yaml`
- Modify: `k8s/cluster-dbs/mongodb/rbac.yaml`

The existing RBAC files contain both ClusterRoles (cluster-scoped) and RoleBindings (namespace-scoped with hardcoded namespaces mariadb-1/2/3, mongo-1/2/3). Since namespaces are now created dynamically, the RoleBindings move into deploy helpers. Only ClusterRoles remain in the static files.

- [ ] **Step 1: Update `k8s/cluster-dbs/mariadb/rbac.yaml`**

Replace the entire file contents with (ClusterRole only, all RoleBindings removed):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: aqsh-mariadb-manager
rules:
  - apiGroups: ["apps"]
    resources: ["statefulsets"]
    resourceNames: ["mariadb"]
    verbs: ["get", "patch"]
  - apiGroups: ["apps"]
    resources: ["statefulsets"]
    verbs: ["list", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
```

- [ ] **Step 2: Update `k8s/cluster-dbs/mongodb/rbac.yaml`**

Replace the entire file contents with (ClusterRoles + ClusterRoleBinding only, all namespace-scoped RoleBindings removed):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: aqsh-mongo-manager
rules:
  - apiGroups: ["apps"]
    resources: ["statefulsets"]
    resourceNames: ["mongodb"]
    verbs: ["get", "patch"]
  - apiGroups: ["apps"]
    resources: ["statefulsets"]
    verbs: ["list", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["mongodb-credentials"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: aqsh-mongo-node-reader
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aqsh-mongo-node-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aqsh-mongo-node-reader
subjects:
  - kind: ServiceAccount
    name: kube-auth-proxy
    namespace: db-ops
```

- [ ] **Step 3: Commit**

```bash
git add k8s/cluster-dbs/mariadb/rbac.yaml k8s/cluster-dbs/mongodb/rbac.yaml
git commit -m "refactor: split RBAC — keep ClusterRoles, remove namespace-scoped RoleBindings"
```

---

### Task 3: Create `scripts/deploy-infra.sh`

**Files:**
- Create: `scripts/deploy-infra.sh`

This script is extracted from `scripts/deploy.sh`. It deploys only shared infrastructure — everything that is NOT per-DB-instance. It also deploys the test-client in cluster-apps since that's shared.

- [ ] **Step 1: Create `scripts/deploy-infra.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

# shellcheck source=/dev/null
source "$ENV_FILE"
export CLUSTER_AUTH_IP CLUSTER_DBS_IP CLUSTER_APPS_IP

echo "=== Step 1: Deploy namespaces and RBAC ==="

kubectl --context kind-cluster-auth apply -f "${ROOT_DIR}/k8s/cluster-auth/namespace.yaml"

kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/namespace.yaml"
kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/federated-auth-rbac.yaml"
kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/aqsh-rbac.yaml"
kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/rbac.yaml"
kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/rbac.yaml"

kubectl --context kind-cluster-apps apply -f "${ROOT_DIR}/k8s/cluster-apps/namespace.yaml"
kubectl --context kind-cluster-apps apply -f "${ROOT_DIR}/k8s/cluster-apps/federated-auth-rbac.yaml"

echo "=== Step 2: Bootstrap credentials ==="

"${SCRIPT_DIR}/setup-credentials.sh"

# Re-source to pick up ISSUER_DBS and ISSUER_APPS added by setup-credentials.sh
# shellcheck source=/dev/null
source "$ENV_FILE"
export ISSUER_DBS ISSUER_APPS

echo "=== Step 3: Deploy cluster-auth (kube-federated-auth) ==="

kubectl --context kind-cluster-auth apply -f "${ROOT_DIR}/k8s/cluster-auth/rbac.yaml"

envsubst < "${ROOT_DIR}/k8s/cluster-auth/configmap.yaml.tpl" | kubectl --context kind-cluster-auth apply -f -

kubectl --context kind-cluster-auth apply -f "${ROOT_DIR}/k8s/cluster-auth/deployment.yaml"
kubectl --context kind-cluster-auth apply -f "${ROOT_DIR}/k8s/cluster-auth/service.yaml"

echo "Waiting for kube-federated-auth to be ready..."
kubectl --context kind-cluster-auth -n db-ops rollout status deployment/kube-federated-auth --timeout=120s

echo "=== Step 4: Deploy mariadb-operator ==="

helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator 2>/dev/null || true
helm repo update mariadb-operator

helm upgrade --install mariadb-operator-crds mariadb-operator/mariadb-operator-crds \
  --kube-context kind-cluster-dbs \
  --wait

helm upgrade --install mariadb-operator mariadb-operator/mariadb-operator \
  --kube-context kind-cluster-dbs \
  --namespace db-ops \
  --wait

echo "=== Step 5: Build aqsh image ==="

mkdir -p "${ROOT_DIR}/.skaffold-rendered"
skaffold build --filename="${ROOT_DIR}/skaffold.yaml" --tag=latest \
  --file-output="${ROOT_DIR}/.skaffold-rendered/build.json"

echo "=== Step 6: Deploy aqsh + Redis with Skaffold ==="

mkdir -p "${ROOT_DIR}/.skaffold-rendered/cluster-dbs"
cp "${ROOT_DIR}/k8s/cluster-dbs/redis.yaml" "${ROOT_DIR}/.skaffold-rendered/cluster-dbs/redis.yaml"
envsubst '${CLUSTER_AUTH_IP}' < "${ROOT_DIR}/k8s/cluster-dbs/aqsh-mariadb-deployment.yaml.tpl" \
  > "${ROOT_DIR}/.skaffold-rendered/cluster-dbs/aqsh-mariadb-deployment.yaml"
cp "${ROOT_DIR}/k8s/cluster-dbs/aqsh-mariadb-service.yaml" \
  "${ROOT_DIR}/.skaffold-rendered/cluster-dbs/aqsh-mariadb-service.yaml"
envsubst '${CLUSTER_AUTH_IP}' < "${ROOT_DIR}/k8s/cluster-dbs/aqsh-mongodb-deployment.yaml.tpl" \
  > "${ROOT_DIR}/.skaffold-rendered/cluster-dbs/aqsh-mongodb-deployment.yaml"
cp "${ROOT_DIR}/k8s/cluster-dbs/aqsh-mongodb-service.yaml" \
  "${ROOT_DIR}/.skaffold-rendered/cluster-dbs/aqsh-mongodb-service.yaml"

skaffold deploy \
  --filename="${ROOT_DIR}/skaffold.yaml" \
  --kube-context kind-cluster-dbs \
  --build-artifacts="${ROOT_DIR}/.skaffold-rendered/build.json" \
  --load-images=true \
  --status-check=false

kubectl --context kind-cluster-dbs -n db-ops rollout restart deployment/aqsh-mariadb
kubectl --context kind-cluster-dbs -n db-ops rollout restart deployment/aqsh-mongodb

echo "Waiting for Redis to be ready..."
kubectl --context kind-cluster-dbs -n db-ops rollout status deployment/redis --timeout=60s

echo "Waiting for aqsh-mariadb to be ready..."
kubectl --context kind-cluster-dbs -n db-ops rollout status deployment/aqsh-mariadb --timeout=120s

echo "Waiting for aqsh-mongodb to be ready..."
kubectl --context kind-cluster-dbs -n db-ops rollout status deployment/aqsh-mongodb --timeout=120s

echo "=== Step 7: Deploy test-client ==="

kubectl --context kind-cluster-apps apply -f "${ROOT_DIR}/k8s/cluster-apps/test-client.yaml"

echo "Waiting for test-client to be ready..."
kubectl --context kind-cluster-apps -n app-a rollout status deployment/test-client --timeout=60s
kubectl --context kind-cluster-apps -n app-b rollout status deployment/test-client --timeout=60s

echo "=== Infrastructure deployment complete ==="
```

Make it executable:

```bash
chmod +x scripts/deploy-infra.sh
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n scripts/deploy-infra.sh
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add scripts/deploy-infra.sh
git commit -m "feat: add deploy-infra.sh for shared infrastructure deployment"
```

---

### Task 4: Create `tests/setup_suite.bash`

**Files:**
- Create: `tests/setup_suite.bash`

BATS automatically discovers `setup_suite.bash` in the test directory. It runs `setup_suite()` once before any test files and `teardown_suite()` once after all test files.

- [ ] **Step 1: Create `tests/setup_suite.bash`**

```bash
#!/usr/bin/env bash

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

- [ ] **Step 2: Verify syntax**

```bash
bash -n tests/setup_suite.bash
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add tests/setup_suite.bash
git commit -m "feat: add setup_suite.bash for BATS-managed cluster lifecycle"
```

---

### Task 5: Add deploy helpers to `common_setup.bash`

**Files:**
- Modify: `tests/test_helper/common_setup.bash`

Add three functions: `deploy_mariadb`, `deploy_mongodb`, and `deploy_test_client`. Each creates the namespace, applies RBAC RoleBindings, deploys the resources, and waits for readiness.

- [ ] **Step 1: Append deploy helpers to `tests/test_helper/common_setup.bash`**

Add the following after the existing `wait_for_task` function:

```bash

# ---------------------------------------------------------------------------
# deploy_mariadb <namespace>
#
# Creates namespace, RBAC RoleBinding, and MariaDB CR.
# Waits for the MariaDB instance to be ready.
# ---------------------------------------------------------------------------
deploy_mariadb() {
  local namespace="$1"

  kubectl --context kind-cluster-dbs create ns "$namespace" --dry-run=client -o yaml \
    | kubectl --context kind-cluster-dbs apply -f -

  kubectl --context kind-cluster-dbs -n "$namespace" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: aqsh-mariadb-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aqsh-mariadb-manager
subjects:
  - kind: ServiceAccount
    name: kube-auth-proxy
    namespace: db-ops
EOF

  kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/${namespace}.yaml"

  echo "Waiting for MariaDB in ${namespace} to be ready..."
  kubectl --context kind-cluster-dbs -n "$namespace" wait \
    --for=condition=Ready mariadb/mariadb --timeout=180s
}

# ---------------------------------------------------------------------------
# deploy_mongodb <namespace>
#
# Creates namespace, RBAC RoleBinding, credentials secret, and MongoDB StatefulSet.
# Waits for the MongoDB pod to be ready.
# ---------------------------------------------------------------------------
deploy_mongodb() {
  local namespace="$1"

  kubectl --context kind-cluster-dbs create ns "$namespace" --dry-run=client -o yaml \
    | kubectl --context kind-cluster-dbs apply -f -

  kubectl --context kind-cluster-dbs -n "$namespace" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: aqsh-mongo-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aqsh-mongo-manager
subjects:
  - kind: ServiceAccount
    name: kube-auth-proxy
    namespace: db-ops
EOF

  if ! kubectl --context kind-cluster-dbs -n "$namespace" get secret mongodb-credentials &>/dev/null; then
    kubectl --context kind-cluster-dbs -n "$namespace" create secret generic mongodb-credentials \
      --from-literal="MONGO_ROOT_USER=${namespace}-admin" \
      --from-literal="MONGO_ROOT_PASS=$(openssl rand -base64 16 | tr -d '=+/')"
  fi

  kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/${namespace}.yaml"

  echo "Waiting for MongoDB in ${namespace} to be ready..."
  kubectl --context kind-cluster-dbs -n "$namespace" wait pod \
    -l app=mongodb --for=condition=Ready --timeout=180s
}
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n tests/test_helper/common_setup.bash
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add tests/test_helper/common_setup.bash
git commit -m "feat: add deploy_mariadb and deploy_mongodb helpers to common_setup"
```

---

### Task 6: Update `tests/mariadb/restart.bats`

**Files:**
- Modify: `tests/mariadb/restart.bats`

Add `deploy_mariadb` call in `setup_file` and namespace cleanup in `teardown_file`.

- [ ] **Step 1: Update `tests/mariadb/restart.bats`**

Replace the `setup_file` function and add `teardown_file`. The full file should be:

```bash
setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  deploy_mariadb "mariadb-1"
}

teardown_file() {
  kubectl --context kind-cluster-dbs delete ns mariadb-1 --ignore-not-found
}

@test "restart task completes successfully" {
  http_post "${MARIADB_AQSH_URL}/tasks/restart" '{"namespace": "mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"
}

@test "restart advances StatefulSet generation and all replicas ready" {
  local before_generation
  before_generation=$(kubectl --context kind-cluster-dbs -n mariadb-1 \
    get statefulset mariadb -o jsonpath='{.status.observedGeneration}')

  http_post "${MARIADB_AQSH_URL}/tasks/restart" '{"namespace": "mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  # Wait for pods to be ready after restart
  kubectl --context kind-cluster-dbs -n mariadb-1 wait pod \
    -l app.kubernetes.io/name=mariadb \
    --for=condition=Ready --timeout=120s >/dev/null 2>&1

  local after_generation ready replicas
  after_generation=$(kubectl --context kind-cluster-dbs -n mariadb-1 \
    get statefulset mariadb -o jsonpath='{.status.observedGeneration}')
  ready=$(kubectl --context kind-cluster-dbs -n mariadb-1 \
    get statefulset mariadb -o jsonpath='{.status.readyReplicas}')
  replicas=$(kubectl --context kind-cluster-dbs -n mariadb-1 \
    get statefulset mariadb -o jsonpath='{.status.replicas}')

  echo "generation: ${before_generation} → ${after_generation}, ready: ${ready}/${replicas}"
  assert [ "$after_generation" -gt "$before_generation" ]
  assert_equal "$ready" "$replicas"
  assert [ "$ready" != "0" ]
}
```

- [ ] **Step 2: Commit**

```bash
git add tests/mariadb/restart.bats
git commit -m "test: add setup/teardown for mariadb-1 in restart.bats"
```

---

### Task 7: Update `tests/mongodb/sanity_check.bats`

**Files:**
- Modify: `tests/mongodb/sanity_check.bats`

Add `deploy_mongodb` call in `setup_file` and namespace cleanup in `teardown_file`.

- [ ] **Step 1: Update `tests/mongodb/sanity_check.bats`**

Replace the `setup_file` function and add `teardown_file`. The full file should be:

```bash
setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  deploy_mongodb "mongo-1"
}

teardown_file() {
  kubectl --context kind-cluster-dbs delete ns mongo-1 --ignore-not-found
}

@test "sanity-check completes without critical issues" {
  http_post "${MONGODB_AQSH_URL}/tasks/sanity-check" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result_status pass_count warn_count fail_count
  result_status=$(echo "$TASK_RESPONSE" | jq -r '.result.status // "unknown"')
  pass_count=$(echo "$TASK_RESPONSE" | jq -r '.result.pass // 0')
  warn_count=$(echo "$TASK_RESPONSE" | jq -r '.result.warn // 0')
  fail_count=$(echo "$TASK_RESPONSE" | jq -r '.result.fail // 0')

  echo "sanity result: status=${result_status} pass=${pass_count} warn=${warn_count} fail=${fail_count}"
  assert [ "$result_status" != "critical" ]
}
```

- [ ] **Step 2: Commit**

```bash
git add tests/mongodb/sanity_check.bats
git commit -m "test: add setup/teardown for mongo-1 in sanity_check.bats"
```

---

### Task 8: Update `tests/mongodb/restart.bats`

**Files:**
- Modify: `tests/mongodb/restart.bats`

Add `deploy_mongodb` call in `setup_file` and namespace cleanup in `teardown_file`.

- [ ] **Step 1: Update `tests/mongodb/restart.bats`**

Replace the `setup_file` function and add `teardown_file`. The full file should be:

```bash
setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  deploy_mongodb "mongo-1"
}

teardown_file() {
  kubectl --context kind-cluster-dbs delete ns mongo-1 --ignore-not-found
}

@test "restart task completes successfully" {
  http_post "${MONGODB_AQSH_URL}/tasks/restart" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"
}

@test "restart advances StatefulSet generation and all replicas ready" {
  local before_generation
  before_generation=$(kubectl --context kind-cluster-dbs -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.status.observedGeneration}')

  http_post "${MONGODB_AQSH_URL}/tasks/restart" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  # Wait for pods to be ready after restart
  kubectl --context kind-cluster-dbs -n mongo-1 wait pod \
    -l app=mongodb \
    --for=condition=Ready --timeout=120s >/dev/null 2>&1

  local after_generation ready replicas
  after_generation=$(kubectl --context kind-cluster-dbs -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.status.observedGeneration}')
  ready=$(kubectl --context kind-cluster-dbs -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.status.readyReplicas}')
  replicas=$(kubectl --context kind-cluster-dbs -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.status.replicas}')

  echo "generation: ${before_generation} → ${after_generation}, ready: ${ready}/${replicas}"
  assert [ "$after_generation" -gt "$before_generation" ]
  assert_equal "$ready" "$replicas"
  assert [ "$ready" != "0" ]
}
```

- [ ] **Step 2: Commit**

```bash
git add tests/mongodb/restart.bats
git commit -m "test: add setup/teardown for mongo-1 in restart.bats"
```

---

### Task 9: Update CI workflow

**Files:**
- Modify: `.github/workflows/ci.yaml`

Simplify the integration job. Remove the separate `Create Kind clusters`, `Deploy sandbox`, and `Install BATS helper libraries` steps. BATS `setup_suite` handles cluster creation and infra deployment. Keep `Tear down clusters` as a safety net with `if: always()`.

- [ ] **Step 1: Replace the integration job steps**

Replace everything from `- name: Create Kind clusters` through `- name: Run integration tests` with:

```yaml
      - name: Run integration tests
        run: ./scripts/test.sh
```

Keep the `Tear down clusters` step unchanged (it's already `if: always()`).

The full integration job steps should be:

```yaml
      - name: Check out repository
        uses: actions/checkout@v4

      - name: Install integration dependencies
        run: |
          set -euo pipefail

          sudo apt-get update
          sudo apt-get install -y gettext-base jq bats

          ARCH="$(dpkg --print-architecture)"
          KUBECTL_VERSION="v1.30.0"
          case "$ARCH" in
            amd64|arm64) ;;
            *)
              echo "Unsupported architecture: $ARCH" >&2
              exit 1
              ;;
          esac

          curl -fsSLo kind "https://kind.sigs.k8s.io/dl/latest/kind-linux-${ARCH}"
          chmod +x kind
          sudo mv kind /usr/local/bin/kind

          curl -fsSLo kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
          curl -fsSLo kubectl.sha256 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl.sha256"
          echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -
          chmod +x kubectl
          sudo mv kubectl /usr/local/bin/kubectl
          rm -f kubectl.sha256

          curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

          curl -fsSLo skaffold "https://storage.googleapis.com/skaffold/releases/latest/skaffold-linux-${ARCH}"
          chmod +x skaffold
          sudo mv skaffold /usr/local/bin/skaffold

      - name: Run integration tests
        run: ./scripts/test.sh

      - name: Tear down clusters
        if: always()
        run: ./scripts/teardown.sh
```

- [ ] **Step 2: Verify YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yaml'))"
```

Expected: no output (clean parse).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yaml
git commit -m "build: simplify CI — BATS setup_suite manages cluster lifecycle"
```

---

### Task 10: Update `scripts/deploy.sh` to use `deploy-infra.sh`

**Files:**
- Modify: `scripts/deploy.sh`

`deploy.sh` is kept as a convenience script for manual full deployment. Refactor it to call `deploy-infra.sh` for the shared part, then deploy all DB instances and test-client on top. This avoids code duplication between `deploy.sh` and `deploy-infra.sh`.

- [ ] **Step 1: Rewrite `scripts/deploy.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

# Deploy shared infrastructure
"${SCRIPT_DIR}/deploy-infra.sh"

# shellcheck source=/dev/null
source "$ENV_FILE"

echo "=== Deploy MariaDB instances ==="

for ns in mariadb-1 mariadb-2 mariadb-3; do
  kubectl --context kind-cluster-dbs create ns "$ns" --dry-run=client -o yaml \
    | kubectl --context kind-cluster-dbs apply -f -

  kubectl --context kind-cluster-dbs -n "$ns" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: aqsh-mariadb-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aqsh-mariadb-manager
subjects:
  - kind: ServiceAccount
    name: kube-auth-proxy
    namespace: db-ops
EOF

  kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/${ns}.yaml"
done

echo "Waiting for MariaDB instances to be ready..."
kubectl --context kind-cluster-dbs -n mariadb-1 wait --for=condition=Ready mariadb/mariadb --timeout=180s
kubectl --context kind-cluster-dbs -n mariadb-2 wait --for=condition=Ready mariadb/mariadb --timeout=180s
kubectl --context kind-cluster-dbs -n mariadb-3 wait --for=condition=Ready mariadb/mariadb --timeout=180s

echo "=== Deploy MongoDB instances ==="

for ns in mongo-1 mongo-2 mongo-3; do
  kubectl --context kind-cluster-dbs create ns "$ns" --dry-run=client -o yaml \
    | kubectl --context kind-cluster-dbs apply -f -

  kubectl --context kind-cluster-dbs -n "$ns" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: aqsh-mongo-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aqsh-mongo-manager
subjects:
  - kind: ServiceAccount
    name: kube-auth-proxy
    namespace: db-ops
EOF

  if ! kubectl --context kind-cluster-dbs -n "$ns" get secret mongodb-credentials &>/dev/null; then
    kubectl --context kind-cluster-dbs -n "$ns" create secret generic mongodb-credentials \
      --from-literal="MONGO_ROOT_USER=${ns}-admin" \
      --from-literal="MONGO_ROOT_PASS=$(openssl rand -base64 16 | tr -d '=+/')"
  fi

  kubectl --context kind-cluster-dbs apply -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/${ns}.yaml"
done

echo "Waiting for MongoDB instances to be ready..."
kubectl --context kind-cluster-dbs -n mongo-1 wait --for=condition=Ready pod -l app=mongodb --timeout=180s
kubectl --context kind-cluster-dbs -n mongo-2 wait --for=condition=Ready pod -l app=mongodb --timeout=180s
kubectl --context kind-cluster-dbs -n mongo-3 wait --for=condition=Ready pod -l app=mongodb --timeout=180s

echo "=== Deployment complete ==="
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n scripts/deploy.sh
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add scripts/deploy.sh
git commit -m "refactor: deploy.sh calls deploy-infra.sh, adds per-DB setup with dynamic RBAC"
```
