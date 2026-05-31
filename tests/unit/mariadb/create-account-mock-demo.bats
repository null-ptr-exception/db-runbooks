#!/usr/bin/env bats
#
# Demonstration of bats-mock + bats-assert for create-account.sh unit tests.
# These tests cover error paths that the hand-rolled mock doesn't reach.
#
# bats-mock matches arguments POSITIONALLY — each * matches exactly one arg.
# kubectl calls include --context/--namespace flags, so patterns must account
# for the exact argument count.

setup() {
  load '../../test_helper/bats-support/load'
  load '../../test_helper/bats-assert/load'
  load '../../test_helper/bats-mock/stub'

  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mariadb/create-account.sh"
  export _LOG_CURRENT_LEVEL=3
}

teardown() {
  unstub kubectl || true
}

# -- Arg patterns for _kubectl_global (no --namespace) -------------------------
# _kubectl_global cluster-info --request-timeout=5s
# → kubectl --context kind-cluster-dbs cluster-info --request-timeout=5s
CLUSTER_INFO="* * cluster-info *"

# -- Arg patterns for _kubectl (with --namespace) -----------------------------
# _kubectl get mariadb mariadb -o jsonpath={...}
# → kubectl --context X --namespace Y get mariadb mariadb -o jsonpath={...}
GET_MDB="* * * * get mariadb mariadb * *"

# _kubectl get statefulset mariadb -o jsonpath={...}
# → kubectl --context X --namespace Y get statefulset mariadb -o jsonpath={...}
GET_STS="* * * * get statefulset mariadb * *"

# _kubectl exec mariadb-0 -c mariadb -- printenv MARIADB_ROOT_PASSWORD
# → kubectl --context X --namespace Y exec mariadb-0 -c mariadb -- printenv MARIADB_ROOT_PASSWORD
EXEC_PRINTENV="* * * * exec mariadb-0 -c mariadb -- printenv MARIADB_ROOT_PASSWORD"

# _kubectl exec mariadb-0 -c mariadb -- mariadb -u root -pPASS -N -B -e SQL
# → kubectl --context X --namespace Y exec mariadb-0 -c mariadb -- mariadb -u root -pPASS -N -B -e SQL
EXEC_SQL="* * * * exec mariadb-0 -c mariadb -- mariadb * * * * * *"

# _kubectl apply -f -
# → kubectl --context X --namespace Y apply -f -
APPLY="* * * * apply -f -"

# -- Helpers -------------------------------------------------------------------

_common_args() {
  echo "--context kind-cluster-dbs \
    --namespace mariadb-2 \
    --database app_db \
    --username app_user \
    --privileges SELECT \
    --password-secret-name mariadb-account-app-user-password \
    --dry-run false \
    --confirm true \
    --json"
}

assert_json() {
  local field="$1" expected="$2"
  local actual
  actual=$(echo "$output" | jq -r "$field")
  assert_equal "$actual" "$expected"
}

# ---------------------------------------------------------------------------
# Test: KUBECTL_UNAVAILABLE
# ---------------------------------------------------------------------------
@test "KUBECTL_UNAVAILABLE when cluster-info fails" {
  stub kubectl \
    "${CLUSTER_INFO} : echo 'connection refused' >&2; exit 1"

  run $SCRIPT $(_common_args)

  assert_success
  assert_json '.status' 'ERROR'
  assert_json '.reason_code' 'KUBECTL_UNAVAILABLE'
}

# ---------------------------------------------------------------------------
# Test: CURRENT_PRIMARY_EMPTY
# ---------------------------------------------------------------------------
@test "CURRENT_PRIMARY_EMPTY when no primary can be determined" {
  stub kubectl \
    "${CLUSTER_INFO} : echo 'Kubernetes control plane is running'" \
    "${GET_MDB} : printf ''" \
    "${GET_MDB} : printf ''" \
    "${GET_STS} : printf '0'"

  run $SCRIPT $(_common_args)

  assert_success
  assert_json '.status' 'ERROR'
  assert_json '.reason_code' 'CURRENT_PRIMARY_EMPTY'
}

# ---------------------------------------------------------------------------
# Test: ROOT_PASSWORD_UNAVAILABLE
# ---------------------------------------------------------------------------
@test "ROOT_PASSWORD_UNAVAILABLE when password cannot be read" {
  stub kubectl \
    "${CLUSTER_INFO} : echo 'Kubernetes control plane is running'" \
    "${GET_MDB} : printf 'mariadb-0'" \
    "${GET_MDB} : printf '1'" \
    "${EXEC_PRINTENV} : exit 1" \
    "${EXEC_PRINTENV} : exit 1"

  run $SCRIPT $(_common_args)

  assert_success
  assert_json '.status' 'ERROR'
  assert_json '.reason_code' 'ROOT_PASSWORD_UNAVAILABLE'
}

# ---------------------------------------------------------------------------
# Test: PASSWORD_SECRET_WRITE_FAILED
# Call sequence: cluster-info, get CR (primary), get CR (replicas),
#   exec printenv, exec SELECT COUNT(*), apply (fail)
# ---------------------------------------------------------------------------
@test "PASSWORD_SECRET_WRITE_FAILED when kubectl apply fails" {
  stub kubectl \
    "${CLUSTER_INFO} : echo 'Kubernetes control plane is running'" \
    "${GET_MDB} : printf 'mariadb-0'" \
    "${GET_MDB} : printf '1'" \
    "${EXEC_PRINTENV} : printf 'root-pass'" \
    "${EXEC_SQL} : printf '0'" \
    "${APPLY} : exit 1"

  run $SCRIPT $(_common_args)

  assert_success
  assert_json '.status' 'ERROR'
  assert_json '.reason_code' 'PASSWORD_SECRET_WRITE_FAILED'
}

# ---------------------------------------------------------------------------
# Test: SQL_VERIFY_FAILED
# Call sequence: cluster-info, get CR x2, exec printenv,
#   exec SELECT COUNT, apply, exec CREATE, exec GRANT, exec SHOW GRANTS (fail)
# ---------------------------------------------------------------------------
@test "SQL_VERIFY_FAILED when SHOW GRANTS fails after successful create" {
  stub kubectl \
    "${CLUSTER_INFO} : echo 'Kubernetes control plane is running'" \
    "${GET_MDB} : printf 'mariadb-0'" \
    "${GET_MDB} : printf '1'" \
    "${EXEC_PRINTENV} : printf 'root-pass'" \
    "${EXEC_SQL} : printf '0'" \
    "${APPLY} : cat >/dev/null" \
    "${EXEC_SQL} : echo ok" \
    "${EXEC_SQL} : echo ok" \
    "${EXEC_SQL} : echo 'access denied' >&2; exit 1"

  run $SCRIPT $(_common_args)

  assert_success
  assert_json '.status' 'ERROR'
  assert_json '.reason_code' 'SQL_VERIFY_FAILED'
}
