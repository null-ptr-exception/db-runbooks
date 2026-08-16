#!/usr/bin/env bash
# MariaDB test suite setup
#
# Deploys the MariaDB control plane + test instances on the 2-cluster infra.
#
# cluster-a (server):
#   db-ops:     kube-federated-auth, kube-auth-proxy + aqsh-mariadb, Redis
#   mariadb-1 / mariadb-2: independently configured MariaDB instances
# cluster-b (server + client):
#   db-ops:     test-client pod, kube-auth-proxy + aqsh-mariadb, Redis
#   mariadb-1:  MariaDB instance (operator-managed)
#   minio:      MinIO for backup tests

wait_deployment_rollout() {
  local ctx="$1"
  local ns="$2"
  local deployment="$3"
  local timeout="$4"

  if kubectl --context "$ctx" -n "$ns" rollout status "deployment/${deployment}" --timeout="$timeout"; then
    return 0
  fi

  echo "=== diagnostics for ${ctx}/${ns}/deployment/${deployment} ===" >&2
  kubectl --context "$ctx" -n "$ns" get pods -o wide >&2 || true
  kubectl --context "$ctx" -n "$ns" describe "deployment/${deployment}" >&2 || true
  kubectl --context "$ctx" -n "$ns" describe pods -l "app=${deployment}" >&2 || true
  kubectl --context "$ctx" -n "$ns" logs -l "app=${deployment}" --all-containers --tail=200 >&2 || true
  return 1
}

ensure_minio_bucket() {
  local ctx="$1"
  local bucket="$2"
  local pod="minio-mc-${bucket}"

  # No --wait=false: the immediately-following `run` recreates a pod with
  # this exact name, and Kubernetes won't accept that until the old one has
  # actually finished terminating — a fire-and-forget delete can race it.
  kubectl --context "$ctx" -n minio delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$ctx" -n minio run "$pod" \
    --image=minio/mc \
    --restart=Never \
    --rm -i \
    --pod-running-timeout=180s \
    --command -- sh -c \
      "timeout 60 mc alias set local http://minio:9000 minioadmin minioadmin-changeme-prod && timeout 60 mc mb -p local/${bucket}"
}

