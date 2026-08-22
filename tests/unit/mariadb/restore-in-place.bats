#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/aqsh-tasks/scripts/mariadb/restore-in-place.sh"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"
  MOCK_DIR="$(mktemp -d)"
  RESULT="${MOCK_DIR}/result.json"
  CALLS="${MOCK_DIR}/kubectl.calls"
  INIT_COUNT="${MOCK_DIR}/init-count"
  UID_GENERATION="${MOCK_DIR}/uid-generation"
  printf '0\n' > "$INIT_COUNT"
  printf '0\n' > "$UID_GENERATION"

  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_CALLS}"
args="$*"
payload_after_p() {
  local previous="" arg
  for arg in "$@"; do
    if [[ "$previous" == "-p" ]]; then printf '%s' "$arg"; return; fi
    previous="$arg"
  done
}
case "$args" in
  *"get mariadb -o jsonpath={range .items"*) printf 'mariadb' ;;
  *"get mariadb mariadb -o jsonpath={.spec.replicas}"*) printf '1' ;;
  *"get mariadb mariadb -o json"*)
    jq -n '{spec:{image:"mariadb:10.6",replicas:1,env:[],envFrom:[]},
      status:{currentPrimary:"mariadb-0",conditions:[{type:"Ready",status:"True"}]}}' ;;
  *"get pods"*"-o json"*)
    jq -n '{items:[{metadata:{name:"mariadb-0",ownerReferences:[{kind:"StatefulSet",name:"mariadb",controller:true}]},spec:{containers:[{name:"mariadb",env:[],envFrom:[]}]}}]}' ;;
  *"get pod mariadb-0 -o jsonpath={.metadata.uid}"*)
    printf 'pod-%s' "$(cat "$MOCK_UID_GENERATION")" ;;
  *"get pod mariadb-0 -o json"*)
    jq -n --arg uid "pod-$(cat "$MOCK_UID_GENERATION")" \
      '{metadata:{uid:$uid},status:{phase:"Running",containerStatuses:[{name:"mariadb",ready:true}]}}' ;;
  *"get pvc"*"-l "*"-o name"*) printf 'persistentvolumeclaim/storage-mariadb-0\n' ;;
  *"get pvc -o name"*) printf 'persistentvolumeclaim/storage-mariadb-0\n' ;;
  *"get statefulset mariadb -o json"*)
    jq -n --argjson count "$(cat "$MOCK_INIT_COUNT")" \
      '{spec:{updateStrategy:{type:"RollingUpdate"},template:{spec:{initContainers:[range(0;$count)|{}]}}}}' ;;
  *"get secret minio -o json"*)
    jq -n '{data:{"access-key-id":("access"|@base64),"secret-access-key":("secret"|@base64)}}' ;;
  *"exec mariadb-0"*"printenv MARIADB_ROOT_PASSWORD"*) printf 'root-secret\n' ;;
  *"exec mariadb-0"*) printf '' ;;
  *"patch mariadb mariadb --type merge"*)
    payload="$(payload_after_p "$@")"
    jq -r '.spec.initContainers | if . == null then 0 else length end' <<<"$payload" > "$MOCK_INIT_COUNT" ;;
  *"patch statefulset mariadb --type merge"*) : ;;
  *"delete pod mariadb-0 --wait=false"*)
    generation="$(cat "$MOCK_UID_GENERATION")"
    printf '%s\n' "$((generation + 1))" > "$MOCK_UID_GENERATION" ;;
  *) printf 'unexpected kubectl call: %s\n' "$args" >&2; exit 99 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/kubectl"

  cat > "${MOCK_DIR}/s5cmd" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *" ls "* ]]; then
  printf '%s\n' '{"key":"s3://db-backups/tenant-a/database/physical-1.xb","type":"file"}'
fi
MOCK
  chmod +x "${MOCK_DIR}/s5cmd"
}

teardown() { rm -rf "$MOCK_DIR"; }

run_restore_in_place() {
  run env PATH="${MOCK_DIR}:${PATH}" LIB_DIR="$LIB_DIR_REAL" \
    AQSH_RESULT_FILE="$RESULT" MOCK_CALLS="$CALLS" \
    MOCK_INIT_COUNT="$INIT_COUNT" MOCK_UID_GENERATION="$UID_GENERATION" \
    MARIADB_OPERATOR_GROUP_DEFAULT=mariadb.mmontes.io \
    DB_NAMESPACE=mariadb-1 BACKUP_NAME=physical-1 \
    BACKUP_ENDPOINT=http://minio:9000 BACKUP_BUCKET=db-backups \
    BACKUP_PREFIX=tenant-a/database BACKUP_ACCESS_SECRET=minio \
    BACKUP_ACCESS_KEY=access-key-id BACKUP_SECRET_ACCESS_SECRET=minio \
    BACKUP_SECRET_KEY=secret-access-key "$@" bash "$SCRIPT"
}

@test "restore-in-place dry run validates exact backup without mutation" {
  run_restore_in_place DRY_RUN=true
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$RESULT")" = "success" ]
  [ "$(jq -r '.data.inPlace' "$RESULT")" = "true" ]
  [ "$(jq -r '.data.backup' "$RESULT")" = "physical-1" ]
  [ "$(jq -r '.data.changed' "$RESULT")" = "false" ]
  ! grep -q 'scale statefulset' "$CALLS"
  ! grep -q 'patch statefulset' "$CALLS"
  ! grep -q 'delete pod' "$CALLS"
}

@test "restore-in-place apply requires confirm before Pod replacement" {
  run_restore_in_place DRY_RUN=false CONFIRM=false
  [ "$status" -ne 0 ]
  [ "$(jq -r '.reason' "$RESULT")" = "INVALID_REQUEST" ]
  ! grep -q 'scale statefulset' "$CALLS"
  ! grep -q 'delete pod' "$CALLS"
}

@test "restore-in-place preserves objects and restores the existing PVC" {
  run_restore_in_place DRY_RUN=false CONFIRM=true WAIT_TIMEOUT=30
  [ "$status" -eq 0 ]
  [ "$(jq -r '.data.state' "$RESULT")" = "COMPLETED" ]
  [ "$(jq -r '.data.changed' "$RESULT")" = "true" ]
  ! grep -q 'scale statefulset' "$CALLS"
  [ "$(grep -c 'delete pod mariadb-0 --wait=false' "$CALLS")" -eq 2 ]
  grep -q 'patch statefulset mariadb --type merge' "$CALLS"
  grep -q 'OnDelete' "$CALLS"
  [ "$(grep -c 'patch mariadb mariadb --type merge' "$CALLS")" -eq 2 ]
  ! grep -q 'delete mariadb' "$CALLS"
  ! grep -q 'delete pvc' "$CALLS"
  [ "$(cat "$INIT_COUNT")" = "0" ]
  [ "$(cat "$UID_GENERATION")" = "2" ]
}
