# Cluster Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate 3-4 Kind clusters to 2 (cluster-a, cluster-b) with Cilium CNI, Istio Gateway ingress, helmfile orchestration, and reorganized per-suite BATS tests starting with the aqsh suite.

**Architecture:** Layer 1 (Kind configs + create script) → Layer 2 (helmfile: Cilium + Istio + Gateway) → Layer 3 (per-suite helmfile with VirtualServices + app charts) → Layer 4 (BATS tests with idempotent setup_suite / opt-in teardown). The aqsh suite is built first as the template for mariadb/mongodb suites to follow.

**Tech Stack:** Kind (K8s 1.31), Cilium 1.16, Istio 1.24, helmfile 1.5+, Helm v4, BATS with bats-support/bats-assert, skaffold (image builds)

---

## File Structure

### New files (infra/)

| File | Responsibility |
|------|---------------|
| `infra/kind-cluster-a.yaml` | Kind config for cluster-a (server-side) |
| `infra/kind-cluster-b.yaml` | Kind config for cluster-b (client-side) |
| `infra/create-clusters.sh` | Idempotent cluster creation script |
| `infra/helmfile-platform.yaml` | Cilium + Istio + Gateway on both clusters |

### New files (aqsh suite)

| File | Responsibility |
|------|---------------|
| `tests/aqsh/setup_suite.bash` | BATS setup_suite/teardown_suite for aqsh tests |
| `tests/aqsh/setup-credentials.sh` | Extract OIDC issuers, CA certs, bootstrap tokens for 2-cluster model |
| `tests/aqsh/auth.bats` | Auth tests (fedauth health, 401 without token) |
| `tests/aqsh/hello_task.bats` | Hello task tests (submit + complete via mariadb/mongodb aqsh) |
| `tests/aqsh/in_pod.bats` | In-pod request tests (projected token) |
| `tests/aqsh/test_helper.bash` | Shared test helpers (URL vars, kexec, http_post, wait_for_task) |

### New files (k8s manifests for new cluster model)

| File | Responsibility |
|------|---------------|
| `k8s/cluster-a/namespace.yaml` | Namespaces for cluster-a |
| `k8s/cluster-a/federated-auth-rbac.yaml` | federated-auth SA + RBAC on cluster-a |
| `k8s/cluster-a/kube-federated-auth-rbac.yaml` | kube-federated-auth SA + RBAC on cluster-a |
| `k8s/cluster-a/kube-federated-auth-deployment.yaml` | kube-federated-auth deployment |
| `k8s/cluster-a/kube-federated-auth-service.yaml` | kube-federated-auth ClusterIP service |
| `k8s/cluster-a/kube-federated-auth-configmap.yaml.tpl` | federated-auth config (2-cluster) |
| `k8s/cluster-a/aqsh-rbac.yaml` | kube-auth-proxy SA |
| `k8s/cluster-a/aqsh-mariadb-deployment.yaml` | aqsh-mariadb deployment (TOKEN_REVIEW_URL via ClusterIP now) |
| `k8s/cluster-a/aqsh-mariadb-service.yaml` | aqsh-mariadb ClusterIP service |
| `k8s/cluster-a/aqsh-mongodb-deployment.yaml` | aqsh-mongodb deployment |
| `k8s/cluster-a/aqsh-mongodb-service.yaml` | aqsh-mongodb ClusterIP service |
| `k8s/cluster-a/redis.yaml` | Redis deployment + service |
| `k8s/cluster-b/namespace.yaml` | Namespaces for cluster-b |
| `k8s/cluster-b/federated-auth-rbac.yaml` | federated-auth SA + RBAC on cluster-b |
| `k8s/cluster-b/test-client.yaml` | test-client deployment in app-a |

### Modified files

| File | Change |
|------|--------|
| `.github/workflows/bats.yaml` | Replace 4-combo matrix with 3-suite matrix, add helmfile install, use new test runner |

### Unchanged (reused)

| File | Note |
|------|------|
| `skaffold.yaml` | Still builds aqsh-mariadb and aqsh-mongodb images |
| `aqsh-tasks/` | No changes to task scripts or Dockerfile |
| `k8s/cluster-dbs/mariadb/` | Reused by future mariadb suite |
| `k8s/cluster-dbs/mongodb/` | Reused by future mongodb suite |

---

### Task 1: Kind Cluster Configs

**Files:**
- Create: `infra/kind-cluster-a.yaml`
- Create: `infra/kind-cluster-b.yaml`

- [ ] **Step 1: Create cluster-a Kind config**

```yaml
# infra/kind-cluster-a.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
nodes:
  - role: control-plane
    image: kindest/node:v1.31.6
    extraPortMappings:
      - containerPort: 30080
        hostPort: 38001
      - containerPort: 30443
        hostPort: 38443
```

- [ ] **Step 2: Create cluster-b Kind config**

```yaml
# infra/kind-cluster-b.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
nodes:
  - role: control-plane
    image: kindest/node:v1.31.6
    extraPortMappings:
      - containerPort: 30080
        hostPort: 38002
      - containerPort: 30443
        hostPort: 38444
```

- [ ] **Step 3: Verify configs are valid**

Run: `kind create cluster --name test-validate --config infra/kind-cluster-a.yaml --dry-run`

