#!/usr/bin/env bats
#
# End-to-end coverage for the full cross-cluster migration chain:
#   migration/preflight -> migration/sourcedb-backup -> migration/export-db-env-to-vault
#   (source, cluster-a) -> migration/import-db-env-from-vault -> migration/check-connection
#   -> migration/restore -> migration/setup-replication (target, cluster-b)
#
# import-db-env-from-vault, check-connection, and restore run in this order
# (not backup-then-restore-then-vault) per docs/mariadb/migration.md's chain:
# the relayed secret needs to exist before restore so restore can point
# root_secret_name/root_secret_key at it (the operator's Ready-probe
# authenticates the physically-restored DB using that Secret), and
# check-connection gates the restore rather than being an afterthought right
# before setup-replication.
#
# Unlike migration_restore.bats / migration_sourcedb_backup.bats (which exercise
# backup+restore within a single cluster), this file proves the two genuinely
# NEW cross-cluster pieces work together against two independent aqsh
# deployments: the Vault credential relay (write on cluster-a's aqsh, read back
# on cluster-b's aqsh) and setup-replication consuming the relayed secret.
#
# check-connection and setup-replication both exercise a REAL cross-cluster
# connection to the source, via a TCP passthrough this file wires up itself:
# infra/shared/templates/gateway.yaml opens port 3306 on the shared Istio
# ingressgateway (mapped to nodePort 30091 on both clusters, per
# infra/helmfile-infra.yaml), and setup_file() below applies a VirtualService
# routing that port, on cluster-a, to this run's throwaway source instance.
# Raw MySQL wire protocol has no SNI/Host equivalent, so that port can only
# ever route to ONE destination at a time — the VirtualService's lifecycle is
# scoped to this test (created in setup_file, deleted in teardown_file)
# rather than being permanent shared infra, to keep that constraint from
# becoming a footgun between runs. The external address is
# mariadb.kind-a.test:30091 (CoreDNS already resolves *.kind-a.test to
# cluster-a's node), NOT the internal mariadb.<ns>.svc.cluster.local:3306,
# which cluster-b can't resolve or route to at all.
#
# setup-replication runs for real (dry_run=false), replicating as a
# dedicated 'repl' account this file provisions directly via kubectl exec
# (create-account.sh can't grant REPLICATION SLAVE — see setup_file below).
#
# Gated behind DB_MODE=dual (needs MARIADB_AQSH_B_URL exported — cluster-b's
# own aqsh, separate from cluster-a's) and ENABLE_MINIO=true (needs a real
# MinIO + Vault reachable from both sides), same convention as the
# ENABLE_MINIO-gated real-backup tests in migration_sourcedb_backup.bats /
# migration_restore.bats.

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
  load 'setup_suite'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="db-ops"
  MARIADB_AQSH_URL="http://aqsh-mariadb.kind-a.test:30080"
  SRC_NS="mariadb-e2e-src"
  DST_NS="mariadb-e2e-dst"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=30m)

  export CTX_A CTX_B NS MARIADB_AQSH_URL SRC_NS DST_NS TEST_POD TOKEN

  if [[ "${DB_MODE:-single}" == "dual" && "${ENABLE_MINIO:-false}" == "true" ]]; then
    # Distinct server_ids (non-colliding mod 10, matching check-connection.sh's
    # own SERVER_ID_COLLISION_MODULUS) — mariadb-operator otherwise assigns
    # the same default (e.g. 1) to any single-replica instance regardless of
    # namespace/cluster, which migration/check-connection correctly BLOCKs on.
    # Source instance on cluster-a: this is what gets backed up and read from.
    deploy_throwaway_mariadb "$SRC_NS" "$CTX_A" "101" || return 1
    # Destination namespace on cluster-b, with its own throwaway "mariadb" CR
    # so migration/restore can auto-detect image/storage_size the same way it
    # would for any migration into a namespace that isn't brand new.
    deploy_throwaway_mariadb "$DST_NS" "$CTX_B" "202" || return 1

    # Test-scoped TCP passthrough: routes the shared gateway's port 3306
    # (nodePort 30091, see infra/shared/templates/gateway.yaml) to this
    # run's source instance. Namespace-scoped, so deleting SRC_NS in
    # teardown_file also removes it; deleted explicitly first below for
    # faster feedback if namespace teardown is slow.
    kubectl --context "$CTX_A" -n "$SRC_NS" apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: migration-e2e-source-mariadb
  namespace: ${SRC_NS}
