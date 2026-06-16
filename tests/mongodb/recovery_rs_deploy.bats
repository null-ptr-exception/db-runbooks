#!/usr/bin/env bats
# =============================================================================
# Post-deploy integration tests: verify that deploy.sh set up mongo-1/2/3
# correctly as 3-replica replica sets.
#
# Covers:
#   B1  mongo-1/2/3 all have 3 healthy RS members (rs.status())
#   B2  each namespace reports setName="rs0", confirming RS mode not standalone
#   B3  key setup operations are idempotent — safe to re-run deploy.sh
#
# Assumes the cluster is already deployed (scripts/deploy.sh or scripts/setup.sh
# has been run). Does NOT create or delete any namespace.
# Run after deploy: bats tests/mongodb/recovery_rs_deploy.bats
# =============================================================================

setup_file() {
  load '../test_helper/common_setup'
  common_setup

  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"

  # recovery.bats teardown_file deletes mongo-1 after its own tests.
  # Re-deploy it here so B-series tests can verify post-deploy state.
  for ns in mongo-1 mongo-2 mongo-3; do
    if ! kubectl --context "$ctx" get ns "$ns" &>/dev/null; then
      echo "Namespace ${ns} missing (recovery.bats teardown) — re-deploying..."
      deploy_mongodb "$ns" "$ctx"
      kubectl --context "$ctx" -n "$ns" apply \
        -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/recovery-configmap.yaml"
      local replicas img
      replicas=$(kubectl --context "$ctx" -n "$ns" \
        get statefulset mongodb -o jsonpath='{.spec.replicas}')
      img=$(kubectl --context "$ctx" -n "$ns" \
        get statefulset mongodb -o jsonpath='{.spec.template.spec.containers[0].image}')
      kubectl --context "$ctx" -n "$ns" \
        patch statefulset mongodb --type=strategic -p "$(cat <<PATCH
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
PATCH
)"
    fi
  done
}

setup() {
  load '../test_helper/common_setup'
}

# ---------------------------------------------------------------------------
# _rs_member_count <namespace> [context]
# Returns the number of members in rs.status() with health=1.
# ---------------------------------------------------------------------------
_rs_member_count() {
  local ns="$1" ctx="${2:-${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}}"
  kubectl --context "$ctx" -n "$ns" exec mongodb-0 -- \
    mongosh --quiet --norc "mongodb://localhost:27017/admin" \
    --eval "try{print(rs.status().members.filter(function(m){return m.health===1;}).length);}catch(e){print(0);}" \
    2>/dev/null | tail -1 | tr -d '\r'
}

# ---------------------------------------------------------------------------
# _rs_set_name <namespace> [context]
# Returns the RS setName from db.hello(), empty if standalone.
# ---------------------------------------------------------------------------
_rs_set_name() {
  local ns="$1" ctx="${2:-${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}}"
  kubectl --context "$ctx" -n "$ns" exec mongodb-0 -- \
    mongosh --quiet --norc "mongodb://localhost:27017/admin" \
    --eval "try{var h=db.hello();print(h.setName||'');}catch(e){print('');}" \
    2>/dev/null | tail -1 | tr -d '\r'
}

# ── B1: all namespaces have 3 healthy RS members ──────────────────────────────

@test "B1: mongo-1 has 3 healthy RS members after deploy" {
  local count
  count=$(_rs_member_count "mongo-1")
  echo "mongo-1 healthy members: $count" >&2
  [ "$count" -eq 3 ]
}

@test "B1: mongo-2 has 3 healthy RS members after deploy" {
  local count
  count=$(_rs_member_count "mongo-2")
  echo "mongo-2 healthy members: $count" >&2
  [ "$count" -eq 3 ]
}

@test "B1: mongo-3 has 3 healthy RS members after deploy" {
  local count
  count=$(_rs_member_count "mongo-3")
  echo "mongo-3 healthy members: $count" >&2
  [ "$count" -eq 3 ]
}

# ── B2: RS mode confirmed — setName is "rs0", not standalone ─────────────────

@test "B2: mongo-1 runs in RS mode (setName=rs0, not standalone)" {
  local set_name
  set_name=$(_rs_set_name "mongo-1")
  echo "mongo-1 setName: '$set_name'" >&2
  assert_equal "$set_name" "rs0"
}