If `--dry-run` isn't supported, just validate YAML syntax:
```bash
python3 -c "import yaml; yaml.safe_load(open('infra/kind-cluster-a.yaml'))"
python3 -c "import yaml; yaml.safe_load(open('infra/kind-cluster-b.yaml'))"
```

Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add infra/kind-cluster-a.yaml infra/kind-cluster-b.yaml
git commit -m "feat: add Kind cluster configs for 2-cluster consolidation"
```

---

### Task 2: Cluster Creation Script

**Files:**
- Create: `infra/create-clusters.sh`

- [ ] **Step 1: Create the idempotent cluster creation script**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

create_cluster() {
  local name="$1"
  local config="$2"

  if kind get clusters 2>/dev/null | grep -qx "$name"; then
    echo "Cluster ${name} already exists, skipping"
    return 0
  fi

  echo "Creating cluster ${name}..."
  kind create cluster --name "$name" --config "$config" --wait 60s
}

create_cluster cluster-a "${SCRIPT_DIR}/kind-cluster-a.yaml"
create_cluster cluster-b "${SCRIPT_DIR}/kind-cluster-b.yaml"

echo "=== Clusters ready ==="
echo "cluster-a: $(docker inspect cluster-a-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
echo "cluster-b: $(docker inspect cluster-b-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x infra/create-clusters.sh
```

- [ ] **Step 3: Commit**

```bash
git add infra/create-clusters.sh
git commit -m "feat: add idempotent cluster creation script"
```

---

### Task 3: Helmfile Platform (Cilium + Istio + Gateway)

**Files:**
- Create: `infra/helmfile-platform.yaml`

- [ ] **Step 1: Create the helmfile**

This was validated during hands-on testing. The helmfile deploys Cilium 1.16, Istio 1.24 (base + istiod + gateway), and Gateway resources on both clusters.

```yaml
# infra/helmfile-platform.yaml
repositories:
  - name: cilium
    url: https://helm.cilium.io
  - name: istio
    url: https://istio-release.storage.googleapis.com/charts

helmDefaults:
  skipSchemaValidation: true

releases:
  # --- Cilium CNI ---
  - name: cilium
    namespace: kube-system
    chart: cilium/cilium
    version: 1.16.7
    kubeContext: kind-cluster-a
    values:
      - ipam:
          mode: kubernetes
        image:
          pullPolicy: IfNotPresent
        hubble:
          enabled: false

  - name: cilium
    namespace: kube-system
    chart: cilium/cilium
    version: 1.16.7
    kubeContext: kind-cluster-b
    values:
      - ipam:
          mode: kubernetes
        image:
          pullPolicy: IfNotPresent
        hubble:
          enabled: false

  # --- Istio base (cluster-a) ---
  - name: istio-base
    namespace: istio-system
    chart: istio/base
    version: 1.24.3
    kubeContext: kind-cluster-a
    createNamespace: true

  - name: istiod
    namespace: istio-system
    chart: istio/istiod
    version: 1.24.3
    kubeContext: kind-cluster-a
    needs:
      - istio-system/istio-base
    values:
      - pilot:
          resources:
            requests:
              cpu: 100m
              memory: 128Mi

  - name: istio-ingressgateway
    namespace: istio-ingress
    chart: istio/gateway
    version: 1.24.3
    kubeContext: kind-cluster-a
    createNamespace: true
    needs:
      - istio-system/istiod
    values:
      - service:
          type: NodePort
          ports:
            - name: status-port
              port: 15021
              protocol: TCP
              targetPort: 15021
            - name: http2
              port: 80
              protocol: TCP
              targetPort: 80
              nodePort: 30080
            - name: https
              port: 443
              protocol: TCP
              targetPort: 443
              nodePort: 30443

  # --- Istio base (cluster-b) ---
  - name: istio-base
    namespace: istio-system
    chart: istio/base
    version: 1.24.3
    kubeContext: kind-cluster-b
    createNamespace: true

  - name: istiod
    namespace: istio-system
    chart: istio/istiod
    version: 1.24.3
    kubeContext: kind-cluster-b
    needs:
      - istio-system/istio-base
    values:
      - pilot:
          resources:
            requests:
              cpu: 100m
              memory: 128Mi

  - name: istio-ingressgateway
    namespace: istio-ingress
    chart: istio/gateway
    version: 1.24.3
    kubeContext: kind-cluster-b
    createNamespace: true
    needs:
      - istio-system/istiod
    values:
      - service:
          type: NodePort
          ports:
            - name: status-port
              port: 15021
              protocol: TCP
              targetPort: 15021
            - name: http2
              port: 80
              protocol: TCP
              targetPort: 80
              nodePort: 30080
            - name: https
              port: 443
              protocol: TCP
              targetPort: 443
              nodePort: 30443
```

- [ ] **Step 2: Commit**

```bash
git add infra/helmfile-platform.yaml
git commit -m "feat: add helmfile platform with Cilium + Istio + Gateway"
```

---

### Task 4: K8s Manifests for 2-Cluster Model

**Files:**
- Create: `k8s/cluster-a/namespace.yaml`
- Create: `k8s/cluster-a/federated-auth-rbac.yaml`
- Create: `k8s/cluster-a/kube-federated-auth-rbac.yaml`
- Create: `k8s/cluster-a/kube-federated-auth-deployment.yaml`
- Create: `k8s/cluster-a/kube-federated-auth-service.yaml`
- Create: `k8s/cluster-a/kube-federated-auth-configmap.yaml.tpl`
- Create: `k8s/cluster-a/aqsh-rbac.yaml`
- Create: `k8s/cluster-a/aqsh-mariadb-deployment.yaml`
- Create: `k8s/cluster-a/aqsh-mariadb-service.yaml`
- Create: `k8s/cluster-a/aqsh-mongodb-deployment.yaml`
- Create: `k8s/cluster-a/aqsh-mongodb-service.yaml`
- Create: `k8s/cluster-a/redis.yaml`
- Create: `k8s/cluster-b/namespace.yaml`
- Create: `k8s/cluster-b/federated-auth-rbac.yaml`
- Create: `k8s/cluster-b/test-client.yaml`