spec:
  hosts:
    - "*"
  gateways:
    - istio-ingress/shared-gateway
  tcp:
    - match:
        - port: 3306
      route:
        - destination:
            host: mariadb.${SRC_NS}.svc.cluster.local
            port:
              number: 3306
EOF

    # Dedicated replication account on the source. create-account.sh can't
    # grant this (its allowed-privilege list is schema-scoped DML/DDL plus a
    # handful of admin ones — REPLICATION SLAVE isn't in it, and replication
    # needs a global ON *.* grant that task doesn't support anyway), so this
    # is direct kubectl exec test-fixture setup, same as
    # deploy_throwaway_mariadb's own raw-kubectl-apply approach.
    kubectl --context "$CTX_A" -n "$SRC_NS" exec mariadb-0 -- \
      mariadb -u root -pmariadb-test-pass -e \
      "CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY 'repl-test-pass'; GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%'; FLUSH PRIVILEGES;" \
      || return 1

    kubectl --context "$CTX_A" -n "$SRC_NS" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mariadb-account-repl
  namespace: ${SRC_NS}
stringData:
  password: repl-test-pass
EOF
  fi
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

teardown_file() {
  load 'setup_suite'
  if [[ "${DB_MODE:-single}" == "dual" && "${ENABLE_MINIO:-false}" == "true" ]]; then
    kubectl --context "kind-cluster-a" -n "mariadb-e2e-src" \
      delete virtualservice migration-e2e-source-mariadb --ignore-not-found >/dev/null 2>&1 || true
    delete_namespace_and_wait "kind-cluster-a" "mariadb-e2e-src" || true
    delete_namespace_and_wait "kind-cluster-b" "mariadb-e2e-dst" || true
  fi
}

kexec() {
  kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"
}

