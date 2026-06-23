#!/usr/bin/env bats
# =============================================================================
# Unit tests for the auto-detect tier in lib/mongodb-recovery.sh
# (_recovery_detect_sts_name / _recovery_detect_configmap /
#  _recovery_detect_credentials / _recovery_detect_data_path and the
#  recovery_resolve_* wrappers that gate them behind "caller declared
#  nothing"). Uses a mock kubectl placed in $TEST_TMPDIR/bin; no cluster.
#
# Mock control env vars:
#   MOCK_OWNER_STS    name   StatefulSet name returned for a pod's ownerReferences
#                            (empty = pod has no StatefulSet owner)
#   MOCK_STS_LIST     names  space-separated StatefulSet names in the namespace
#   MOCK_STS_JSON     json   full `kubectl get statefulset <name> -o json` body
#   MOCK_DBPATH       path   dbPath returned by the mongosh serverCmdLineOpts probe
#   MOCK_EXEC_ERROR_TEXT text  simulates a kubectl/mongosh-layer failure (e.g.
#                            "Error from server (NotFound): pods \"x\" not
#                            found") instead of clean JS output — takes
#                            precedence over MOCK_DBPATH when set
# =============================================================================

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export K8S_NAMESPACE="mongo-1"
  export _LOG_CURRENT_LEVEL=3
  LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export LIB_DIR

  export MOCK_OWNER_STS=""
  export MOCK_STS_LIST="mongodb"
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{"env":[]}],"initContainers":[],"volumes":[]}}}}'
  export MOCK_DBPATH=""
  export MOCK_EXEC_ERROR_TEXT=""

  mkdir -p "${TEST_TMPDIR}/bin"

  cat > "${TEST_TMPDIR}/bin/kubectl" << 'KUBECTL_EOF'
#!/usr/bin/env bash
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context|--namespace|-n|--kubeconfig) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

cmd="${args[0]:-}"
sub="${args[1]:-}"
name="${args[2]:-}"
flags="${args[*]:-}"

case "$cmd" in
  get)
    case "$sub" in
      pod)
        if [[ "$flags" == *"ownerReferences"* ]]; then
          printf '%s' "${MOCK_OWNER_STS:-}"
        fi
        exit 0 ;;
      statefulsets)
        printf '%s' "${MOCK_STS_LIST:-}"
        exit 0 ;;
      statefulset|sts)
        if [[ "$flags" == *"-o json"* || "$flags" == *"json"* ]]; then
          printf '%s' "${MOCK_STS_JSON:-{\}}"
        fi
        exit 0 ;;
    esac
    exit 0 ;;
  exec)
    js="${flags}"
    if [[ "$js" == *"serverCmdLineOpts"* ]]; then
      if [[ -n "${MOCK_EXEC_ERROR_TEXT:-}" ]]; then
        printf '%s' "${MOCK_EXEC_ERROR_TEXT}"
      elif [[ -n "${MOCK_DBPATH:-}" ]]; then
        printf 'DBPATH:%s' "${MOCK_DBPATH}"
      fi
    fi
    exit 0 ;;
esac
exit 0
KUBECTL_EOF
  chmod +x "${TEST_TMPDIR}/bin/kubectl"

  # shellcheck source=/dev/null
  source "${LIB_DIR}/logging.sh"
  source "${LIB_DIR}/response.sh"
  source "${LIB_DIR}/k8s.sh"
  source "${LIB_DIR}/mongodb.sh"
  source "${LIB_DIR}/mongodb-recovery.sh"
}

# ── _recovery_detect_sts_name ───────────────────────────────────────────────

@test "detect_sts_name resolves from target pod's ownerReferences" {
  export MOCK_OWNER_STS="mongodb"
  run _recovery_detect_sts_name "mongodb-2"
  [ "$status" -eq 0 ]
  [ "$output" = "mongodb" ]
}