These manifests are adapted from the existing `k8s/cluster-auth/`, `k8s/cluster-dbs/`, and `k8s/cluster-apps/` directories. Key changes:
1. kube-federated-auth moves from its own cluster to cluster-a
2. kube-auth-proxy's `TOKEN_REVIEW_URL` changes from cross-cluster NodePort to `http://kube-federated-auth.db-ops.svc.cluster.local:8080` (same cluster now)
3. aqsh services change from NodePort to ClusterIP (Istio Gateway handles external access)
4. kube-federated-auth service changes from NodePort to ClusterIP
5. kube-federated-auth configmap simplifies to 2 clusters (cluster-a + cluster-b) instead of 3-4

- [ ] **Step 1: Create cluster-a namespace manifest**

```yaml
# k8s/cluster-a/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: db-ops
```

- [ ] **Step 2: Create cluster-a federated-auth-rbac (for kube-federated-auth to validate tokens from cluster-a)**

This is the same as the existing `k8s/cluster-dbs/federated-auth-rbac.yaml` — a ServiceAccount and RBAC so kube-federated-auth can create TokenReviews against cluster-a's API server.

```yaml
# k8s/cluster-a/federated-auth-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-federated-auth-reader
  namespace: db-ops
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-federated-auth-reader
rules:
  - apiGroups: ["authentication.k8s.io"]
    resources: ["tokenreviews"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-federated-auth-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-federated-auth-reader
subjects:
  - kind: ServiceAccount
    name: kube-federated-auth-reader
    namespace: db-ops
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kube-federated-auth-reader
  namespace: db-ops
rules:
  - apiGroups: [""]
    resources: ["serviceaccounts/token"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kube-federated-auth-reader
  namespace: db-ops
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kube-federated-auth-reader
subjects:
  - kind: ServiceAccount
    name: kube-federated-auth-reader
    namespace: db-ops
```

- [ ] **Step 3: Create kube-federated-auth RBAC on cluster-a (the server itself)**

Same as existing `k8s/cluster-auth/rbac.yaml`:

```yaml
# k8s/cluster-a/kube-federated-auth-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-federated-auth
  namespace: db-ops
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kube-federated-auth
  namespace: db-ops
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "create", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kube-federated-auth
  namespace: db-ops
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kube-federated-auth
subjects:
  - kind: ServiceAccount
    name: kube-federated-auth
    namespace: db-ops
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-federated-auth-tokenreview
rules:
  - apiGroups: ["authentication.k8s.io"]
    resources: ["tokenreviews"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-federated-auth-tokenreview
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-federated-auth-tokenreview
subjects:
  - kind: ServiceAccount
    name: kube-federated-auth
    namespace: db-ops
```

- [ ] **Step 4: Create kube-federated-auth deployment (same as existing, no changes)**

```yaml
# k8s/cluster-a/kube-federated-auth-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-federated-auth
  namespace: db-ops
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kube-federated-auth
  template:
    metadata:
      labels:
        app: kube-federated-auth
    spec:
      serviceAccountName: kube-federated-auth
      containers:
        - name: kube-federated-auth
          image: ghcr.io/rophy/kube-federated-auth:3.2.0
          env:
            - name: CONFIG_PATH
              value: /etc/kube-federated-auth/config/clusters.yaml
            - name: PORT
              value: "8080"
            - name: SECRET_NAME
              value: kube-federated-auth-tokens
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: config
              mountPath: /etc/kube-federated-auth/config
              readOnly: true
            - name: ca-certs
              mountPath: /etc/kube-federated-auth/ca-certs
              readOnly: true
            - name: tokens
              mountPath: /etc/kube-federated-auth/tokens
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: kube-federated-auth-config
        - name: ca-certs
          configMap:
            name: kube-federated-auth-ca-certs
        - name: tokens
          secret:
            secretName: kube-federated-auth-tokens
```

- [ ] **Step 5: Create kube-federated-auth ClusterIP service (was NodePort, now internal)**

```yaml
# k8s/cluster-a/kube-federated-auth-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: kube-federated-auth
  namespace: db-ops
spec:
  type: ClusterIP
  selector:
    app: kube-federated-auth
  ports:
    - port: 8080
      targetPort: 8080
```

- [ ] **Step 6: Create kube-federated-auth configmap template (2-cluster model)**

```yaml
# k8s/cluster-a/kube-federated-auth-configmap.yaml.tpl
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-federated-auth-config
  namespace: db-ops
data:
  clusters.yaml: |
    authorized_clients:
      - "cluster-a/db-ops/kube-auth-proxy"
    cache:
      ttl: 60
      max_entries: 1000
    clusters:
      cluster-a:
        issuer: "${ISSUER_CLUSTER_A}"
        ca_cert: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
        token_path: "/var/run/secrets/kubernetes.io/serviceaccount/token"
      cluster-b:
        issuer: "${ISSUER_CLUSTER_B}"
        api_server: "https://${CLUSTER_B_IP}:6443"
        ca_cert: "/etc/kube-federated-auth/ca-certs/cluster-b-ca.crt"
        token_path: "/etc/kube-federated-auth/tokens/cluster-b-token"
```

Note: `cluster-a` uses the local SA token (same cluster), while `cluster-b` uses remote CA cert + token.

- [ ] **Step 7: Create aqsh RBAC on cluster-a**

```yaml
# k8s/cluster-a/aqsh-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-auth-proxy
  namespace: db-ops
```

- [ ] **Step 8: Create aqsh-mariadb deployment template**

Key change: `TOKEN_REVIEW_URL` uses in-cluster service instead of cross-cluster NodePort.

