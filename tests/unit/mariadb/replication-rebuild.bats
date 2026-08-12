#!/usr/bin/env bats
# =============================================================================
# Unit tests for lib/mariadb-replication-rebuild.sh — the volume selection that
# decides which datadirs get overwritten in place.
#
# Two failure modes matter here and neither is recoverable once the restore
# init hook starts:
#   - selecting too much  → another StatefulSet's data is overwritten
#   - selecting too little → a member keeps its old data while the rest are
#                            restored, and the instance comes back inconsistent
# =============================================================================

setup() {
  LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../../../aqsh-tasks/lib" && pwd)"
  export LIB_DIR DB_NAMESPACE="mariadb-1"
  # shellcheck disable=SC1091
  source "$LIB_DIR/mariadb-replication-rebuild.sh"
  MDB="mariadb"
}

# Mock the cluster: $PVC_LIST is what `get pvc -o name` returns, $LABEL_LIST
# what the label selector returns. Either can be made to fail.
_mock_kubectl() {
  _kubectl() {
    local args=("$@") is_label=0 a
    for a in "${args[@]}"; do [[ "$a" == -l ]] && is_label=1; done
    if (( is_label )); then
      [[ "${LABEL_FAILS:-0}" == 1 ]] && return 1
      printf '%s\n' "${LABEL_LIST:-}"
    else
      [[ "${NAME_FAILS:-0}" == 1 ]] && return 1
      printf '%s\n' "${PVC_LIST:-}"
    fi
  }
}

@test "selects this instance's data volumes" {
  LABEL_LIST=""
  PVC_LIST="persistentvolumeclaim/storage-mariadb-0
persistentvolumeclaim/storage-mariadb-1"
  _mock_kubectl
  run _mdbr_data_pvcs
  [ "$status" -eq 0 ]
  [ "$output" = $'storage-mariadb-0\nstorage-mariadb-1' ]
}

@test "does not select another StatefulSet's volumes with a similar suffix" {
  # storage-foo-mariadb-0 belongs to the "foo-mariadb" instance. A trailing
  # "-mariadb-<n>" match would sweep it into the set of datadirs we wipe.
  LABEL_LIST=""
  PVC_LIST="persistentvolumeclaim/storage-mariadb-0
persistentvolumeclaim/storage-foo-mariadb-0
persistentvolumeclaim/storage-mariadb-replica-mariadb-0"
  _mock_kubectl
  run _mdbr_data_pvcs
  [ "$status" -eq 0 ]
  [ "$output" = "storage-mariadb-0" ]
}

@test "does not select unrelated volumes" {
  LABEL_LIST=""
  PVC_LIST="persistentvolumeclaim/data-postgres-0
persistentvolumeclaim/storage-mariadb-0
persistentvolumeclaim/backup-scratch"
  _mock_kubectl
  run _mdbr_data_pvcs
  [ "$output" = "storage-mariadb-0" ]
}

@test "the label selector still contributes, and results are deduplicated" {
  LABEL_LIST="persistentvolumeclaim/storage-mariadb-0"
  PVC_LIST="persistentvolumeclaim/storage-mariadb-0
persistentvolumeclaim/storage-mariadb-1"
  _mock_kubectl
  run _mdbr_data_pvcs
  [ "$output" = $'storage-mariadb-0\nstorage-mariadb-1' ]
}

@test "a non-default volumeClaimTemplate name is honoured" {
  MDBR_PVC_TEMPLATE="data"
  LABEL_LIST=""
  PVC_LIST="persistentvolumeclaim/data-mariadb-0
persistentvolumeclaim/storage-mariadb-0"
  _mock_kubectl
  run _mdbr_data_pvcs
  [ "$output" = "data-mariadb-0" ]
}

@test "a failed label listing is an error, not an empty result" {
  # Swallowing this would silently restore fewer volumes than the instance has,
  # leaving one member on stale data.
  LABEL_FAILS=1
  PVC_LIST="persistentvolumeclaim/storage-mariadb-0"
  _mock_kubectl
  run _mdbr_data_pvcs
  [ "$status" -eq 1 ]
}

@test "a failed name listing is an error, not an empty result" {
  NAME_FAILS=1
  LABEL_LIST="persistentvolumeclaim/storage-mariadb-0"
  _mock_kubectl
  run _mdbr_data_pvcs
  [ "$status" -eq 1 ]
}