# ---------------------------------------------------------------------------
# ensure_vault_approle <context>
#
# Provisions a dev-mode Vault (see tests/chart/templates/vault.yaml) with an
# AppRole that migration/export-db-env-to-vault and migration/import-db-env-from-vault
# use: enables the approle auth method, writes a policy scoped to
# secret/data/migration/*, creates a role bound to it, and mints a secret_id.
# Runs from a throwaway pod in the vault namespace (in-cluster DNS, no need
# for the cross-cluster *.kind-b.test gateway hostname at provisioning time).
#
# Sets VAULT_ROLE_ID / VAULT_SECRET_ID in the caller's shell on success.
# ---------------------------------------------------------------------------
ensure_vault_approle() {
  local ctx="$1"
  local ns="vault"
  local pod="vault-provision"
  local root_token="vault-dev-root-token" # must match tests/chart/values.yaml vault.devRootToken

  # No --wait=false: the immediately-following `run` recreates a pod with
  # this exact name, and Kubernetes won't accept that until the old one has
  # actually finished terminating — a fire-and-forget delete can race it.
  kubectl --context "$ctx" -n "$ns" delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true

  local out
  out=$(kubectl --context "$ctx" -n "$ns" run "$pod" \
    --image=curlimages/curl:8.10.1 \
    --restart=Never \
    --rm -i \
    --pod-running-timeout=180s \
    --env="VAULT_TOKEN=${root_token}" \
    --command -- sh -c '
      set -e
      VADDR="http://vault:8200"
      curl -sf -H "X-Vault-Token: $VAULT_TOKEN" -X POST -d "{\"type\":\"approle\"}" "$VADDR/v1/sys/auth/approle" >/dev/null 2>&1 || true
      curl -sf -H "X-Vault-Token: $VAULT_TOKEN" -X PUT -d "{\"policy\":\"path \\\"secret/data/migration/*\\\" { capabilities = [\\\"create\\\",\\\"read\\\",\\\"update\\\"] }\"}" "$VADDR/v1/sys/policies/acl/migration-relay" >/dev/null
      curl -sf -H "X-Vault-Token: $VAULT_TOKEN" -X POST -d "{\"token_policies\":\"migration-relay\",\"token_ttl\":\"1h\",\"token_max_ttl\":\"4h\"}" "$VADDR/v1/auth/approle/role/migration-relay" >/dev/null
      curl -sf -H "X-Vault-Token: $VAULT_TOKEN" "$VADDR/v1/auth/approle/role/migration-relay/role-id"
      echo
      curl -sf -H "X-Vault-Token: $VAULT_TOKEN" -X POST "$VADDR/v1/auth/approle/role/migration-relay/secret-id"
    ')

  local role_json secret_json
  role_json=$(printf '%s\n' "$out" | sed -n '1p')
  secret_json=$(printf '%s\n' "$out" | sed -n '2p')

  VAULT_ROLE_ID=$(printf '%s' "$role_json" | jq -r '.data.role_id // empty')
  VAULT_SECRET_ID=$(printf '%s' "$secret_json" | jq -r '.data.secret_id // empty')
  export VAULT_ROLE_ID VAULT_SECRET_ID

  if [[ -z "$VAULT_ROLE_ID" || -z "$VAULT_SECRET_ID" ]]; then
    echo "Failed to provision Vault AppRole (role_id/secret_id empty)" >&2
    echo "role response: ${role_json}" >&2
    echo "secret response: ${secret_json}" >&2
    return 1
  fi
}

delete_namespace_and_wait() {
  local ctx="$1"
  local ns="$2"
  local timeout="${3:-300s}"

  if kubectl --context "$ctx" delete ns "$ns" --ignore-not-found --wait=true --timeout="$timeout"; then
    return 0
  fi

  echo "=== namespace delete diagnostics for ${ctx}/${ns} ===" >&2
  kubectl --context "$ctx" get ns "$ns" -o yaml >&2 || true
  kubectl --context "$ctx" -n "$ns" get users.k8s.mariadb.com,grants.k8s.mariadb.com,mariadbs.k8s.mariadb.com,physicalbackups.k8s.mariadb.com -o wide >&2 || true
  return 1
}

# ---------------------------------------------------------------------------
# deploy_throwaway_mariadb <namespace> [context]
#
# Creates a namespace, RBAC RoleBinding (against the aqsh-mariadb-manager
# ClusterRole installed by the mariadbRbac release), and a non-replicated
# MariaDB CR. Used by individual .bats files (get-db-env, check_connection,
# migration_*) for a disposable per-file instance isolated from mariadb-1.
# ---------------------------------------------------------------------------
deploy_throwaway_mariadb() {
  local namespace="$1"
  local ctx="${2:-kind-cluster-a}"

  kubectl --context "$ctx" create ns "$namespace" --dry-run=client -o yaml \
    | kubectl --context "$ctx" apply -f -

  kubectl --context "$ctx" -n "$namespace" apply -f - <<EOF
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

  kubectl --context "$ctx" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mariadb
  namespace: ${namespace}
stringData:
  password: mariadb-test-pass
---
apiVersion: k8s.mariadb.com/v1alpha1
kind: MariaDB
metadata:
  name: mariadb
  namespace: ${namespace}
spec:
  rootPasswordSecretKeyRef:
    name: mariadb
    key: password
  port: 3306
  image: mariadb:10.6
  storage:
    size: 1Gi
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      memory: 1Gi
EOF

  echo "Waiting for ${namespace} to be ready..."
  if ! kubectl --context "$ctx" -n "$namespace" wait \
    --for=condition=Ready mariadb/mariadb --timeout=300s 2>/dev/null; then
    echo "MariaDB CR not ready after 300s. Checking status..." >&2
    kubectl --context "$ctx" -n "$namespace" get mariadb mariadb -o yaml | tail -50 >&2
    kubectl --context "$ctx" -n "$namespace" get pods >&2
    return 1
  fi
}

setup_suite() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  "${ROOT_DIR}/scripts/preflight.sh"
  source "${ROOT_DIR}/infra/deploy.sh"

  local CTX_A="kind-cluster-a"
  local CTX_B="kind-cluster-b"
  local NS="db-ops"

  # Layer 0: shared infra (idempotent)
  setup_infra

  wait_ns_gone "$CTX_A" db-ops mariadb-1 mariadb-2
  wait_ns_gone "$CTX_B" db-ops mariadb-1 minio

  # Install mariadb-operator CRDs and operator on both clusters
  helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator 2>/dev/null || true
  helm repo update mariadb-operator

  for ctx in "$CTX_A" "$CTX_B"; do
    echo "Installing mariadb-operator CRDs on ${ctx}..."
    helm upgrade --install mariadb-operator-crds mariadb-operator/mariadb-operator-crds \
      --kube-context "$ctx" \
      --wait
    echo "Installing mariadb-operator on ${ctx}..."
    helm upgrade --install mariadb-operator mariadb-operator/mariadb-operator \
      --kube-context "$ctx" \
      --namespace db-ops \
      --create-namespace \
      --wait
  done

  # Build aqsh image and push to local registry
  docker build -t localhost:5005/db-runbooks:latest "${ROOT_DIR}"
  docker push localhost:5005/db-runbooks:latest
  kind load docker-image localhost:5005/db-runbooks:latest --name cluster-a
  kind load docker-image localhost:5005/db-runbooks:latest --name cluster-b

  local HELMFILE="${ROOT_DIR}/tests/mariadb/helmfile.yaml"

  # First apply: deploy everything with default (empty) runtime values.
  helmfile apply -f "$HELMFILE"

  [[ -n "${CLUSTER_A_IP:-}" ]] || { echo "CLUSTER_A_IP not set by setup_infra" >&2; return 1; }
  [[ -n "${CLUSTER_B_IP:-}" ]] || { echo "CLUSTER_B_IP not set by setup_infra" >&2; return 1; }

  # Vault must be ready and its AppRole provisioned BEFORE the second apply,
  # since VAULT_ROLE_ID/VAULT_SECRET_ID are injected into both aqsh-mariadb
  # releases' mariadb.env as part of that same runtime-values apply below.
  echo "Waiting for vault..."
  wait_deployment_rollout "$CTX_B" vault vault 120s
  echo "Provisioning Vault AppRole for migration credential relay..."
  ensure_vault_approle "$CTX_B" || return 1

  # Extract runtime credentials from live clusters
  local ISSUER_A ISSUER_B CA_A CA_B TOKEN_A TOKEN_B

  ISSUER_A=$(kubectl --context "$CTX_A" get --raw /.well-known/openid-configuration \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])")
  ISSUER_B=$(kubectl --context "$CTX_B" get --raw /.well-known/openid-configuration \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])")

  CA_A=$(kubectl --context "$CTX_A" config view --raw \
    -o jsonpath="{.clusters[?(@.name==\"kind-cluster-a\")].cluster.certificate-authority-data}" | base64 -d)
  CA_B=$(kubectl --context "$CTX_B" config view --raw \
    -o jsonpath="{.clusters[?(@.name==\"kind-cluster-b\")].cluster.certificate-authority-data}" | base64 -d)

  TOKEN_A=$(kubectl --context "$CTX_A" -n "$NS" create token kube-federated-auth-reader \
    --duration=168h --audience=https://kubernetes.default.svc.cluster.local)
  TOKEN_B=$(kubectl --context "$CTX_B" -n "$NS" create token kube-federated-auth-reader \
    --duration=168h --audience=https://kubernetes.default.svc.cluster.local)

  # Throwaway deployment PGP keypair for the secrets/* task family (shared
  # by both clusters' aqsh releases; callers fetch the public half through
  # the secrets/pubkey task). No gpg on the host → no key; the secrets.bats
  # file skips itself instead of failing the whole suite.
  local PGP_PRIV
  PGP_PRIV=$(provision_ephemeral_pgp_key)

  # Write runtime-discovered values to a temp file. aqsh.config.mariadb.env is
  # a scalar, so this second apply fully REPLACES the MINIO_ENDPOINT-only
  # content helmfile.yaml's first apply set for mariadb-server/mariadb-server-b
  # — it must therefore repeat MINIO_ENDPOINT alongside the runtime-discovered
  # VAULT_* values, not just add to it. Vault is single-instance on cluster-b
  # (like MinIO), so both releases share the same values. aqsh: is a single
  # mapping below (config + pgpKey as siblings) — a second top-level aqsh:
  # key in the same YAML document would silently clobber the first.
  local RUNTIME_VALUES="${ROOT_DIR}/tests/mariadb/runtime-values.yaml"
  cat > "$RUNTIME_VALUES" <<EOF
federatedAuth:
  clusters:
    cluster-a:
      issuer: "${ISSUER_A}"
      apiServer: "https://${CLUSTER_A_IP}:6443"
    cluster-b:
      issuer: "${ISSUER_B}"
      apiServer: "https://${CLUSTER_B_IP}:6443"
  caCerts:
    cluster-a-ca.crt: |
$(echo "$CA_A" | sed 's/^/      /')
    cluster-b-ca.crt: |
$(echo "$CA_B" | sed 's/^/      /')
  tokens:
    cluster-a-token: "${TOKEN_A}"
    cluster-b-token: "${TOKEN_B}"
aqsh:
  config:
    mariadb.env: |
      MINIO_ENDPOINT=http://minio.kind-b.test:30080
      VAULT_ADDR=http://vault.kind-b.test:30080
      VAULT_MOUNT=secret
      VAULT_ROLE_ID=${VAULT_ROLE_ID}
      VAULT_SECRET_ID=${VAULT_SECRET_ID}
EOF
  if [[ -n "$PGP_PRIV" ]]; then
    # Appends as a sibling of `config:` under the same top-level `aqsh:`
    # mapping opened above — a second top-level `aqsh:` key here would be a
    # duplicate YAML key that silently clobbers the block above.
    cat >> "$RUNTIME_VALUES" <<EOF
  pgpKey: |
$(echo "$PGP_PRIV" | sed 's/^/    /')
EOF
  fi

  # Second apply: inject real runtime values.
  helmfile apply -f "$HELMFILE" --values "$RUNTIME_VALUES"
  rm -f "$RUNTIME_VALUES"

  # Wait for deployments on cluster-a
  echo "Waiting for kube-federated-auth..."
  kubectl --context "$CTX_A" -n "$NS" wait \
    --for=condition=Available deployment/kube-federated-auth --timeout=300s

  echo "Waiting for redis (cluster-a)..."
  wait_deployment_rollout "$CTX_A" "$NS" redis 120s

  echo "Waiting for aqsh (cluster-a)..."
  wait_deployment_rollout "$CTX_A" "$NS" aqsh 300s

  echo "Waiting for mariadb (cluster-a)..."
  kubectl --context "$CTX_A" -n mariadb-1 wait \
    --for=condition=Ready mariadb/mariadb --timeout=900s
  kubectl --context "$CTX_A" -n mariadb-2 wait \
    --for=condition=Ready mariadb/mariadb --timeout=900s

  echo "Waiting for namespace-local database gateway..."
  wait_deployment_rollout "$CTX_A" mariadb-1 database-gateway 180s

  echo "Waiting for database gateway test client..."
  wait_deployment_rollout "$CTX_A" mariadb-1 database-gateway-client 120s

  # Wait for deployments on cluster-b
  echo "Waiting for redis (cluster-b)..."
  wait_deployment_rollout "$CTX_B" "$NS" redis 120s

  echo "Waiting for aqsh (cluster-b)..."
  wait_deployment_rollout "$CTX_B" "$NS" aqsh 300s

  echo "Waiting for mariadb (cluster-b)..."
  kubectl --context "$CTX_B" -n mariadb-1 wait \
    --for=condition=Ready mariadb/mariadb --timeout=900s

  echo "Waiting for test-client..."
  wait_deployment_rollout "$CTX_B" "$NS" test-client 120s

  echo "Waiting for minio..."
  wait_deployment_rollout "$CTX_B" minio minio 180s
  ensure_minio_bucket "$CTX_B" db-backups

  echo "=== mariadb test suite setup complete ==="
}

teardown_suite() {
  local ctx_a="kind-cluster-a"
  local ctx_b="kind-cluster-b"

  # Delete database namespaces first — the operator in db-ops processes CR finalizers.
  # Then delete db-ops — no finalizer-bearing CRs remain.
  delete_namespace_and_wait "$ctx_a" mariadb-1 300s || true
  delete_namespace_and_wait "$ctx_a" mariadb-2 300s || true
  delete_namespace_and_wait "$ctx_b" mariadb-1 300s || true
  kubectl --context "$ctx_a" delete ns db-ops --ignore-not-found --wait=false || true
  kubectl --context "$ctx_b" delete ns db-ops minio --ignore-not-found --wait=false || true

  if [[ "${TEARDOWN:-}" == "true" ]]; then
    ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    helmfile destroy -f "${ROOT_DIR}/tests/mariadb/helmfile.yaml" || true
  fi
}