```yaml
# k8s/cluster-a/aqsh-mariadb-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aqsh-mariadb
  namespace: db-ops
spec:
  replicas: 1
  selector:
    matchLabels:
      app: aqsh-mariadb
  template:
    metadata:
      labels:
        app: aqsh-mariadb
    spec:
      serviceAccountName: kube-auth-proxy
      containers:
        - name: aqsh
          image: aqsh-mariadb
          imagePullPolicy: Never
          env:
            - name: AQSH_MODE
              value: both
            - name: AQSH_BIND
              value: "0.0.0.0:8080"
            - name: AQSH_REDIS_ADDR
              value: "redis:6379"
            - name: AQSH_TASKS_CONFIG
              value: /etc/aqsh/tasks.yaml
            - name: AQSH_TASKS_DIR
              value: /tasks
            - name: AQSH_REQUIRE_IDENTITY
              value: "true"
            - name: AQSH_WORKER_QUEUES
              value: "mariadb"
          ports:
            - containerPort: 8080
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
        - name: kube-auth-proxy
          image: ghcr.io/rophy/kube-auth-proxy:0.4.1
          env:
            - name: UPSTREAM
              value: "http://localhost:8080"
            - name: TOKEN_REVIEW_URL
              value: "http://kube-federated-auth.db-ops.svc.cluster.local:8080"
            - name: PORT
              value: "4180"
          ports:
            - containerPort: 4180
          livenessProbe:
            httpGet:
              path: /healthz
              port: 4180
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /healthz
              port: 4180
            initialDelaySeconds: 5
            periodSeconds: 10
```

- [ ] **Step 9: Create aqsh-mariadb ClusterIP service**

```yaml
# k8s/cluster-a/aqsh-mariadb-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: aqsh-mariadb
  namespace: db-ops
spec:
  type: ClusterIP
  selector:
    app: aqsh-mariadb
  ports:
    - port: 4180
      targetPort: 4180
```

- [ ] **Step 10: Create aqsh-mongodb deployment template**

```yaml
# k8s/cluster-a/aqsh-mongodb-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aqsh-mongodb
  namespace: db-ops
spec:
  replicas: 1
  selector:
    matchLabels:
      app: aqsh-mongodb
  template:
    metadata:
      labels:
        app: aqsh-mongodb
    spec:
      serviceAccountName: kube-auth-proxy
      containers:
        - name: aqsh
          image: aqsh-mongodb
          imagePullPolicy: Never
          env:
            - name: AQSH_MODE
              value: both
            - name: AQSH_BIND
              value: "0.0.0.0:8080"
            - name: AQSH_REDIS_ADDR
              value: "redis:6379"
            - name: AQSH_TASKS_CONFIG
              value: /etc/aqsh/tasks.yaml
            - name: AQSH_TASKS_DIR
              value: /tasks
            - name: AQSH_REQUIRE_IDENTITY
              value: "true"
            - name: AQSH_WORKER_QUEUES
              value: "mongodb"
          ports:
            - containerPort: 8080
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
        - name: kube-auth-proxy
          image: ghcr.io/rophy/kube-auth-proxy:0.4.1
          env:
            - name: UPSTREAM
              value: "http://localhost:8080"
            - name: TOKEN_REVIEW_URL
              value: "http://kube-federated-auth.db-ops.svc.cluster.local:8080"
            - name: PORT
              value: "4180"
          ports:
            - containerPort: 4180
          livenessProbe:
            httpGet:
              path: /healthz
              port: 4180
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /healthz
              port: 4180
            initialDelaySeconds: 5
            periodSeconds: 10
```

- [ ] **Step 11: Create aqsh-mongodb ClusterIP service**

```yaml
# k8s/cluster-a/aqsh-mongodb-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: aqsh-mongodb
  namespace: db-ops
spec:
  type: ClusterIP
  selector:
    app: aqsh-mongodb
  ports:
    - port: 4180
      targetPort: 4180
```

- [ ] **Step 12: Create redis deployment + service (copy from existing)**

```yaml
# k8s/cluster-a/redis.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: db-ops
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          ports:
            - containerPort: 6379
          readinessProbe:
            exec:
              command: ["redis-cli", "ping"]
            initialDelaySeconds: 5
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: db-ops
spec:
  selector:
    app: redis
  ports:
    - port: 6379
      targetPort: 6379
```

- [ ] **Step 13: Create cluster-b namespace manifest**

```yaml
# k8s/cluster-b/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: db-ops
---
apiVersion: v1
kind: Namespace
metadata:
  name: app-a
```

- [ ] **Step 14: Create cluster-b federated-auth-rbac**

```yaml
# k8s/cluster-b/federated-auth-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-federated-auth-reader
  namespace: db-ops
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-federated-auth-reader
rules:
  - apiGroups: ["authentication.k8s.io"]
    resources: ["tokenreviews"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-federated-auth-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-federated-auth-reader
subjects:
  - kind: ServiceAccount
    name: kube-federated-auth-reader
    namespace: db-ops
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kube-federated-auth-reader
  namespace: db-ops
rules:
  - apiGroups: [""]
    resources: ["serviceaccounts/token"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kube-federated-auth-reader
  namespace: db-ops
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kube-federated-auth-reader
subjects:
  - kind: ServiceAccount
    name: kube-federated-auth-reader
    namespace: db-ops
```

- [ ] **Step 15: Create cluster-b test-client**

```yaml
# k8s/cluster-b/test-client.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: test-client
  namespace: app-a
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-client
  namespace: app-a
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-client
  template:
    metadata:
      labels:
        app: test-client
    spec:
      serviceAccountName: test-client
      containers:
        - name: test-client
          image: curlimages/curl:latest
          command: ["sleep", "infinity"]
          volumeMounts:
            - name: token
              mountPath: /var/run/secrets/tokens
              readOnly: true
      volumes:
        - name: token
          projected:
            sources:
              - serviceAccountToken:
                  expirationSeconds: 3600
                  path: token
```

