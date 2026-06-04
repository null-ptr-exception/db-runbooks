#!/usr/bin/env bash
# aqsh test suite setup
#
# Deploys the aqsh framework layer on top of the shared infra (2 Kind clusters
# with Cilium + Istio).
#
# cluster-a (server): kube-federated-auth, kube-auth-proxy + aqsh, Redis
# cluster-b (client): test-client pod
#
# All cross-component traffic goes through Istio Gateway:
#   test-client (cluster-b) → aqsh.kind-a.test:30080 → kube-auth-proxy → aqsh
#   kube-auth-proxy (cluster-a) → fedauth.kind-a.test:30080 → kube-federated-auth

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  source "${ROOT_DIR}/infra/deploy.sh"

  # Layer 0: shared infra (idempotent)
  setup_infra

  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"
  local REGISTRY="localhost:5005"
  local NS="aqsh-test"

  # --- Namespaces ---
  for ctx in "$CTX_A" "$CTX_B"; do
    kubectl --context "$ctx" create ns "$NS" --dry-run=client -o yaml \
      | kubectl --context "$ctx" apply -f -
  done

  # --- Credentials: extract issuers, CA certs, bootstrap tokens ---
  local ISSUER_A ISSUER_B CA_A CA_B TOKEN_A TOKEN_B

  ISSUER_A=$(kubectl --context "$CTX_A" get --raw /.well-known/openid-configuration \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])")
  ISSUER_B=$(kubectl --context "$CTX_B" get --raw /.well-known/openid-configuration \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])")

  CA_A=$(kubectl --context "$CTX_A" config view --raw \
    -o jsonpath="{.clusters[?(@.name==\"kind-cluster-a\")].cluster.certificate-authority-data}" | base64 -d)
  CA_B=$(kubectl --context "$CTX_B" config view --raw \
    -o jsonpath="{.clusters[?(@.name==\"kind-cluster-b\")].cluster.certificate-authority-data}" | base64 -d)

  # SA for fedauth to call TokenReview on each cluster
  kubectl --context "$CTX_A" -n "$NS" apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-federated-auth-reader
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
    namespace: aqsh-test
EOF

  kubectl --context "$CTX_B" -n "$NS" apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-federated-auth-reader
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
    namespace: aqsh-test
