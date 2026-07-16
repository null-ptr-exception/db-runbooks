#!/usr/bin/env bats
#
# Contract test for the blue/green capability gate (bg_require_bluegreen_capable,
# invoked from bg_init_target). Blue/green needs the current-generation operator
# (ExternalMariaDB + multiCluster + physical bootstrapFrom); on a legacy
# mmontes-era operator it must fail fast with a stable public reason without
# exposing the platform implementation behind the task.
#
# Mock control:
#   MOCK_HAS_EXT=1  the ExternalMariaDB CRD exists (current generation)
#   MOCK_HAS_EXT=0  it does not (legacy operator)

setup() {
  unset MARIADB_OPERATOR_GROUP_DEFAULT _MDB_OPERATOR_GROUP
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  LIB_DIR_REAL="${REPO_ROOT}/aqsh-tasks/lib"
  MOCK_DIR="$(mktemp -d)"
  RESULT="${MOCK_DIR}/result.json"

  cat > "${MOCK_DIR}/kubectl" <<'MOCK'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *api-resources*)
    if [[ "${MOCK_HAS_EXT:-1}" == "1" ]]; then
      printf '%s\n' mariadbs.k8s.mariadb.com externalmariadbs.k8s.mariadb.com physicalbackups.k8s.mariadb.com
    else
      printf '%s\n' mariadbs.mariadb.mmontes.io backups.mariadb.mmontes.io restores.mariadb.mmontes.io
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "${MOCK_DIR}/kubectl"
}

teardown() { rm -rf "${MOCK_DIR}"; }

# Run bg_init_target (which invokes the gate) in a fresh shell.
run_gate() {
  run env "PATH=${MOCK_DIR}:${PATH}" \
    "LIB_DIR=${LIB_DIR_REAL}" \
    "AQSH_RESULT_FILE=${RESULT}" \
    "DB_NAMESPACE=mariadb-1" \
    "_LOG_CURRENT_LEVEL=3" \
    "$@" \
    bash -c 'source "${LIB_DIR}/mariadb-blue-green.sh"; bg_init_target; echo GATE_PASSED'
}

result_field() { jq -r "$1" "${RESULT}"; }

write_create_fake_lib() {
  local fake_lib="${MOCK_DIR}/fake-lib"
  mkdir -p "$fake_lib"
  cat > "${fake_lib}/mariadb-blue-green.sh" <<'FAKE_LIB'
#!/usr/bin/env bash
BG_NAMESPACE="${DB_NAMESPACE:?DB_NAMESPACE is required}"
BG_MDB="${MARIADB_NAME:-mariadb}"

mdbt_load_config() { :; }
bg_required() { [[ -n "$2" ]] || return 2; }
bg_init_target() { :; }
mdbt_resolve_backup_location() { return 0; }
bg_require_confirm() { :; }
bg_validate_dns_label() { :; }
bg_validate_image() { :; }
bg_validate_url() { :; }
bg_create_physical_backup() {
  BG_BACKUP_DATA='{"bucket":"private-bucket","manifest":"private-manifest","sourceStatus":{"conditions":["private-condition"]}}'
}
bg_peer_call_task() {
  printf '%s\n' '{"taskId":"private-task-id","body":"private-http-body","manifest":"private-peer-manifest"}'
}
bg_write_result() { printf '%s\n' "$1"; }
response_ok() {
  jq -nc --arg op "$1" --arg message "$2" --argjson data "$3" \
    '{status:"success",code:0,operation:$op,message:$message,data:$data}'
}
bg_fail() {
  jq -nc --arg op "$1" --arg message "$2" --argjson data "${3:-{}}" \
    --argjson code "${4:-1}" --arg reason "${5:-OPERATION_FAILED}" \
    '{status:"error",code:$code,operation:$op,message:$message,data:$data,reason:$reason}'
  exit "${4:-1}"
}
FAKE_LIB
  printf '%s\n' "$fake_lib"
}

@test "gate passes on a current-generation operator (ExternalMariaDB present)" {
  run_gate MOCK_HAS_EXT=1
  [ "$status" -eq 0 ]
  [[ "$output" == *GATE_PASSED* ]]
}

@test "gate fails fast on a legacy operator (no ExternalMariaDB CRD)" {
  run_gate MOCK_HAS_EXT=0
  [ "$status" -ne 0 ]
  [[ "$output" != *GATE_PASSED* ]]
  [ "$(result_field '.status')" = "error" ]
  [ "$(result_field '.reason')" = "OPERATION_UNAVAILABLE" ]
  [ "$(result_field '.message')" = "blue-green is unavailable for this database" ]
  [ "$(result_field '.data.stage')" = "capability-check" ]
  [ "$(result_field '.data.available')" = "false" ]

  local public_result
  public_result="$(cat "$RESULT")"
  [[ "$public_result" != *"k8s.mariadb.com"* ]]
  [[ "$public_result" != *"ExternalMariaDB"* ]]
  [[ "$public_result" != *"operatorGroup"* ]]
  [[ "$public_result" != *"multiCluster"* ]]
  [[ "$public_result" != *"Kubernetes"* ]]
}