- [ ] **Step 16: Commit all manifests**

```bash
git add k8s/cluster-a/ k8s/cluster-b/
git commit -m "feat: add k8s manifests for 2-cluster model"
```

---

### Task 5: Aqsh Suite Credential Setup Script

**Files:**
- Create: `tests/aqsh/setup-credentials.sh`

This is a simplified version of `scripts/setup-credentials.sh` for the 2-cluster model. It extracts OIDC issuers and CA certs from cluster-a and cluster-b, then creates the ConfigMap and Secret that kube-federated-auth needs.

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# setup-credentials.sh — extract OIDC issuers, CA certs, and bootstrap tokens
# for the 2-cluster model (cluster-a + cluster-b).
# Outputs: creates ConfigMap + Secret in cluster-a's db-ops namespace.
# Also writes ISSUER_CLUSTER_A, ISSUER_CLUSTER_B, CLUSTER_B_IP to stdout
# as KEY=VALUE lines for the caller to capture.

CTX_A="kind-cluster-a"
CTX_B="kind-cluster-b"

get_issuer() {
  kubectl --context "$1" get --raw /.well-known/openid-configuration \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])"
}

get_ca_cert() {
  local ctx="$1" cluster_name="$2"
  kubectl --context "$ctx" config view --raw \
    -o jsonpath="{.clusters[?(@.name==\"${cluster_name}\")].cluster.certificate-authority-data}" \
    | base64 -d
}