@test "detect_sts_name fails when target pod has no StatefulSet owner" {
  export MOCK_OWNER_STS=""
  run _recovery_detect_sts_name "mongodb-2"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "detect_sts_name resolves by namespace-listing when exactly one StatefulSet exists" {
  export MOCK_STS_LIST="mongodb"
  run _recovery_detect_sts_name ""
  [ "$status" -eq 0 ]
  [ "$output" = "mongodb" ]
}

@test "detect_sts_name fails closed when multiple StatefulSets exist and no target pod to disambiguate" {
  export MOCK_STS_LIST="mongodb other-sts"
  run _recovery_detect_sts_name ""
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ── _recovery_detect_configmap ──────────────────────────────────────────────

@test "detect_configmap resolves from the data-recovery init container's own volume binding" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{
    "initContainers":[{"name":"data-recovery","volumeMounts":[{"name":"recovery-config-vol","mountPath":"/recovery-config"}]}],
    "volumes":[{"name":"recovery-config-vol","configMap":{"name":"custom-recovery-cm"}}]
  }}}}'
  run _recovery_detect_configmap "mongodb"
  [ "$status" -eq 0 ]
  [ "$output" = "custom-recovery-cm" ]
}

@test "detect_configmap fails when there is no data-recovery init container" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"initContainers":[],"volumes":[]}}}}'
  run _recovery_detect_configmap "mongodb"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ── _recovery_detect_credentials ────────────────────────────────────────────

@test "detect_credentials resolves official-image MONGO_INITDB_ROOT_* secretKeyRefs" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{"env":[
    {"name":"MONGO_INITDB_ROOT_USERNAME","valueFrom":{"secretKeyRef":{"name":"mongodb-credentials","key":"MONGO_ROOT_USER"}}},
    {"name":"MONGO_INITDB_ROOT_PASSWORD","valueFrom":{"secretKeyRef":{"name":"mongodb-credentials","key":"MONGO_ROOT_PASS"}}}
  ]}]}}}}'
  run _recovery_detect_credentials "mongodb"
  [ "$status" -eq 0 ]
  IFS=$'\x1f' read -r secret direct_user user_key pass_key <<< "$output"
  [ "$secret" = "mongodb-credentials" ]
  [ "$direct_user" = "" ]
  [ "$user_key" = "MONGO_ROOT_USER" ]
  [ "$pass_key" = "MONGO_ROOT_PASS" ]
}

@test "detect_credentials resolves Bitnami-style MONGODB_ROOT_* secretKeyRefs" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{"env":[
    {"name":"MONGODB_ROOT_USER","valueFrom":{"secretKeyRef":{"name":"mongodb","key":"mongodb-root-user"}}},
    {"name":"MONGODB_ROOT_PASSWORD","valueFrom":{"secretKeyRef":{"name":"mongodb","key":"mongodb-root-password"}}}
  ]}]}}}}'
  run _recovery_detect_credentials "mongodb"
  [ "$status" -eq 0 ]
  IFS=$'\x1f' read -r secret direct_user user_key pass_key <<< "$output"
  [ "$secret" = "mongodb" ]
  [ "$user_key" = "mongodb-root-user" ]
  [ "$pass_key" = "mongodb-root-password" ]
}

@test "detect_credentials accepts a literal (non-secret) username alongside a secretKeyRef password" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{"env":[
    {"name":"MONGO_INITDB_ROOT_USERNAME","value":"root"},
    {"name":"MONGO_INITDB_ROOT_PASSWORD","valueFrom":{"secretKeyRef":{"name":"mongodb-credentials","key":"MONGO_ROOT_PASS"}}}
  ]}]}}}}'
  run _recovery_detect_credentials "mongodb"
  [ "$status" -eq 0 ]
  IFS=$'\x1f' read -r secret direct_user user_key pass_key <<< "$output"
  [ "$secret" = "mongodb-credentials" ]
  [ "$direct_user" = "root" ]
  [ "$user_key" = "" ]
  [ "$pass_key" = "MONGO_ROOT_PASS" ]
}