EOF

  TOKEN_A=$(kubectl --context "$CTX_A" -n "$NS" create token kube-federated-auth-reader \
    --duration=168h --audience=https://kubernetes.default.svc.cluster.local)
  TOKEN_B=$(kubectl --context "$CTX_B" -n "$NS" create token kube-federated-auth-reader \
    --duration=168h --audience=https://kubernetes.default.svc.cluster.local)

  # --- kube-federated-auth on cluster-a ---
  kubectl --context "$CTX_A" -n "$NS" apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-federated-auth
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
    namespace: aqsh-test
EOF

  kubectl --context "$CTX_A" -n "$NS" create configmap kube-federated-auth-ca-certs \
    --from-literal="cluster-a-ca.crt=${CA_A}" \
    --from-literal="cluster-b-ca.crt=${CA_B}" \
    --dry-run=client -o yaml | kubectl --context "$CTX_A" -n "$NS" apply -f -

  kubectl --context "$CTX_A" -n "$NS" create secret generic kube-federated-auth-tokens \
    --from-literal="cluster-a-token=${TOKEN_A}" \
    --from-literal="cluster-b-token=${TOKEN_B}" \
    --dry-run=client -o yaml | kubectl --context "$CTX_A" -n "$NS" apply -f -

  kubectl --context "$CTX_A" -n "$NS" create configmap kube-federated-auth-config \
    --from-literal=clusters.yaml="
authorized_clients:
  - \"cluster-a/${NS}/kube-auth-proxy\"
cache:
  ttl: 60
  max_entries: 1000
clusters:
  cluster-a:
    issuer: \"${ISSUER_A}\"
    api_server: \"https://${CLUSTER_A_IP}:6443\"
    ca_cert: \"/etc/kube-federated-auth/ca-certs/cluster-a-ca.crt\"
    token_path: \"/etc/kube-federated-auth/tokens/cluster-a-token\"
  cluster-b:
    issuer: \"${ISSUER_B}\"
    api_server: \"https://${CLUSTER_B_IP}:6443\"
    ca_cert: \"/etc/kube-federated-auth/ca-certs/cluster-b-ca.crt\"
    token_path: \"/etc/kube-federated-auth/tokens/cluster-b-token\"
" --dry-run=client -o yaml | kubectl --context "$CTX_A" -n "$NS" apply -f -

  kubectl --context "$CTX_A" -n "$NS" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-federated-auth
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
          image: ${REGISTRY}/kube-federated-auth:latest
          env:
            - name: CONFIG_PATH
              value: /etc/kube-federated-auth/config/clusters.yaml
            - name: PORT
              value: "8080"
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
---
apiVersion: v1
kind: Service
metadata:
  name: kube-federated-auth
spec:
  selector:
    app: kube-federated-auth
  ports:
    - port: 8080
      targetPort: 8080
EOF

  # --- Redis on cluster-a ---
  kubectl --context "$CTX_A" -n "$NS" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
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
          image: ${REGISTRY}/redis:latest
          ports:
            - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  selector:
    app: redis
  ports:
    - port: 6379
      targetPort: 6379
EOF

  # --- aqsh (with kube-auth-proxy sidecar) on cluster-a ---
  # kube-auth-proxy reaches fedauth via Istio Gateway, simulating cross-cluster
  kubectl --context "$CTX_A" -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-auth-proxy
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aqsh
spec:
  replicas: 1
  selector:
    matchLabels:
      app: aqsh
  template:
    metadata:
      labels:
        app: aqsh
    spec:
      serviceAccountName: kube-auth-proxy
      containers:
        - name: aqsh
          image: ${REGISTRY}/aqsh-mariadb:latest
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
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
        - name: kube-auth-proxy
          image: ${REGISTRY}/kube-auth-proxy:latest
          env:
            - name: UPSTREAM
              value: "http://localhost:8080"
            - name: TOKEN_REVIEW_URL
              value: "http://fedauth.kind-a.test:30080"
            - name: PORT
              value: "4180"
          ports:
            - containerPort: 4180
          readinessProbe:
            httpGet:
              path: /healthz
              port: 4180
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: aqsh
spec:
  selector:
    app: aqsh
  ports:
    - port: 4180
      targetPort: 4180
EOF

  # --- Istio Gateway + VirtualServices on cluster-a ---
  kubectl --context "$CTX_A" -n istio-ingress apply -f - <<EOF
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
        - "fedauth.kind-a.test"
        - "aqsh.kind-a.test"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: fedauth
spec:
  hosts:
    - "fedauth.kind-a.test"
  gateways:
    - aqsh-gateway
  http:
    - route:
        - destination:
            host: kube-federated-auth.${NS}.svc.cluster.local
            port:
              number: 8080
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: aqsh
spec:
  hosts:
    - "aqsh.kind-a.test"
  gateways:
    - aqsh-gateway
  http:
    - route:
        - destination:
            host: aqsh.${NS}.svc.cluster.local
            port:
              number: 4180
EOF

  # --- test-client on cluster-b ---
  kubectl --context "$CTX_B" -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: test-client
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-client
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
          image: ${REGISTRY}/curl:latest
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
EOF

  # --- Push required images to local registry ---
  for img in ghcr.io/rophy/kube-federated-auth:3.2.0 ghcr.io/rophy/kube-auth-proxy:0.4.1 redis:alpine curlimages/curl:latest; do
    local name="${img%%:*}"
    name="${name##*/}"
    local tag="${img##*:}"
    docker pull --platform linux/amd64 "$img"
    docker tag "$img" "${REGISTRY}/${name}:latest"
    docker push "${REGISTRY}/${name}:latest"
  done

  # Build and push aqsh image
  skaffold build --filename="${ROOT_DIR}/skaffold.yaml" --tag=latest
  docker tag aqsh-mariadb:latest "${REGISTRY}/aqsh-mariadb:latest"
  docker push "${REGISTRY}/aqsh-mariadb:latest"

  # --- Wait for deployments ---
  echo "Waiting for kube-federated-auth..."
  kubectl --context "$CTX_A" -n "$NS" rollout status deployment/kube-federated-auth --timeout=120s

  echo "Waiting for redis..."
  kubectl --context "$CTX_A" -n "$NS" rollout status deployment/redis --timeout=60s

  echo "Waiting for aqsh..."
  kubectl --context "$CTX_A" -n "$NS" rollout status deployment/aqsh --timeout=120s

  echo "Waiting for test-client..."
  kubectl --context "$CTX_B" -n "$NS" rollout status deployment/test-client --timeout=60s

  echo "=== aqsh test suite setup complete ==="
}

teardown_suite() {
  if [[ "${TEARDOWN:-}" != "true" ]]; then
    return 0
  fi

  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"
  local NS="aqsh-test"

  kubectl --context "$CTX_A" -n istio-ingress delete gateway aqsh-gateway --ignore-not-found
  kubectl --context "$CTX_A" -n istio-ingress delete virtualservice fedauth aqsh --ignore-not-found
  kubectl --context "$CTX_A" delete ns "$NS" --ignore-not-found
  kubectl --context "$CTX_B" delete ns "$NS" --ignore-not-found
}