ISSUER_CLUSTER_A=$(get_issuer "$CTX_A")
ISSUER_CLUSTER_B=$(get_issuer "$CTX_B")
CA_B=$(get_ca_cert "$CTX_B" "kind-cluster-b")
CLUSTER_B_IP=$(docker inspect cluster-b-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

TOKEN_B=$(kubectl --context "$CTX_B" -n db-ops create token kube-federated-auth-reader \
  --duration=168h \
  --audience=https://kubernetes.default.svc.cluster.local)

kubectl --context "$CTX_A" -n db-ops create configmap kube-federated-auth-ca-certs \
  --from-literal="cluster-b-ca.crt=${CA_B}" \
  --dry-run=client -o yaml | kubectl --context "$CTX_A" apply -f -

kubectl --context "$CTX_A" -n db-ops create secret generic kube-federated-auth-tokens \
  --from-literal="cluster-b-token=${TOKEN_B}" \
  --dry-run=client -o yaml | kubectl --context "$CTX_A" apply -f -

echo "ISSUER_CLUSTER_A=${ISSUER_CLUSTER_A}"
echo "ISSUER_CLUSTER_B=${ISSUER_CLUSTER_B}"
echo "CLUSTER_B_IP=${CLUSTER_B_IP}"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x tests/aqsh/setup-credentials.sh
```

- [ ] **Step 3: Commit**

```bash
git add tests/aqsh/setup-credentials.sh
git commit -m "feat: add credential setup script for 2-cluster model"
```

---

### Task 6: Aqsh Suite Helmfile

**Files:**
- Create: `tests/aqsh/helmfile.yaml`

This helmfile is not a Helm chart — it uses `kubectl apply` via helmfile's raw chart capabilities or hooks. However, since we're deploying plain manifests (not Helm charts), a simpler approach is to keep the kubectl-apply logic in the setup_suite script and reserve helmfile for actual Helm chart deployments (mariadb-operator, etc.). For the aqsh suite, the infra is all plain manifests.

**Decision:** The aqsh suite uses kubectl apply for its manifests (no Helm charts needed). Helmfile is reserved for suites that need Helm charts (mariadb, mongodb). The setup_suite script handles Layer 3 directly.

- [ ] **Step 1: Skip helmfile for aqsh suite**

No file needed. The aqsh suite's Layer 3 is handled by `setup_suite.bash` calling `kubectl apply` on the manifests in `k8s/cluster-a/` and `k8s/cluster-b/`. Document this decision in the setup_suite script.

- [ ] **Step 2: Commit** (nothing to commit for this task — proceed to next task)

---

### Task 7: Aqsh Suite Test Helper

**Files:**
- Create: `tests/aqsh/test_helper.bash`

This is the per-suite helper that replaces `tests/test_helper/common_setup.bash`. It sets up URL variables for the new Istio Gateway routing model.

- [ ] **Step 1: Create the helper**

```bash
#!/usr/bin/env bash

# test_helper.bash — shared helpers for the aqsh test suite
# Load from setup_file() in each .bats file:
#   load 'test_helper'

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${HELPER_DIR}/../.." && pwd)"

load "${ROOT_DIR}/tests/test_helper/bats-support/load.bash"
load "${ROOT_DIR}/tests/test_helper/bats-assert/load.bash"

export ROOT_DIR
export CTX_A="kind-cluster-a"
export CTX_B="kind-cluster-b"

export MARIADB_AQSH_URL="http://aqsh-mariadb.kind-a.localhost:38001"
export MONGODB_AQSH_URL="http://aqsh-mongodb.kind-a.localhost:38001"
export FEDAUTH_URL="http://fedauth.kind-a.localhost:38001"

aqsh_suite_setup() {
  # Wait for test-client pod to be ready, then resolve its name
  kubectl --context "$CTX_B" -n app-a wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n app-a \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  export TEST_POD

  if [[ "${1:-}" == "--create-token" ]]; then
    TOKEN=$(kubectl --context "$CTX_B" -n app-a create token test-client --duration=30m)
    export TOKEN
  fi
}

kexec() {
  kubectl --context "$CTX_B" -n app-a exec "$TEST_POD" -- sh -c "$1"
}

http_post() {
  local url="$1" body="$2"
  local response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\\n%{http_code}' \
    -X POST '${url}' \
    -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Content-Type: application/json' \
    -d '${body}'")

  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-540}"
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/tasks/${task_id}'")
    export TASK_RESPONSE

    status=$(echo "$TASK_RESPONSE" | jq -r '.status' 2>/dev/null || true)

    if [[ "$status" == "completed" ]]; then
      return 0
    elif [[ "$status" == "failed" ]]; then
      echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2
      return 1
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}
```

- [ ] **Step 2: Commit**

```bash
git add tests/aqsh/test_helper.bash
git commit -m "feat: add aqsh suite test helper with Istio Gateway URLs"
```

---

### Task 8: Aqsh Suite Setup/Teardown

**Files:**
- Create: `tests/aqsh/setup_suite.bash`

- [ ] **Step 1: Create setup_suite.bash**

```bash
#!/usr/bin/env bash

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local INFRA_DIR="${ROOT_DIR}/infra"
  local K8S_DIR="${ROOT_DIR}/k8s"
  local SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"

  # Layer 1: ensure clusters exist
  "${INFRA_DIR}/create-clusters.sh"

  # Layer 2: shared platform (Cilium + Istio + Gateway)
  helmfile sync -f "${INFRA_DIR}/helmfile-platform.yaml"

  # Layer 3: suite-specific infra

  # 3a. Namespaces + RBAC
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/namespace.yaml"
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/federated-auth-rbac.yaml"
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/kube-federated-auth-rbac.yaml"
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/aqsh-rbac.yaml"
  kubectl --context "$CTX_B" apply -f "${K8S_DIR}/cluster-b/namespace.yaml"
  kubectl --context "$CTX_B" apply -f "${K8S_DIR}/cluster-b/federated-auth-rbac.yaml"

  # 3b. Credentials (OIDC issuers, CA certs, bootstrap tokens)
  local cred_output
  cred_output=$("${SUITE_DIR}/setup-credentials.sh")
  local ISSUER_CLUSTER_A ISSUER_CLUSTER_B CLUSTER_B_IP
  eval "$(echo "$cred_output" | grep '^ISSUER_CLUSTER_A=\|^ISSUER_CLUSTER_B=\|^CLUSTER_B_IP=')"
  export ISSUER_CLUSTER_A ISSUER_CLUSTER_B CLUSTER_B_IP

  # 3c. kube-federated-auth configmap + deployment
  envsubst < "${K8S_DIR}/cluster-a/kube-federated-auth-configmap.yaml.tpl" \
    | kubectl --context "$CTX_A" apply -f -
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/kube-federated-auth-deployment.yaml"
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/kube-federated-auth-service.yaml"

  echo "Waiting for kube-federated-auth..."
  kubectl --context "$CTX_A" -n db-ops rollout status deployment/kube-federated-auth --timeout=120s

  # 3d. Build and load aqsh images
  skaffold build --filename="${ROOT_DIR}/skaffold.yaml" --tag=latest --quiet
  kind load docker-image aqsh-mariadb:latest --name cluster-a
  kind load docker-image aqsh-mongodb:latest --name cluster-a

  # 3e. Redis + aqsh deployments
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/redis.yaml"
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/aqsh-mariadb-service.yaml"
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/aqsh-mongodb-service.yaml"
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/aqsh-mariadb-deployment.yaml"
  kubectl --context "$CTX_A" apply -f "${K8S_DIR}/cluster-a/aqsh-mongodb-deployment.yaml"

  echo "Waiting for Redis..."
  kubectl --context "$CTX_A" -n db-ops rollout status deployment/redis --timeout=120s
  echo "Waiting for aqsh-mariadb..."
  kubectl --context "$CTX_A" -n db-ops rollout status deployment/aqsh-mariadb --timeout=120s
  echo "Waiting for aqsh-mongodb..."
  kubectl --context "$CTX_A" -n db-ops rollout status deployment/aqsh-mongodb --timeout=120s

  # 3f. Istio VirtualServices for routing
  kubectl --context "$CTX_A" -n istio-ingress apply -f - <<'VSEOF'
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: aqsh-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "*.kind-a.localhost"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: aqsh-mariadb
spec:
  hosts:
    - "aqsh-mariadb.kind-a.localhost"
  gateways:
    - aqsh-gateway
  http:
    - route:
        - destination:
            host: aqsh-mariadb.db-ops.svc.cluster.local
            port:
              number: 4180
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: aqsh-mongodb
spec:
  hosts:
    - "aqsh-mongodb.kind-a.localhost"
  gateways:
    - aqsh-gateway
  http:
    - route:
        - destination:
            host: aqsh-mongodb.db-ops.svc.cluster.local
            port:
              number: 4180
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: fedauth
spec:
  hosts:
    - "fedauth.kind-a.localhost"
  gateways:
    - aqsh-gateway
  http:
    - route:
        - destination:
            host: kube-federated-auth.db-ops.svc.cluster.local
            port:
              number: 8080
VSEOF

  # 3g. Test client on cluster-b
  kubectl --context "$CTX_B" apply -f "${K8S_DIR}/cluster-b/test-client.yaml"
  echo "Waiting for test-client..."
  kubectl --context "$CTX_B" -n app-a rollout status deployment/test-client --timeout=60s
}