@test "detect_credentials fails soft when mongod has no env-based credential wiring at all" {
  # e.g. mongod started directly with --dbpath, bypassing entrypoint env wiring
  # (the actual shape of tests/mongodb/recovery_bitnami_profile.bats's fixture)
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{"env":[]}]}}}}'
  run _recovery_detect_credentials "mongodb"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "detect_credentials fails soft when username/password secretKeyRefs point at two different secrets" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{"env":[
    {"name":"MONGO_INITDB_ROOT_USERNAME","valueFrom":{"secretKeyRef":{"name":"secret-a","key":"user"}}},
    {"name":"MONGO_INITDB_ROOT_PASSWORD","valueFrom":{"secretKeyRef":{"name":"secret-b","key":"pass"}}}
  ]}]}}}}'
  run _recovery_detect_credentials "mongodb"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ── Bitnami file-mounted-secret convention (*_PASSWORD_FILE, no secretKeyRef) ─

@test "secret_ref_from_file resolves a Secret-backed volume mount to secret+key" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{"volumeMounts":[
    {"name":"mongodb-creds-vol","mountPath":"/opt/bitnami/mongodb/secrets","readOnly":true}
  ]}],"volumes":[
    {"name":"mongodb-creds-vol","secret":{"secretName":"mongodb-credentials"}}
  ]}}}}'
  run _recovery_secret_ref_from_file "$MOCK_STS_JSON" "/opt/bitnami/mongodb/secrets/mongodb-root-password"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'mongodb-credentials\x1fmongodb-root-password')" ]
}

@test "secret_ref_from_file fails soft when no volumeMount prefixes the file path" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{"volumeMounts":[
    {"name":"data","mountPath":"/data/db"}
  ]}],"volumes":[
    {"name":"data","persistentVolumeClaim":{"claimName":"data-mongodb-0"}}
  ]}}}}'
  run _recovery_secret_ref_from_file "$MOCK_STS_JSON" "/opt/bitnami/mongodb/secrets/mongodb-root-password"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "secret_ref_from_file fails soft when the matching volume isn't Secret-backed" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{"volumeMounts":[
    {"name":"data","mountPath":"/opt/bitnami/mongodb/secrets"}
  ]}],"volumes":[
    {"name":"data","persistentVolumeClaim":{"claimName":"data-mongodb-0"}}
  ]}}}}'
  run _recovery_secret_ref_from_file "$MOCK_STS_JSON" "/opt/bitnami/mongodb/secrets/mongodb-root-password"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "detect_credentials resolves a file-mounted Bitnami password with a literal root username" {
  # The real hardened-Bitnami shape: MONGODB_ROOT_USER is a literal value
  # ("root" isn't treated as sensitive); MONGODB_ROOT_PASSWORD_FILE holds a
  # path into a Secret-backed volume instead of a secretKeyRef env var.
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{
    "env":[
      {"name":"MONGODB_ROOT_USER","value":"root"},
      {"name":"MONGODB_ROOT_PASSWORD_FILE","value":"/opt/bitnami/mongodb/secrets/mongodb-root-password"}
    ],
    "volumeMounts":[{"name":"mongodb-creds-vol","mountPath":"/opt/bitnami/mongodb/secrets","readOnly":true}]
  }],"volumes":[{"name":"mongodb-creds-vol","secret":{"secretName":"mongodb-credentials"}}]}}}}'
  run _recovery_detect_credentials "mongodb"
  [ "$status" -eq 0 ]
  IFS=$'\x1f' read -r secret direct_user user_key pass_key <<< "$output"
  [ "$secret" = "mongodb-credentials" ]
  [ "$direct_user" = "root" ]
  [ "$user_key" = "" ]
  [ "$pass_key" = "mongodb-root-password" ]
}

