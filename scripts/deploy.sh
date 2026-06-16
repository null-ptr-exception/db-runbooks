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

    if [[ "$USE_MARIADB_OPERATOR" == "true" ]]; then
      kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/${ns}.yaml"
    else
      # Native mode: extract only the Secret document (kind: Secret) from the operator
      # yaml so we reuse the same password, then deploy the native StatefulSet.
      python3 -c "
import sys, re
docs = open('${ROOT_DIR}/k8s/cluster-dbs/mariadb/${ns}.yaml').read().split('\n---\n')
for doc in docs:
    if re.search(r'^kind:\s*Secret', doc, re.MULTILINE):
        print(doc)
" | kubectl --context "$ctx" -n "$ns" apply -f -
      kubectl --context "$ctx" -n "$ns" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/statefulset.yaml"
    fi

    if [[ "$DB_MODE" == "dual" ]]; then
      kubectl --context "$ctx" -n "$ns" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mariadb/nodeport-service.yaml"
    fi
  done

  echo "Waiting for MariaDB instances in ${ctx}..."
  for ns in "${namespaces[@]}"; do
    if [[ "$USE_MARIADB_OPERATOR" == "true" ]]; then
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

    kubectl --context "$ctx" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/${ns}.yaml"
    if [[ "$DB_MODE" == "dual" ]]; then
      kubectl --context "$ctx" -n "$ns" apply -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/nodeport-service.yaml"
    fi
  done

  echo "Waiting for MongoDB instances in ${ctx}..."
  for ns in "${namespaces[@]}"; do
    kubectl --context "$ctx" -n "$ns" rollout status statefulset/mongodb --timeout=180s
  done

  echo "Initialising MongoDB replica sets in ${ctx}..."
  for ns in "${namespaces[@]}"; do
    local replicas
    replicas=$(kubectl --context "$ctx" -n "$ns" get statefulset mongodb \
      -o jsonpath='{.spec.replicas}')
    if [[ -z "$replicas" ]] || ! [[ "$replicas" =~ ^[0-9]+$ ]]; then
      echo "  [$ns] ERROR: could not read valid replica count from StatefulSet mongodb" >&2
      return 1
    fi

    local rs_init_js
    rs_init_js=$(cat <<RSJS
var cfg={_id:'rs0',members:[]};
for(var i=0;i<${replicas};i++){
  cfg.members.push({_id:i,host:'mongodb-'+i+'.mongodb.${ns}.svc.cluster.local:27017',priority:(i===0?2:1)});
}
try{
  var r=rs.initiate(cfg);
  if(r.ok||r.code===23){print('RS_OK');}
  else{print('RS_ERR:'+JSON.stringify(r));}
}catch(e){
  if(e.message&&e.message.indexOf('already initialized')>=0){print('RS_ALREADY');}
  else{throw e;}
}
RSJS
)
    local rs_init_out
    rs_init_out=$(kubectl --context "$ctx" -n "$ns" exec mongodb-0 -- \
      mongosh --quiet --norc --eval "$rs_init_js")
    if echo "$rs_init_out" | grep -q '^RS_ERR'; then
      echo "  [$ns] ERROR: RS initiate failed: $rs_init_out" >&2
      return 1
    fi

    # Wait for primary election (up to 120s)
    echo "  [$ns] Waiting for RS primary..."
    local elapsed=0
    until kubectl --context "$ctx" -n "$ns" exec mongodb-0 -- \
        mongosh --quiet --norc --eval \
          "try{var h=db.hello();print(h.isWritablePrimary?'PRIMARY':'WAITING');}catch(e){print('WAITING');}" \
        2>/dev/null | grep -q PRIMARY; do
      if [[ "$elapsed" -ge 120 ]]; then
        echo "  [$ns] WARNING: RS primary not elected after 120s" >&2
        break
      fi
      sleep 5
      elapsed=$((elapsed + 5))
    done

    # Create root user from secret (idempotent — ignore "already exists")
    local root_user root_pass
    root_user=$(kubectl --context "$ctx" -n "$ns" get secret mongodb-credentials \
      -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
    root_pass=$(kubectl --context "$ctx" -n "$ns" get secret mongodb-credentials \
      -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)

    kubectl --context "$ctx" -n "$ns" exec mongodb-0 -- \
      mongosh --quiet --norc --eval "
try {
  db.getSiblingDB('admin').createUser({
    user: '${root_user}',
    pwd: '${root_pass}',
    roles: [{role:'root',db:'admin'}]
  });
  print('USER_CREATED');
} catch(e) {
  if(e.code===51003||e.message.indexOf('already exists')>=0){print('USER_EXISTS');}
  else{throw e;}
}"
  done

  echo "Applying MongoDB recovery prerequisites in ${ctx}..."
  for ns in "${namespaces[@]}"; do
    kubectl --context "$ctx" -n "$ns" apply \
      -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/recovery-configmap.yaml"

    local img replicas
    img=$(kubectl --context "$ctx" -n "$ns" get statefulset mongodb \
      -o jsonpath='{.spec.template.spec.containers[0].image}')
    replicas=$(kubectl --context "$ctx" -n "$ns" get statefulset mongodb \
      -o jsonpath='{.spec.replicas}')
    if [[ -z "$replicas" ]] || ! [[ "$replicas" =~ ^[0-9]+$ ]]; then
      echo "  [$ns] ERROR: could not read valid replica count for recovery patch" >&2
      return 1
    fi
    kubectl --context "$ctx" -n "$ns" \
      patch statefulset mongodb --type=strategic -p "$(cat <<RECOVERY_PATCH
{
  "spec": {
    "updateStrategy": {"rollingUpdate": {"partition": ${replicas}}},
    "template": {
      "spec": {
        "initContainers": [{
          "name": "data-recovery",
          "image": "${img}",
          "command": ["/bin/bash", "-c"],
          "args": ["WIPE_TARGETS=\$(cat /recovery-config/wipe-targets 2>/dev/null || echo ''); MY_NAME=\$(hostname); if [ -n \"\$WIPE_TARGETS\" ] && echo \"\$WIPE_TARGETS\" | grep -qw \"\$MY_NAME\"; then echo '[RECOVERY] Wiping data for '\$MY_NAME; find /data/db -mindepth 1 -delete 2>/dev/null || true; echo '[RECOVERY] Wipe complete.'; else echo '[RECOVERY] '\$MY_NAME' not in wipe targets, skip.'; fi"],
          "volumeMounts": [
            {"name": "data", "mountPath": "/data/db"},
            {"name": "recovery-config-vol", "mountPath": "/recovery-config", "readOnly": true}
          ],
          "securityContext": {"runAsUser": 999, "runAsNonRoot": true}
        }],
        "volumes": [{"name": "recovery-config-vol", "configMap": {"name": "mongodb-recovery-config"}}]
      }
    }
  }
}
RECOVERY_PATCH
)"
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