teardown_suite() {
  if [[ "${TEARDOWN:-}" != "true" ]]; then
    return 0
  fi

  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"

  # Clean up VirtualServices and Gateway
  kubectl --context "$CTX_A" -n istio-ingress delete gateway aqsh-gateway --ignore-not-found
  kubectl --context "$CTX_A" -n istio-ingress delete virtualservice aqsh-mariadb aqsh-mongodb fedauth --ignore-not-found

  # Clean up suite-specific resources (keep clusters + platform)
  kubectl --context "$CTX_A" delete ns db-ops --ignore-not-found
  kubectl --context "$CTX_B" delete ns db-ops app-a --ignore-not-found
}
```

- [ ] **Step 2: Commit**

```bash
git add tests/aqsh/setup_suite.bash
git commit -m "feat: add aqsh suite setup/teardown with idempotent layered infra"
```

---

### Task 9: Aqsh Suite BATS Tests

**Files:**
- Create: `tests/aqsh/auth.bats`
- Create: `tests/aqsh/hello_task.bats`
- Create: `tests/aqsh/in_pod.bats`

These are adapted from the existing `tests/common/` tests, updated to use the new test helper and Istio Gateway URLs.

- [ ] **Step 1: Create auth.bats**

```bash
# tests/aqsh/auth.bats
setup_file() {
  load 'test_helper'
  aqsh_suite_setup
}

setup() {
  load 'test_helper'
}

@test "fedauth health check returns 200" {
  run kexec "curl -s -o /dev/null -w '%{http_code}' '${FEDAUTH_URL}/health'"
  assert_output "200"
}

@test "unauthenticated request to aqsh-mariadb returns 401" {
  run kexec "curl -s -o /dev/null -w '%{http_code}' '${MARIADB_AQSH_URL}/health'"
  assert_output "401"
}

@test "unauthenticated request to aqsh-mongodb returns 401" {
  run kexec "curl -s -o /dev/null -w '%{http_code}' '${MONGODB_AQSH_URL}/health'"
  assert_output "401"
}
```

- [ ] **Step 2: Create hello_task.bats**

```bash
# tests/aqsh/hello_task.bats
setup_file() {
  load 'test_helper'
  aqsh_suite_setup --create-token
}

setup() {
  load 'test_helper'
}

@test "hello task completes with expected logs via aqsh-mariadb" {
  http_post "${MARIADB_AQSH_URL}/tasks/common%2Fhello" '{"name": "World"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')

  wait_for_task "$MARIADB_AQSH_URL" "$task_id" 30

  local logs
  logs=$(kexec "curl -s -m 5 \
    -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Accept: text/event-stream' \
    '${MARIADB_AQSH_URL}/tasks/${task_id}/logs?follow=false'" 2>/dev/null || true)

  echo "$logs"
  [[ "$logs" == *"Hello, World!"* ]]
}

@test "hello task submits via aqsh-mongodb" {
  http_post "${MONGODB_AQSH_URL}/tasks/common%2Fhello" '{"name": "World"}'
  assert_equal "$HTTP_CODE" "202"
}
```

- [ ] **Step 3: Create in_pod.bats**

```bash
# tests/aqsh/in_pod.bats
setup_file() {
  load 'test_helper'
  aqsh_suite_setup
}

setup() {
  load 'test_helper'
}

@test "in-pod request to aqsh-mariadb via projected token returns 202" {
  run kubectl --context "$CTX_B" -n app-a exec "$TEST_POD" -- \
    sh -c 'curl -s -o /dev/null -w "%{http_code}" \
      -X POST "http://aqsh-mariadb.kind-a.localhost:38001/tasks/common%2Fhello" \
      -H "Authorization: Bearer $(cat /var/run/secrets/tokens/token)" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"from-pod\"}"'
  assert_output "202"
}