@test "detect_credentials resolves both username and password via file-mounted secrets" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{
    "env":[
      {"name":"MONGODB_ROOT_USER_FILE","value":"/opt/bitnami/mongodb/secrets/mongodb-root-user"},
      {"name":"MONGODB_ROOT_PASSWORD_FILE","value":"/opt/bitnami/mongodb/secrets/mongodb-root-password"}
    ],
    "volumeMounts":[{"name":"mongodb-creds-vol","mountPath":"/opt/bitnami/mongodb/secrets","readOnly":true}]
  }],"volumes":[{"name":"mongodb-creds-vol","secret":{"secretName":"mongodb-credentials"}}]}}}}'
  run _recovery_detect_credentials "mongodb"
  [ "$status" -eq 0 ]
  IFS=$'\x1f' read -r secret direct_user user_key pass_key <<< "$output"
  [ "$secret" = "mongodb-credentials" ]
  [ "$direct_user" = "" ]
  [ "$user_key" = "mongodb-root-user" ]
  [ "$pass_key" = "mongodb-root-password" ]
}

@test "detect_credentials fails soft when *_PASSWORD_FILE points at a path with no matching volume mount" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{
    "env":[{"name":"MONGODB_ROOT_PASSWORD_FILE","value":"/some/unmounted/path/password"}],
    "volumeMounts":[{"name":"data","mountPath":"/data/db"}]
  }],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"data-mongodb-0"}}]}}}}'
  run _recovery_detect_credentials "mongodb"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ── _recovery_detect_data_path ──────────────────────────────────────────────

@test "detect_data_path resolves the live dbPath from mongod itself" {
  export MOCK_DBPATH="/bitnami/mongodb/data/db"
  run _recovery_detect_data_path "mongodb-0" "user" "pass"
  [ "$status" -eq 0 ]
  [ "$output" = "/bitnami/mongodb/data/db" ]
}

@test "detect_data_path fails soft when mongod reports no dbPath" {
  export MOCK_DBPATH=""
  run _recovery_detect_data_path "mongodb-0" "user" "pass"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "detect_data_path fails soft (does not mistake error text for a path) when kubectl exec fails before mongosh runs" {
  # _recovery_mongosh_pod merges kubectl's own stderr into stdout (2>&1) --
  # a kubectl-layer failure (pod not found, container not ready) produces
  # non-empty output that isn't JS-generated. The DBPATH: sentinel must
  # reject this rather than accepting the error text as a detected path.
  export MOCK_EXEC_ERROR_TEXT='Error from server (NotFound): pods "mongodb-0" not found'
  run _recovery_detect_data_path "mongodb-0" "user" "pass"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ── recovery_resolve_* precedence (explicit input always wins over detection) ─

@test "resolve_sts_name returns the explicit value without attempting detection" {
  export MOCK_OWNER_STS="should-not-be-used"
  run recovery_resolve_sts_name "explicit-sts" "mongodb-2"
  [ "$status" -eq 0 ]
  [ "$output" = "explicit-sts" ]
}

@test "resolve_sts_name falls through to detection when explicit is empty" {
  export MOCK_OWNER_STS="detected-sts"
  run recovery_resolve_sts_name "" "mongodb-2"
  [ "$status" -eq 0 ]
  [ "$output" = "detected-sts" ]
}

@test "resolve_sts_name falls through to hardcoded literal when explicit empty and detection fails" {
  export MOCK_OWNER_STS=""
  export MOCK_STS_LIST="a b"
  run recovery_resolve_sts_name "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "mongodb" ]
}

@test "resolve_configmap returns the explicit value without attempting detection" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"initContainers":[],"volumes":[]}}}}'
  run recovery_resolve_configmap "explicit-cm" "mongodb"
  [ "$status" -eq 0 ]
  [ "$output" = "explicit-cm" ]
}

@test "resolve_configmap falls through to hardcoded literal when detection fails" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"initContainers":[],"volumes":[]}}}}'
  run recovery_resolve_configmap "" "mongodb"
  [ "$status" -eq 0 ]
  [ "$output" = "mongodb-recovery-config" ]
}

