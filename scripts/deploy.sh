#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

# Deploy shared infrastructure
"${SCRIPT_DIR}/deploy-infra.sh"

# shellcheck source=/dev/null
source "$ENV_FILE"

DB_MODE="${DB_MODE:-single}"
USE_MARIADB_OPERATOR="${USE_MARIADB_OPERATOR:-true}"
CLUSTER_DBS_CONTEXT="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
MONGO_TOPOLOGY="${MONGO_TOPOLOGY:-standalone}"
MARIADB_TOPOLOGY="${MARIADB_TOPOLOGY:-standalone}"

# ---------------------------------------------------------------------------
# _apply_per_pod_nodeports <db> <topology> <context> <namespace>
#   db: "mongodb" or "mariadb"
#   topology: standalone / 2+1 / 1+2 / 3+0
# Applies per-pod NodePort Service yamls that exist for pod-0 (always),
# pod-1 (when topology has ≥2 pods on this cluster), pod-2 (3+0 only).
# ---------------------------------------------------------------------------
_apply_per_pod_nodeports() {
  local db="$1" topology="$2" ctx="$3" ns="$4" members_on_cluster="${5:-}"
  local db_dir="${ROOT_DIR}/k8s/cluster-dbs/${db}"

  if [[ "$topology" == "standalone" ]]; then
    return 0
  fi

  if [[ -z "$members_on_cluster" ]]; then
    if [[ "$topology" == "3+0" ]]; then
      members_on_cluster="3"
    elif [[ "$topology" == *"+"* ]]; then
      members_on_cluster="${topology%%+*}"
    else
      members_on_cluster="1"
    fi
  fi

  # pod-0 is covered by nodeport-service.yaml; per-pod manifests start at pod-1.
  if [[ "$members_on_cluster" -ge 2 && -f "${db_dir}/nodeport-pod1.yaml" ]]; then
    kubectl --context "$ctx" -n "$ns" apply -f "${db_dir}/nodeport-pod1.yaml"
  fi

  if [[ "$members_on_cluster" -ge 3 && -f "${db_dir}/nodeport-pod2.yaml" ]]; then
    kubectl --context "$ctx" -n "$ns" apply -f "${db_dir}/nodeport-pod2.yaml"
  fi
}

_members_for_ctx() {
  local topology="$1" ctx="$2"
  if [[ "$topology" == "standalone" ]]; then
    echo 1
    return 0
  fi
  if [[ "$topology" == "3+0" ]]; then
    echo 3
    return 0
  fi
  if [[ "$topology" != *"+"* ]]; then
    echo 1
    return 0
  fi

  local members_a="${topology%%+*}"
  local members_b="${topology##*+}"
  if [[ "$ctx" == *"-a" ]]; then
    echo "$members_a"
  elif [[ "$ctx" == *"-b" ]]; then
    echo "$members_b"
  else
    echo "$members_a"
  fi
}

# ---------------------------------------------------------------------------
# deploy_mariadb_to_cluster <context> <namespace_list...>
# ---------------------------------------------------------------------------
deploy_mariadb_to_cluster() {
  local ctx="$1"
  shift
  local namespaces=("$@")

  for ns in "${namespaces[@]}"; do
    kubectl --context "$ctx" create ns "$ns" --dry-run=client -o yaml \
      | kubectl --context "$ctx" apply -f -

    kubectl --context "$ctx" -n "$ns" apply -f - <<EOF
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

    local mariadb_tpl="${ROOT_DIR}/k8s/cluster-dbs/mariadb/${ns}-rs.yaml.tpl"
    if [[ "$MARIADB_TOPOLOGY" != "standalone" && -f "$mariadb_tpl" ]]; then
      # Replication mode: always use native StatefulSet with binlog + unique server IDs.
      # Extract the Secret from the operator yaml so we reuse the same password.
      python3 -c "
import sys, re
docs = open('${ROOT_DIR}/k8s/cluster-dbs/mariadb/${ns}.yaml').read().split('\n---\n')
for doc in docs:
    if re.search(r'^kind:\s*Secret', doc, re.MULTILINE):
        print(doc)
" | kubectl --context "$ctx" -n "$ns" apply -f -
      local replica_count base_server_id members_a
      replica_count="$(_members_for_ctx "$MARIADB_TOPOLOGY" "$ctx")"
      members_a="${MARIADB_TOPOLOGY%%+*}"
      if [[ "$ctx" == *"-b" ]]; then
        base_server_id=$(( members_a + 1 ))
      else
        base_server_id=1
      fi
      MARIADB_REPLICAS="$replica_count" MARIADB_BASE_SERVER_ID="$base_server_id" \
        envsubst '${MARIADB_REPLICAS} ${MARIADB_BASE_SERVER_ID}' < "$mariadb_tpl" \
        | kubectl --context "$ctx" apply -f -
    elif [[ "$USE_MARIADB_OPERATOR" == "true" ]]; then
      kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/${ns}.yaml"
    else
      # Native standalone mode: extract Secret, deploy native StatefulSet.
      python3 -c "
import sys, re
docs = open('${ROOT_DIR}/k8s/cluster-dbs/mariadb/${ns}.yaml').read().split('\n---\n')
for doc in docs:
    if re.search(r'^kind:\s*Secret', doc, re.MULTILINE):
        print(doc)
" | kubectl --context "$ctx" -n "$ns" apply -f -
      kubectl --context "$ctx" -n "$ns" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/statefulset.yaml"
    fi

    if [[ "$DB_MODE" == "dual" ]] || [[ "$MARIADB_TOPOLOGY" != "standalone" ]]; then
      local cluster_members
      cluster_members="$(_members_for_ctx "$MARIADB_TOPOLOGY" "$ctx")"
      kubectl --context "$ctx" -n "$ns" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/nodeport-service.yaml"
      _apply_per_pod_nodeports "mariadb" "$MARIADB_TOPOLOGY" "$ctx" "$ns" "$cluster_members"
    fi
  done

  echo "Waiting for MariaDB instances in ${ctx}..."
  for ns in "${namespaces[@]}"; do
    if [[ "$MARIADB_TOPOLOGY" != "standalone" ]]; then
      kubectl --context "$ctx" -n "$ns" wait pod \
        -l app.kubernetes.io/name=mariadb --for=condition=Ready --timeout=180s
    elif [[ "$USE_MARIADB_OPERATOR" == "true" ]]; then
      kubectl --context "$ctx" -n "$ns" wait --for=condition=Ready mariadb/mariadb --timeout=180s
    else
      kubectl --context "$ctx" -n "$ns" wait pod \
        -l app.kubernetes.io/name=mariadb --for=condition=Ready --timeout=180s
    fi
  done
}