@test "B2: mongo-2 runs in RS mode (setName=rs0, not standalone)" {
  local set_name
  set_name=$(_rs_set_name "mongo-2")
  echo "mongo-2 setName: '$set_name'" >&2
  assert_equal "$set_name" "rs0"
}

@test "B2: mongo-3 runs in RS mode (setName=rs0, not standalone)" {
  local set_name
  set_name=$(_rs_set_name "mongo-3")
  echo "mongo-3 setName: '$set_name'" >&2
  assert_equal "$set_name" "rs0"
}

# ── B3: idempotency — re-applying setup operations is safe ───────────────────

@test "B3: re-applying recovery ConfigMap to mongo-1 is idempotent (kubectl apply exits 0)" {
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
  kubectl --context "$ctx" -n mongo-1 apply \
    -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/recovery-configmap.yaml"
}

@test "B3: re-applying recovery ConfigMap to mongo-2 is idempotent" {
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
  kubectl --context "$ctx" -n mongo-2 apply \
    -f "${ROOT_DIR}/k8s/cluster-dbs/mongodb/recovery-configmap.yaml"
}

@test "B3: re-applying STS init-container patch to mongo-1 does not duplicate init container" {
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
  local img replicas
  img=$(kubectl --context "$ctx" -n mongo-1 get statefulset mongodb \
    -o jsonpath='{.spec.template.spec.containers[0].image}')
  replicas=$(kubectl --context "$ctx" -n mongo-1 get statefulset mongodb \
    -o jsonpath='{.spec.replicas}')

  kubectl --context "$ctx" -n mongo-1 \
    patch statefulset mongodb --type=strategic -p "$(cat <<PATCH
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
PATCH
)"

  # Strategic merge must not duplicate: count must still be exactly 1
  local ic_count
  ic_count=$(kubectl --context "$ctx" -n mongo-1 get statefulset mongodb \
    -o jsonpath='{.spec.template.spec.initContainers[*].name}' \
    | tr ' ' '\n' | grep -c '^data-recovery$' || true)
  echo "data-recovery init container count: $ic_count" >&2
  [ "$ic_count" -eq 1 ]
}

@test "B3: rs.initiate() on already-initialised RS in mongo-1 does not error" {
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
  local out
  out=$(kubectl --context "$ctx" -n mongo-1 exec mongodb-0 -- \
    mongosh --quiet --norc "mongodb://localhost:27017/admin" \
    --eval "
      try {
        rs.initiate({_id:'rs0',members:[
          {_id:0,host:'mongodb-0.mongodb.mongo-1.svc.cluster.local:27017'},
          {_id:1,host:'mongodb-1.mongodb.mongo-1.svc.cluster.local:27017'},
          {_id:2,host:'mongodb-2.mongodb.mongo-1.svc.cluster.local:27017'}
        ]});
        print('initiated');
      } catch(e) {
        if(e.codeName==='AlreadyInitialized'){print('already_initialized');}
        else{print('error:'+e.message); quit(1);}
      }" 2>/dev/null | tail -1 | tr -d '\r')
  echo "rs.initiate() result: $out" >&2
  [[ "$out" == "already_initialized" || "$out" == "initiated" ]]
}

@test "B3: createUser on existing root user in mongo-2 does not crash deploy" {
  local ctx="${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}"
  local user pass
  user=$(kubectl --context "$ctx" -n mongo-2 get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  pass=$(kubectl --context "$ctx" -n mongo-2 get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)

  local out
  out=$(kubectl --context "$ctx" -n mongo-2 exec mongodb-0 -- \
    mongosh --quiet --norc \
    "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin" \
    --eval "
      try {
        db.getSiblingDB('admin').createUser({
          user:'${user}',pwd:'${pass}',roles:[{role:'root',db:'admin'}]});
        print('created');
      } catch(e) {
        if(/already exists/.test(e.message)){print('exists');} else{throw e;}
      }" 2>/dev/null | tail -1 | tr -d '\r')
  echo "createUser result: $out" >&2
  [[ "$out" == "exists" || "$out" == "created" ]]
}