@test "resolve_credentials skips detection entirely when caller declared any one credential field" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{"env":[
    {"name":"MONGO_INITDB_ROOT_USERNAME","valueFrom":{"secretKeyRef":{"name":"detected-secret","key":"u"}}},
    {"name":"MONGO_INITDB_ROOT_PASSWORD","valueFrom":{"secretKeyRef":{"name":"detected-secret","key":"p"}}}
  ]}]}}}}'
  run recovery_resolve_credentials "explicit-secret" "" "" "" "mongodb"
  [ "$status" -eq 0 ]
  IFS=$'\x1f' read -r secret direct_user user_key pass_key <<< "$output"
  [ "$secret" = "explicit-secret" ]
  # caller declared a secret but no keys — falls to hardcoded literal keys,
  # never mixes in the detected secret's keys.
  [ "$user_key" = "MONGO_ROOT_USER" ]
  [ "$pass_key" = "MONGO_ROOT_PASS" ]
}

@test "resolve_credentials skips detection when only direct_user is declared" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{"env":[
    {"name":"MONGO_INITDB_ROOT_USERNAME","valueFrom":{"secretKeyRef":{"name":"detected-secret","key":"u"}}},
    {"name":"MONGO_INITDB_ROOT_PASSWORD","valueFrom":{"secretKeyRef":{"name":"detected-secret","key":"p"}}}
  ]}]}}}}'
  run recovery_resolve_credentials "" "explicit-user" "" "" "mongodb"
  [ "$status" -eq 0 ]
  IFS=$'\x1f' read -r secret direct_user user_key pass_key <<< "$output"
  # secret stays the hardcoded literal (not "detected-secret") — proves
  # detection never ran just because direct_user was declared.
  [ "$secret" = "mongodb-credentials" ]
  [ "$direct_user" = "explicit-user" ]
  [ "$user_key" = "MONGO_ROOT_USER" ]
  [ "$pass_key" = "MONGO_ROOT_PASS" ]
}

@test "resolve_credentials skips detection when only credential_user_key is declared" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{"env":[
    {"name":"MONGO_INITDB_ROOT_USERNAME","valueFrom":{"secretKeyRef":{"name":"detected-secret","key":"u"}}},
    {"name":"MONGO_INITDB_ROOT_PASSWORD","valueFrom":{"secretKeyRef":{"name":"detected-secret","key":"p"}}}
  ]}]}}}}'
  run recovery_resolve_credentials "" "" "explicit-user-key" "" "mongodb"
  [ "$status" -eq 0 ]
  IFS=$'\x1f' read -r secret direct_user user_key pass_key <<< "$output"
  [ "$secret" = "mongodb-credentials" ]
  [ "$user_key" = "explicit-user-key" ]
  [ "$pass_key" = "MONGO_ROOT_PASS" ]
}

@test "resolve_credentials skips detection when only credential_pass_key is declared" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{"env":[
    {"name":"MONGO_INITDB_ROOT_USERNAME","valueFrom":{"secretKeyRef":{"name":"detected-secret","key":"u"}}},
    {"name":"MONGO_INITDB_ROOT_PASSWORD","valueFrom":{"secretKeyRef":{"name":"detected-secret","key":"p"}}}
  ]}]}}}}'
  run recovery_resolve_credentials "" "" "" "explicit-pass-key" "mongodb"
  [ "$status" -eq 0 ]
  IFS=$'\x1f' read -r secret direct_user user_key pass_key <<< "$output"
  [ "$secret" = "mongodb-credentials" ]
  [ "$pass_key" = "explicit-pass-key" ]
  [ "$user_key" = "MONGO_ROOT_USER" ]
}

@test "resolve_credentials detects when all four fields are empty" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{"env":[
    {"name":"MONGODB_ROOT_USER","valueFrom":{"secretKeyRef":{"name":"app-secret","key":"u"}}},
    {"name":"MONGODB_ROOT_PASSWORD","valueFrom":{"secretKeyRef":{"name":"app-secret","key":"p"}}}
  ]}]}}}}'
  run recovery_resolve_credentials "" "" "" "" "mongodb"
  [ "$status" -eq 0 ]
  IFS=$'\x1f' read -r secret direct_user user_key pass_key <<< "$output"
  [ "$secret" = "app-secret" ]
  [ "$user_key" = "u" ]
  [ "$pass_key" = "p" ]
}

