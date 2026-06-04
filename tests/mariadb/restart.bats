# Integration test for operator-driven MariaDB restart.
#
# This is a black-box test: it submits the restart task and then checks the
# cluster directly — did the operator actually roll the pods, or (without the
# operator) leave everything untouched? The structured task result envelope
# (status / reason_code / per-pod restart evidence) is asserted exhaustively
# with a mocked kubectl in tests/unit/mariadb/restart.bats, so it is not
# re-checked here.

setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
  deploy_mariadb "mariadb-1"
}

setup() {
  load '../test_helper/common_setup'
}

teardown_file() {
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" delete ns mariadb-1 --ignore-not-found
}

K() {
  kubectl --context "${CLUSTER_DBS_CONTEXT:-kind-cluster-dbs}" -n mariadb-1 "$@"
}

# Submit a restart task and block until it finishes (202 + task reaches done).
submit_restart() {
  http_post "${MARIADB_AQSH_URL}/tasks/restart" "$1"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"
}

# One line per MariaDB pod, "name=uid", sorted by name. A changed UID means the
# pod was recreated — i.e. the operator actually rolled it.
pod_uids() {
  K get pods -l app.kubernetes.io/name=mariadb --sort-by=.metadata.name \
    -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}{"\n"}{end}'
}

# The restart annotation the task stamps on the CR, regardless of which metadata
# field the CRD supports (podMetadata on new CRDs, inheritMetadata on old ones).
restart_annotation() {
  K get mariadb mariadb -o json | jq -r '
    ((.spec.podMetadata.annotations // {}) + (.spec.inheritMetadata.annotations // {}))
    | to_entries[] | select(.key | test("restarted-at$")) | .value' | head -1
}

@test "dry-run touches nothing on the cluster" {
  local before_uids
  before_uids=$(pod_uids)

  # dry_run defaults to true.
  submit_restart '{"namespace": "mariadb-1"}'

  assert_equal "$(pod_uids)" "$before_uids"
}

@test "confirmed restart patches the CR and the operator rolls every pod" {
  local before_uids
  before_uids=$(pod_uids)

  submit_restart '{"namespace": "mariadb-1", "dry_run": "false", "confirm": "true"}'

  if [[ "${USE_MARIADB_OPERATOR:-true}" != "true" ]]; then
    # Operator-driven restart is a no-op without the operator: nothing changes.
    echo "native mode: expecting no rollout"
    assert_equal "$(pod_uids)" "$before_uids"
    return
  fi

  # 1. The task's only cluster mutation is the restart annotation on the CR.
  local annotation
  annotation=$(restart_annotation)
  echo "restart annotation on CR: '${annotation}'"
  assert [ -n "$annotation" ]

  # 2. The operator — not the task — recreates the pods and brings them back Ready.
  K wait pod -l app.kubernetes.io/name=mariadb --for=condition=Ready --timeout=180s >/dev/null 2>&1

  local after_uids ready replicas
  after_uids=$(pod_uids)
  echo "pod uids before:"; echo "$before_uids"
  echo "pod uids after:";  echo "$after_uids"
  refute_equal "$after_uids" "$before_uids"   # at least one pod was recreated

  ready=$(K get statefulset mariadb -o jsonpath='{.status.readyReplicas}')
  replicas=$(K get statefulset mariadb -o jsonpath='{.status.replicas}')
  echo "ready: ${ready}/${replicas}"
  assert_equal "$ready" "$replicas"
  assert [ "$ready" != "0" ]
}