@test "physical backup descriptor keeps storage policy and raw status private" {
  run env \
    "LIB_DIR=${LIB_DIR_REAL}" \
    "DB_NAMESPACE=mariadb-1" \
    "_LOG_CURRENT_LEVEL=3" \
    bash -c '
      source "${LIB_DIR}/mariadb-blue-green.sh"
      BG_MDB="mariadb"
      BACKUP_NAME="backup-public-id"
      BACKUP_BUCKET="private-bucket"
      BACKUP_PREFIX="private/prefix"
      BACKUP_ENDPOINT="https://private-storage.example"
      BACKUP_REGION="private-region"
      BACKUP_ACCESS_SECRET="private-access-secret"
      BACKUP_ACCESS_KEY="private-access-key"
      BACKUP_SECRET_ACCESS_SECRET="private-secret-access-secret"
      BACKUP_SECRET_KEY="private-secret-key"
      BACKUP_TARGET="PreferReplica"
      BACKUP_COMPRESSION="bzip2"
      WAIT_TIMEOUT="1s"

      bg_get_mariadb_json() {
        printf "%s\n" '\''{"metadata":{"namespace":"mariadb-1","name":"mariadb"},"status":{"conditions":[{"type":"Ready","status":"True","reason":"private-condition"}],"currentPrimary":"private-pod"}}'\''
      }
      mdbt_physical_backup_manifest() { printf "%s\n" "{}"; }
      _kubectl() {
        if [[ "${1:-}" == "apply" ]]; then
          command cat >/dev/null
        fi
        return 0
      }

      bg_create_physical_backup "blue-green/create"
      printf "%s\n" "$BG_BACKUP_DATA"
    '

  [ "$status" -eq 0 ]
  [ "$(jq -r '.namespace' <<<"$output")" = "mariadb-1" ]
  [ "$(jq -r '.backupName' <<<"$output")" = "backup-public-id" ]
  [ "$(jq -r '.completed' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("bucket") or has("prefix") or has("endpoint") or has("region") or has("sourceStatus")' <<<"$output")" = "false" ]
  [[ "$output" != *"private-storage"* ]]
  [[ "$output" != *"private-secret"* ]]
  [[ "$output" != *"private-pod"* ]]
  [[ "$output" != *"private-condition"* ]]
}

@test "peer failures keep transport diagnostics private" {
  run env \
    "LIB_DIR=${LIB_DIR_REAL}" \
    "DB_NAMESPACE=mariadb-1" \
    "_LOG_CURRENT_LEVEL=3" \
    bash -c '
      source "${LIB_DIR}/mariadb-blue-green.sh"
      curl() {
        printf "%s\n" "private-curl-stderr private-task-id private-http-body" >&2
        return 7
      }
      if bg_peer_call_task "blue-green/create" "https://peer.example" "private-token" \
        "blue-green/create" "{}" 1; then
        exit 1
      fi
      printf "%s\n" "$BG_PEER_ERR"
    '

  [ "$status" -eq 0 ]
  [ "$(jq -r '.stage' <<<"$output")" = "peer-operation" ]
  [[ "$output" != *"private-curl-stderr"* ]]
  [[ "$output" != *"private-task-id"* ]]
  [[ "$output" != *"private-http-body"* ]]
  [[ "$output" != *"private-token"* ]]
}

@test "create returns only high-level stage results" {
  local fake_lib
  fake_lib="$(write_create_fake_lib)"

  run env \
    "LIB_DIR=${fake_lib}" \
    "DB_NAMESPACE=mariadb-1" \
    "BLUE_NAME=mariadb-blue" \
    "GREEN_NAME=mariadb-green" \
    "GREEN_IMAGE=mariadb:11.4" \
    "TARGET_IMAGE=mariadb:11.8" \
    "PEER_AQSH_URL=https://peer.example" \
    "PEER_TOKEN=private-token" \
    "CONFIRM=true" \
    bash "${REPO_ROOT}/aqsh-tasks/scripts/mariadb/blue-green/create.sh"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = "success" ]
  [ "$(jq -r '.data.stage' <<<"$output")" = "ready" ]
  [ "$(jq -r '.data.completed' <<<"$output")" = "true" ]
  [ "$(jq -r '.data.backupCompleted' <<<"$output")" = "true" ]
  [ "$(jq -r '.data.bootstrapCompleted' <<<"$output")" = "true" ]
  [ "$(jq -r '.data.upgradePerformed' <<<"$output")" = "true" ]
  [ "$(jq -r '.data.replicationValidated' <<<"$output")" = "true" ]
  [ "$(jq -r '.data | has("backup") or has("bootstrap") or has("upgrade") or has("replicationValidate")' <<<"$output")" = "false" ]
  [[ "$output" != *"private-bucket"* ]]
  [[ "$output" != *"private-manifest"* ]]
  [[ "$output" != *"private-task-id"* ]]
  [[ "$output" != *"private-http-body"* ]]
  [[ "$output" != *"private-token"* ]]
}