@test "resolve_credentials falls through to hardcoded literal when all four empty and detection fails" {
  export MOCK_STS_JSON='{"spec":{"template":{"spec":{"containers":[{"env":[]}]}}}}'
  run recovery_resolve_credentials "" "" "" "" "mongodb"
  [ "$status" -eq 0 ]
  IFS=$'\x1f' read -r secret direct_user user_key pass_key <<< "$output"
  [ "$secret" = "mongodb-credentials" ]
  [ "$user_key" = "MONGO_ROOT_USER" ]
  [ "$pass_key" = "MONGO_ROOT_PASS" ]
}

# ── recovery_resolve_data_paths (module-level global upgrade) ──────────────

@test "resolve_data_paths leaves globals untouched when both data_path and mount_path are explicit" {
  _RECOVERY_DATA_PATH_EXPLICIT="/explicit/data"
  _RECOVERY_MOUNT_PATH_EXPLICIT="/explicit/mount"
  _RECOVERY_DATA_PATH="/explicit/data"
  _RECOVERY_MOUNT_PATH="/explicit/mount"
  export MOCK_DBPATH="/should/not/be/used"

  recovery_resolve_data_paths "mongodb-0" "user" "pass"

  [ "$_RECOVERY_DATA_PATH" = "/explicit/data" ]
  [ "$_RECOVERY_MOUNT_PATH" = "/explicit/mount" ]
}

@test "resolve_data_paths applies detection to mount_path only when data_path was explicit" {
  _RECOVERY_DATA_PATH_EXPLICIT="/explicit/data"
  _RECOVERY_MOUNT_PATH_EXPLICIT=""
  _RECOVERY_DATA_PATH="/explicit/data"
  _RECOVERY_MOUNT_PATH="/bitnami/mongodb"
  export MOCK_DBPATH="/data/db"

  recovery_resolve_data_paths "mongodb-0" "user" "pass"

  [ "$_RECOVERY_DATA_PATH" = "/explicit/data" ]
  [ "$_RECOVERY_MOUNT_PATH" = "/data/db" ]
}

@test "resolve_data_paths detects and applies to both data_path and mount_path when neither was explicit" {
  _RECOVERY_DATA_PATH_EXPLICIT=""
  _RECOVERY_MOUNT_PATH_EXPLICIT=""
  _RECOVERY_DATA_PATH="/bitnami/mongodb/data/db"
  _RECOVERY_MOUNT_PATH="/bitnami/mongodb"
  export MOCK_DBPATH="/data/db"

  recovery_resolve_data_paths "mongodb-0" "user" "pass"

  [ "$_RECOVERY_DATA_PATH" = "/data/db" ]
  [ "$_RECOVERY_MOUNT_PATH" = "/data/db" ]
}

@test "resolve_data_paths applies detection to data_path only when mount_path was explicit" {
  _RECOVERY_DATA_PATH_EXPLICIT=""
  _RECOVERY_MOUNT_PATH_EXPLICIT="/custom/mount"
  _RECOVERY_DATA_PATH="/bitnami/mongodb/data/db"
  _RECOVERY_MOUNT_PATH="/custom/mount"
  export MOCK_DBPATH="/data/db"

  recovery_resolve_data_paths "mongodb-0" "user" "pass"

  [ "$_RECOVERY_DATA_PATH" = "/data/db" ]
  [ "$_RECOVERY_MOUNT_PATH" = "/custom/mount" ]
}

@test "resolve_data_paths keeps the hardcoded literal when detection fails and nothing was explicit" {
  _RECOVERY_DATA_PATH_EXPLICIT=""
  _RECOVERY_MOUNT_PATH_EXPLICIT=""
  _RECOVERY_DATA_PATH="/bitnami/mongodb/data/db"
  _RECOVERY_MOUNT_PATH="/bitnami/mongodb"
  export MOCK_DBPATH=""

  recovery_resolve_data_paths "mongodb-0" "user" "pass"

  [ "$_RECOVERY_DATA_PATH" = "/bitnami/mongodb/data/db" ]
  [ "$_RECOVERY_MOUNT_PATH" = "/bitnami/mongodb" ]
}