http_post() {
  local url="$1" body="$2"
  local response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\\n%{http_code}' \
    -X POST '${url}' -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Content-Type: application/json' -d '${body}'")
  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-540}"
  local elapsed=0 status
  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE
    status=$(echo "$TASK_RESPONSE" | jq -r '.status' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && { echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2; return 1; }
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

_result_data() {
  echo "$TASK_RESPONSE" | jq -r \
    '(.result.data as $d | (($d | try fromjson catch null) // (if ($d | type) == "object" then $d else null end)))'
}

@test "full cross-cluster migration chain: preflight -> backup -> vault relay -> import-vault -> check-connection -> restore -> setup-replication" {
  if [[ "${DB_MODE:-single}" != "dual" ]]; then
    skip "DB_MODE is not dual"
  fi
  if [[ "${ENABLE_MINIO:-false}" != "true" ]]; then
    skip "MinIO not enabled (ENABLE_MINIO!=true)"
  fi
  [[ -n "${MARIADB_AQSH_B_URL:-}" ]] || skip "MARIADB_AQSH_B_URL is not set"

  local minio_endpoint="http://minio.kind-b.test:30080"
  local minio_access_key="minioadmin"
  local minio_secret_key="minioadmin-changeme-prod"
  local vault_path="migration/e2e-${BATS_TEST_NUMBER}-$$/source"
  local secret_name="migration-e2e-source-creds"
  # External, cross-cluster-reachable address (see file header) — NOT the
  # internal mariadb.<ns>.svc.cluster.local:3306, which cluster-b can't
  # resolve or route to.
  local source_host="mariadb.kind-a.test"
  local source_port="30091"

  # --- Step 1: preflight the source (cluster-a) ---------------------------
  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fpreflight" \
    "$(jq -nc --arg ns "$SRC_NS" '{namespace: $ns}')"
  assert_equal "$HTTP_CODE" "202"
  wait_for_task "$MARIADB_AQSH_URL" "$(echo "$HTTP_BODY" | jq -r '.id')"

  # --- Step 2: back up the source to the shared MinIO bucket (cluster-a) --
  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fsourcedb-backup" \
    "$(jq -nc \
      --arg ns "$SRC_NS" --arg ep "$minio_endpoint" \
      --arg ak "$minio_access_key" --arg sk "$minio_secret_key" \
      '{namespace: $ns, minio_endpoint: $ep, minio_access_key: $ak,
        minio_secret_key: $sk, minio_bucket: "db-backups",
        dry_run: "false", confirm: "true", wait_timeout: "10m"}')"
  assert_equal "$HTTP_CODE" "202"
  wait_for_task "$MARIADB_AQSH_URL" "$(echo "$HTTP_BODY" | jq -r '.id')"

  local backup_data backup_file
  backup_data="$(_result_data)"
  backup_file=$(echo "$backup_data" | jq -r '.data.backup.prefix + "/" + .data.backupName')
  echo "backup_file: ${backup_file}" >&2
  [[ -n "$backup_file" && "$backup_file" != "null/null" ]]

  # --- Step 3: relay the source root password AND the repl account's
  #     password through Vault, in one call (cluster-a) ---------------------
  http_post "${MARIADB_AQSH_URL}/tasks/migration%2Fexport-db-env-to-vault" \
    "$(jq -nc --arg ns "$SRC_NS" --arg vp "$vault_path" '{
      namespace: $ns, mdb: "mariadb",
      envs: "MARIADB_ROOT_PASSWORD=root_password",
      secret_name: "mariadb-account-repl",
      secret_keys: "password=repl_password",
      vault_path: $vp
    }')"
  assert_equal "$HTTP_CODE" "202"
  wait_for_task "$MARIADB_AQSH_URL" "$(echo "$HTTP_BODY" | jq -r '.id')"

  local write_data
  write_data="$(_result_data)"
  assert_equal "$(echo "$write_data" | jq -r '.vault.path // empty')" "$vault_path"
  # The relayed value must never appear in the task response.
  run echo "$TASK_RESPONSE"
  refute_output --partial "mariadb-test-pass"

  # --- Step 4: pull both relayed passwords out of Vault, into a target-side
  #     Secret (cluster-b) — before restore, per docs/mariadb/migration.md,
  #     so restore can point root_secret_name/root_secret_key at it. Root's
  #     password lands under Secret key "password" (serves check-connection
  #     and restore); repl's lands under "repl_password" (serves
  #     setup-replication, step 7). --------------------------------------
  http_post "${MARIADB_AQSH_B_URL}/tasks/migration%2Fimport-db-env-from-vault" \
    "$(jq -nc --arg ns "$DST_NS" --arg vp "$vault_path" --arg sn "$secret_name" '{
      namespace: $ns, vault_path: $vp, secret_name: $sn,
      keys: "root_password=password,repl_password=repl_password"
    }')"
  assert_equal "$HTTP_CODE" "202"
  wait_for_task "$MARIADB_AQSH_B_URL" "$(echo "$HTTP_BODY" | jq -r '.id')"

  local read_data
  read_data="$(_result_data)"
  echo "import-db-env-from-vault result: ${read_data}" >&2
  assert_equal "$(echo "$read_data" | jq -r '.secret.name // empty')" "$secret_name"
  # The relayed value must never appear in the task response here either.
  run echo "$TASK_RESPONSE"
  refute_output --partial "mariadb-test-pass"

  # The Secret materialized on cluster-b must carry the SAME password the
  # source pod actually has (deploy_throwaway_mariadb's fixed root password) —
  # proving the write (cluster-a) -> read (cluster-b) round trip through Vault
  # delivered the correct value, not just A value.
  local relayed_password
  relayed_password=$(kubectl --context "$CTX_B" -n "$DST_NS" \
    get secret "$secret_name" -o jsonpath='{.data.password}' | base64 -d)
  assert_equal "$relayed_password" "mariadb-test-pass"

  # --- Step 5: confirm the target (the placeholder instance
  #     deploy_throwaway_mariadb set up in DST_NS) can reach and
  #     authenticate to the source, using the relayed secret — gates the
  #     restore below, same as docs/mariadb/migration.md step 5. -----------
  http_post "${MARIADB_AQSH_B_URL}/tasks/migration%2Fcheck-connection" \
    "$(jq -nc --arg ns "$DST_NS" --arg ip "$source_host" --arg port "$source_port" --arg sn "$secret_name" '{
      namespace: $ns, ip: $ip, port: $port,
      repl_password_secret: $sn, repl_password_key: "password"
    }')"
  assert_equal "$HTTP_CODE" "202"
  wait_for_task "$MARIADB_AQSH_B_URL" "$(echo "$HTTP_BODY" | jq -r '.id')"

  local check_data
  check_data="$(_result_data)"
  echo "check-connection result: ${check_data}" >&2
  assert_equal "$(echo "$check_data" | jq -r '.status // empty')" "PASS"

  # --- Step 6: restore into the target namespace (cluster-b), pointing
  #     rootPasswordSecretKeyRef at the relayed secret so the restored CR's
  #     root-password Secret matches the physically-restored data. ---------
  http_post "${MARIADB_AQSH_B_URL}/tasks/migration%2Frestore" \
    "$(jq -nc \
      --arg ns "$DST_NS" --arg bf "$backup_file" --arg ep "$minio_endpoint" \
      --arg ak "$minio_access_key" --arg sk "$minio_secret_key" \
      --arg sn "$secret_name" \
      '{namespace: $ns, backup_file: $bf, minio_endpoint: $ep,
        minio_access_key: $ak, minio_secret_key: $sk, minio_bucket: "db-backups",
        root_secret_name: $sn, root_secret_key: "password",
        dry_run: "false", confirm: "true", wait_timeout: "10m"}')"
  assert_equal "$HTTP_CODE" "202"
  wait_for_task "$MARIADB_AQSH_B_URL" "$(echo "$HTTP_BODY" | jq -r '.id')" 960

  local restore_data restored restore_target
  restore_data="$(_result_data)"
  echo "restore result: ${restore_data}" >&2
  restored=$(echo "$restore_data" | jq -r '.data.restored')
  restore_target=$(echo "$restore_data" | jq -r '.data.target')
  assert_equal "$restored" "true"
  [[ -n "$restore_target" && "$restore_target" != "null" ]]
  export RESTORE_TARGET="$restore_target"

  # --- Step 7: point the restored target at the source as its replication
  #     master, for real — using the dedicated repl account (repl_password_
  #     secret's "repl_password" key, from step 4), not root's. -------------
  http_post "${MARIADB_AQSH_B_URL}/tasks/migration%2Fsetup-replication" \
    "$(jq -nc --arg ns "$DST_NS" --arg mdb "$restore_target" --arg sn "$secret_name" \
      --arg host "$source_host" --arg port "$source_port" '{
      namespace: $ns, mdb: $mdb,
      host: $host, port: $port,
      repl_user: "repl",
      repl_password_secret: $sn,
      repl_password_key: "repl_password",
      dry_run: "false", confirm: "true"
    }')"
  assert_equal "$HTTP_CODE" "202"
  wait_for_task "$MARIADB_AQSH_B_URL" "$(echo "$HTTP_BODY" | jq -r '.id')"

  local repl_data
  repl_data="$(_result_data)"
  echo "setup-replication result: ${repl_data}" >&2
  assert_equal "$(echo "$repl_data" | jq -r '.status // empty')" "DONE"
  assert_equal "$(echo "$repl_data" | jq -r '.reason_code // empty')" "REPLICATION_CONFIGURED"
  assert_equal "$(echo "$repl_data" | jq -r '.replication.user // empty')" "repl"
  run echo "$repl_data" | jq -r '.slave_status'
  assert_output --partial "Slave_IO_Running: Yes"
  assert_output --partial "Slave_SQL_Running: Yes"
}