# ---------------------------------------------------------------------------
# deploy_mongodb_to_cluster <context> <namespace_list...>
# ---------------------------------------------------------------------------
deploy_mongodb_to_cluster() {
  local ctx="$1"
  shift
  local namespaces=("$@")

  for ns in "${namespaces[@]}"; do
    kubectl --context "$ctx" create ns "$ns" --dry-run=client -o yaml \
      | kubectl --context "$ctx" apply -f -

    kubectl --context "$ctx" -n "$ns" apply -f - <<EOF
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

    if ! kubectl --context "$ctx" -n "$ns" get secret mongodb-credentials &>/dev/null; then
      kubectl --context "$ctx" -n "$ns" create secret generic mongodb-credentials \
        --from-literal="MONGO_ROOT_USER=${ns}-admin" \
        --from-literal="MONGO_ROOT_PASS=$(openssl rand -base64 16 | tr -d '=+/')"
    fi

    local cluster_members
    cluster_members="$(_members_for_ctx "$MONGO_TOPOLOGY" "$ctx")"
    local rs_tpl="${ROOT_DIR}/k8s/cluster-dbs/mongodb/${ns}-rs.yaml.tpl"
    if [[ "$MONGO_TOPOLOGY" != "standalone" && -f "$rs_tpl" ]]; then
      MONGO_REPLICAS="$cluster_members" envsubst < "$rs_tpl" \
        | kubectl --context "$ctx" apply -f -
    else
      kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/${ns}.yaml"
    fi
    if [[ "$DB_MODE" == "dual" ]]; then
      kubectl --context "$ctx" -n "$ns" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/nodeport-service.yaml"
      _apply_per_pod_nodeports "mongodb" "$MONGO_TOPOLOGY" "$ctx" "$ns" "$cluster_members"
    fi
  done

  echo "Waiting for MongoDB instances in ${ctx}..."
  for ns in "${namespaces[@]}"; do
    kubectl --context "$ctx" -n "$ns" rollout status statefulset/mongodb --timeout=180s
  done
}

if [[ "$DB_MODE" == "dual" ]]; then
  echo "=== Deploy MariaDB instances (dual mode) ==="
  deploy_mariadb_to_cluster "kind-cluster-dbs-a" mariadb-1
  deploy_mariadb_to_cluster "kind-cluster-dbs-b" mariadb-1

  echo "=== Deploy MongoDB instances (dual mode) ==="
  deploy_mongodb_to_cluster "kind-cluster-dbs-a" mongo-1
  deploy_mongodb_to_cluster "kind-cluster-dbs-b" mongo-1
else
  echo "=== Deploy MariaDB instances ==="
  deploy_mariadb_to_cluster "$CLUSTER_DBS_CONTEXT" mariadb-1 mariadb-2 mariadb-3

  echo "=== Deploy MongoDB instances ==="
  deploy_mongodb_to_cluster "$CLUSTER_DBS_CONTEXT" mongo-1 mongo-2 mongo-3
fi

echo "=== Deployment complete ==="