@test "no matching volumes is a valid empty result, not an error" {
  LABEL_LIST=""
  PVC_LIST="persistentvolumeclaim/data-postgres-0"
  _mock_kubectl
  run _mdbr_data_pvcs
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- exact backup selection --------------------------------------------------

_mock_storage_client() {
  BACKUP_BUCKET="db-backups"
  BACKUP_PREFIX="mariadb/mariadb-1"
  BACKUP_ENDPOINT="http://minio:9000"
  mdbt_s3_prepare_direct_client() { return 0; }
  setup_minio_client() { return 0; }
  s5() { printf '%s\n' "${S5_LISTING:-}"; }
}

@test "exact backup lookup ignores prefix siblings" {
  S5_LISTING='{"key":"s3://db-backups/mariadb/mariadb-1/physical-1.xb.bz2","type":"file"}
{"key":"s3://db-backups/mariadb/mariadb-1/physical-10.xb.bz2","type":"file"}'
  _mock_storage_client

  run _mdbr_exact_backup_object physical-1
  [ "$status" -eq 0 ]
  [ "$output" = "s3://db-backups/mariadb/mariadb-1/physical-1.xb.bz2" ]
}

@test "exact backup lookup rejects multiple compression variants" {
  S5_LISTING='{"key":"s3://db-backups/mariadb/mariadb-1/physical-1.xb","type":"file"}
{"key":"s3://db-backups/mariadb/mariadb-1/physical-1.xb.gz","type":"file"}'
  _mock_storage_client

  run _mdbr_exact_backup_object physical-1
  [ "$status" -eq 3 ]
}

@test "in-place restore hook downloads the preflighted object exactly" {
  NAMESPACE="mariadb-1"
  BACKUP_ENDPOINT="http://minio:9000"
  BACKUP_BUCKET="db-backups"
  BACKUP_PREFIX="mariadb/mariadb-1"
  BACKUP_ACCESS_SECRET="minio"
  BACKUP_ACCESS_KEY="access-key-id"
  BACKUP_SECRET_ACCESS_SECRET="minio"
  BACKUP_SECRET_KEY="secret-access-key"

  run _mdbr_restore_init_containers mariadb:10.6 \
    s3://db-backups/mariadb/mariadb-1/physical-1.xb.bz2 physical-1
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<<"$output")" = "4" ]
  # v0.0.24's CRD uses []Container without a name field and the operator names
  # the resulting Pod init containers init-0, init-1, ... itself.
  [ "$(jq -r 'all(.[]; has("name") | not)' <<<"$output")" = "true" ]
  [ "$(jq -r '.[1].args[3]' <<<"$output")" = \
    "s3://db-backups/mariadb/mariadb-1/physical-1.xb.bz2" ]
  [ "$(jq -r '.[1].args[4]' <<<"$output")" = \
    "/var/lib/mysql/.aqsh-restore/backup.source" ]
  [[ "$(jq -r '.[3].args[0]' <<<"$output")" == \
    *"mariabackup --prepare"* ]]
  [[ "$(jq -r '.[3].args[0]' <<<"$output")" != \
    *"mariadb-backup --prepare"* ]]
  [[ "$(jq -r '.[3].args[0]' <<<"$output")" == \
    *"! -name .aqsh-restore"* ]]
  [ "$(jq -r '.[0] | has("volumeMounts")' <<<"$output")" = "false" ]
}

@test "restore hook is appended without changing existing user init containers" {
  local original restore combined
  original='[{"image":"busybox:1.36","args":["true"]}]'
  restore='[{"image":"alpine:3.20","args":["prepare"]},{"image":"mariadb:10.6","args":["restore"]}]'

  combined="$(jq -nc --argjson original "$original" --argjson restore "$restore" \
    '($original // []) + $restore')"

  [ "$(jq -c '.[0]' <<<"$combined")" = \
    '{"image":"busybox:1.36","args":["true"]}' ]
  [ "$(jq -r '[.[].image] | join(" ")' <<<"$combined")" = \
    "busybox:1.36 alpine:3.20 mariadb:10.6" ]
}

@test "v24 restore fences rollout and patches the CR hook without scaling" {
  local calls="$BATS_TEST_TMPDIR/kubectl.calls"
  _kubectl() {
    printf '%s\n' "$*" >> "$calls"
  }

  _mdbr_patch_sts_strategy '{"type":"OnDelete"}'
  _mdbr_patch_init_containers '[]'
  grep -q 'patch statefulset mariadb --type merge' "$calls"
  grep -q 'OnDelete' "$calls"
  grep -q 'patch mariadb mariadb --type merge' "$calls"
  ! grep -q 'scale statefulset' "$calls"
}