@test "in-pod request to aqsh-mongodb via projected token returns 202" {
  run kubectl --context "$CTX_B" -n app-a exec "$TEST_POD" -- \
    sh -c 'curl -s -o /dev/null -w "%{http_code}" \
      -X POST "http://aqsh-mongodb.kind-a.localhost:38001/tasks/common%2Fhello" \
      -H "Authorization: Bearer $(cat /var/run/secrets/tokens/token)" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"from-pod\"}"'
  assert_output "202"
}
```

**Important note for in_pod.bats:** The curl inside the test-client pod (on cluster-b) needs to resolve `aqsh-mariadb.kind-a.localhost` to 127.0.0.1 and reach host port 38001. This works because `.localhost` resolves to 127.0.0.1 on the host, but inside a Kind container, `localhost` resolves to the container's own loopback. The test-client pod would need to reach the Kind host network. This may require using the cluster-a node IP instead. If `.localhost` DNS doesn't work from inside the pod, fall back to:

```bash
# Alternative: use cluster-a's Docker IP with Host header
CLUSTER_A_IP=$(docker inspect cluster-a-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
curl -H "Host: aqsh-mariadb.kind-a.localhost" "http://${CLUSTER_A_IP}:30080/tasks/..."
```

This issue should be validated during implementation. The `kexec`-based tests (auth.bats, hello_task.bats) run curl from inside the pod via kubectl exec from the host, so they use host networking and `.localhost` works. But `in_pod.bats` runs curl directly inside the pod where `.localhost` may not reach the host. The implementer should test this and adjust URLs accordingly.

- [ ] **Step 4: Commit**

```bash
git add tests/aqsh/auth.bats tests/aqsh/hello_task.bats tests/aqsh/in_pod.bats
git commit -m "feat: add aqsh BATS test suite"
```

---

### Task 10: CI Workflow Update

**Files:**
- Modify: `.github/workflows/bats.yaml`

- [ ] **Step 1: Update the workflow**

Replace the current 4-combo `{single,dual} × {operator=true,false}` matrix with a 3-suite matrix. Add helmfile to the tool install step.

```yaml
# .github/workflows/bats.yaml
name: BATS Integration Tests

'on':
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  integration:
    runs-on: [self-hosted, aws-runner]
    timeout-minutes: 60
    strategy:
      fail-fast: false
      max-parallel: 3
      matrix:
        suite: [aqsh]
    env:
      TEARDOWN: "true"
    steps:
      - name: Check out repository
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with:
          persist-credentials: false

      - name: Tune kernel limits for Kind
        run: |
          sudo sysctl fs.inotify.max_user_watches=524288
          sudo sysctl fs.inotify.max_user_instances=512

      - name: Install CLI tools
        run: |
          set -euo pipefail

          # kind
          if ! command -v kind &>/dev/null; then
            sudo curl -fsSL -o /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.29.0/kind-linux-amd64
            sudo chmod +x /usr/local/bin/kind
          fi

          # kubectl
          if ! command -v kubectl &>/dev/null; then
            sudo curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/v1.33.1/bin/linux/amd64/kubectl"
            sudo chmod +x /usr/local/bin/kubectl
          fi

          # helm
          if ! command -v helm &>/dev/null; then
            curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
          fi

          # helmfile
          if ! command -v helmfile &>/dev/null; then
            sudo curl -fsSL -o /usr/local/bin/helmfile https://github.com/helmfile/helmfile/releases/download/v1.5.2/helmfile_1.5.2_linux_amd64.tar.gz
            # helmfile is distributed as tarball
            cd /tmp && curl -fsSL https://github.com/helmfile/helmfile/releases/download/v1.5.2/helmfile_1.5.2_linux_amd64.tar.gz | sudo tar xz -C /usr/local/bin helmfile
            sudo chmod +x /usr/local/bin/helmfile
          fi

          # skaffold
          if ! command -v skaffold &>/dev/null; then
            sudo curl -fsSL -o /usr/local/bin/skaffold https://storage.googleapis.com/skaffold/releases/v2.16.0/skaffold-linux-amd64
            sudo chmod +x /usr/local/bin/skaffold
          fi

          # bats
          if ! command -v bats &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y bats
          fi

      - name: Install BATS helper libraries
        run: ./scripts/install-bats-libs.sh

      - name: Run ${{ matrix.suite }} test suite
        run: bats tests/${{ matrix.suite }}/

      - name: Tear down clusters
        if: always()
        run: |
          kind delete cluster --name cluster-a 2>/dev/null || true
          kind delete cluster --name cluster-b 2>/dev/null || true
```

Note: The matrix starts with only `[aqsh]`. Add `mariadb` and `mongodb` as those suites are implemented.

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/bats.yaml
git commit -m "feat: update CI to per-suite matrix with helmfile + 2-cluster model"
```

---

### Task 11: End-to-End Validation

**Files:** None (testing only)

- [ ] **Step 1: Clean up any existing test clusters**

```bash
kind delete cluster --name cluster-a 2>/dev/null || true
kind delete cluster --name cluster-b 2>/dev/null || true
```

- [ ] **Step 2: Run the aqsh test suite end-to-end**

```bash
bats tests/aqsh/
```

Expected: All tests pass. The setup_suite creates clusters, deploys platform, deploys aqsh infra, and runs tests.

- [ ] **Step 3: Verify idempotency — run again without teardown**

```bash
bats tests/aqsh/
```

Expected: Second run is faster (clusters + platform already exist), all tests pass again.

- [ ] **Step 4: Verify teardown**

```bash
TEARDOWN=true bats tests/aqsh/
```

Expected: Tests pass, then suite-specific resources are cleaned up.

- [ ] **Step 5: Fix any issues found during validation**

If tests fail, debug and fix. Common issues to check:
- `.localhost` DNS resolution from inside pods (see note in Task 9)
- Istio sidecar injection (pods in `db-ops` namespace may need `istio-injection=enabled` label)
- aqsh-mariadb/mongodb deployment template is `.yaml.tpl` but `kubectl apply` expects plain YAML — the template has no `${VAR}` substitutions anymore (TOKEN_REVIEW_URL is hardcoded to in-cluster service), so rename to `.yaml` or use `envsubst` in setup_suite even though there's nothing to substitute

---

### Task 12: Documentation Update

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update CLAUDE.md kubectl contexts section**

Replace the current 4-cluster context table with the 2-cluster model:

```markdown
## kubectl Contexts

| Context | Cluster | Purpose |
|---------|---------|---------|
| kind-cluster-a | cluster-a | Server-side: kube-federated-auth, aqsh, Redis, databases, operators |
| kind-cluster-b | cluster-b | Client-side: test-client workloads |
```

- [ ] **Step 2: Update namespace table**

```markdown
## Namespaces

| Namespace | Clusters | Purpose |
|-----------|----------|---------|
| db-ops | cluster-a, cluster-b | Control plane (federated auth, aqsh, credentials) |
| istio-system | cluster-a, cluster-b | Istio control plane |
| istio-ingress | cluster-a, cluster-b | Istio ingress gateway |
| app-a | cluster-b | Test-client workloads |
| db-1, db-2, db-3 | cluster-a | MariaDB instances (mariadb suite) |
| mongo-1, mongo-2, mongo-3 | cluster-a | MongoDB instances (mongodb suite) |
```

- [ ] **Step 3: Update Quick Start section**

```markdown
## Quick Start

```bash
# Run aqsh test suite (creates clusters + infra automatically)
bats tests/aqsh/

# Run with teardown
TEARDOWN=true bats tests/aqsh/

# Clean up everything
kind delete cluster --name cluster-a
kind delete cluster --name cluster-b
```
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for 2-cluster consolidated model"
```
