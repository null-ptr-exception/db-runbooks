#!/usr/bin/env bats

load helpers.bash

setup() {
  setup_env
  require_multi_mode
}

expected_members() {
  local ns="$1"
  if [ "${MONGO_REPLICATION_MODE}" = "3+1" ] && [ "$ns" != "mongo-1" ]; then
    echo 1
  else
    echo 2
  fi
}

@test "mongodb replica set members match MONGO_REPLICATION_MODE" {
  for ns in mongo-1 mongo-2 mongo-3; do
    run bash -ceu '
      NS="$1"
      ROOT_USER=$(kubectl --context kind-cluster-region-a -n "$NS" get secret mongodb-credentials -o jsonpath="{.data.MONGO_ROOT_USER}" | base64 -d)
      ROOT_PASS=$(kubectl --context kind-cluster-region-a -n "$NS" get secret mongodb-credentials -o jsonpath="{.data.MONGO_ROOT_PASS}" | base64 -d)
      kubectl --context kind-cluster-region-a -n "$NS" exec mongodb-0 -- mongosh --quiet --norc -u "$ROOT_USER" -p "$ROOT_PASS" --authenticationDatabase admin --eval "rs.status().members.length"
    ' _ "$ns"
    assert_success
    [ "$output" -eq "$(expected_members "$ns")" ]
  done
}

@test "mongodb primary stays in region-a and region-b secondary exists for enabled sets" {
  for pair in "mongo-1:30092" "mongo-2:30094" "mongo-3:30096"; do
    ns="${pair%%:*}"
    port="${pair##*:}"

    run bash -ceu '
      NS="$1"; PORT="$2"
      ROOT_USER=$(kubectl --context kind-cluster-region-a -n "$NS" get secret mongodb-credentials -o jsonpath="{.data.MONGO_ROOT_USER}" | base64 -d)
      ROOT_PASS=$(kubectl --context kind-cluster-region-a -n "$NS" get secret mongodb-credentials -o jsonpath="{.data.MONGO_ROOT_PASS}" | base64 -d)
      kubectl --context kind-cluster-region-a -n "$NS" exec mongodb-0 -- mongosh --quiet --norc -u "$ROOT_USER" -p "$ROOT_PASS" --authenticationDatabase admin --eval "rs.status().members.filter((m) => m.stateStr === \"PRIMARY\")[0].name"
    ' _ "$ns" "$port"
    assert_success
    assert_output --partial "${REGION_A_IP}:${port}"

    if [ "${MONGO_REPLICATION_MODE}" = "3+1" ] && [ "$ns" != "mongo-1" ]; then
      continue
    fi

    run bash -ceu '
      NS="$1"; PORT="$2"; REMOTE_IP="$3"
      ROOT_USER=$(kubectl --context kind-cluster-region-a -n "$NS" get secret mongodb-credentials -o jsonpath="{.data.MONGO_ROOT_USER}" | base64 -d)
      ROOT_PASS=$(kubectl --context kind-cluster-region-a -n "$NS" get secret mongodb-credentials -o jsonpath="{.data.MONGO_ROOT_PASS}" | base64 -d)
      kubectl --context kind-cluster-region-a -n "$NS" exec mongodb-0 -- mongosh --quiet --norc -u "$ROOT_USER" -p "$ROOT_PASS" --authenticationDatabase admin --eval "rs.status().members.filter((m) => m.name === \"${REMOTE_IP}:${PORT}\")[0].stateStr"
    ' _ "$ns" "$port" "$REGION_B_IP"
    assert_success
    assert_output "SECONDARY"
  done
}

@test "mongodb write on region-a primary can be read from region-b secondary" {
  run bash -ceu '
    ROOT_USER=$(kubectl --context kind-cluster-region-a -n mongo-1 get secret mongodb-credentials -o jsonpath="{.data.MONGO_ROOT_USER}" | base64 -d)
    ROOT_PASS=$(kubectl --context kind-cluster-region-a -n mongo-1 get secret mongodb-credentials -o jsonpath="{.data.MONGO_ROOT_PASS}" | base64 -d)
    kubectl --context kind-cluster-region-a -n mongo-1 exec mongodb-0 -- mongosh --quiet --norc -u "$ROOT_USER" -p "$ROOT_PASS" --authenticationDatabase admin --eval "db=db.getSiblingDB('cross_region_test'); db.replication_probe.updateOne({_id:1},{\$set:{note:'ok'}},{upsert:true});"
  '
  assert_success

  run wait_for_replication '
    ROOT_USER=$(kubectl --context kind-cluster-region-b -n mongo-1 get secret mongodb-credentials -o jsonpath="{.data.MONGO_ROOT_USER}" | base64 -d)
    ROOT_PASS=$(kubectl --context kind-cluster-region-b -n mongo-1 get secret mongodb-credentials -o jsonpath="{.data.MONGO_ROOT_PASS}" | base64 -d)
    VALUE=$(kubectl --context kind-cluster-region-b -n mongo-1 exec mongodb-0 -- mongosh --quiet --norc -u "$ROOT_USER" -p "$ROOT_PASS" --authenticationDatabase admin --eval "db.getSiblingDB(\"cross_region_test\").getMongo().setReadPref(\"secondary\"); doc=db.getSiblingDB(\"cross_region_test\").replication_probe.findOne({_id:1}); doc ? doc.note : \"\"" | tr -d "\\r")
    [ "$VALUE" = "ok" ]
  '
  assert_success
}
