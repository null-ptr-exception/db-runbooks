#!/usr/bin/env bats
# =============================================================================
# Unit tests for the G1 self-heal mechanism in lib/mongodb-recovery.sh:
#   _recovery_detect_data_mount      — live volume/mount-path lookup
#   _recovery_detect_run_as_user     — live runAsUser lookup
#   _recovery_auto_patch_init_container — adds the missing init container
#   _recovery_revert_auto_patch      — surgically removes it again
#
# Uses a mock kubectl placed in $TEST_TMPDIR/bin; no cluster. The mock
# records every `patch` call's full argument string (which includes the -p
# JSON body) to patch-calls.log, one call per line, so tests can assert on
# exactly what was sent without needing a stateful fake API server.
#
# The wiring of these functions into recovery_run_gates (G1, gate mode only)
# and recovery_reset (revert) is intentionally NOT unit-tested here — it
# needs the full G1-G8 gate mock already established in
# tests/unit/mongodb/recovery.bats, and is instead proven end-to-end against
# a real cluster by tests/mongodb/recovery_auto_patch.bats.
#
# Mock control env vars:
#   MOCK_STS_JSON   json   full `kubectl get statefulset <name> -o json` body
#   MOCK_CM_EXISTS  1|0    whether `kubectl get configmap <name>` succeeds
#   MOCK_PATCH_FAIL 1|0    kubectl patch returns error
# =============================================================================

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export K8S_NAMESPACE="mongo-1"
  export _LOG_CURRENT_LEVEL=3
  LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export LIB_DIR

  export MOCK_STS_JSON='{"spec":{"replicas":3,"template":{"spec":{"containers":[{"image":"mongo:7"}]}}}}'
  export MOCK_CM_EXISTS=1
  export MOCK_PATCH_FAIL=0

  mkdir -p "${TEST_TMPDIR}/bin"
  : > "${TEST_TMPDIR}/patch-calls.log"

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
flags="${args[*]:-}"

case "$cmd" in
  get)
    case "$sub" in
      statefulset|sts)
        if [[ "$flags" == *"-o json"* || "$flags" == *"json"* ]]; then
          printf '%s' "${MOCK_STS_JSON:-{\}}"
        fi
        exit 0 ;;
      configmap|cm)
        [[ "${MOCK_CM_EXISTS:-1}" == "0" ]] && exit 1
        exit 0 ;;
    esac
    exit 0 ;;
  patch)
    [[ "${MOCK_PATCH_FAIL:-0}" == "1" ]] && { printf 'patch forbidden\n' >&2; exit 1; }
    printf '%s\n' "${flags}" >> "${TEST_TMPDIR}/patch-calls.log"
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

# Strip whitespace so substring assertions don't depend on kubectl/jq's
# pretty-printed spacing (e.g. "name": "x" vs "name":"x").
_compact() { tr -d '[:space:]'; }

# ── _recovery_detect_data_mount ─────────────────────────────────────────────

@test "detect_data_mount matches an exact mountPath" {
  local sts_json='{"spec":{"template":{"spec":{"containers":[{"volumeMounts":[{"name":"data","mountPath":"/data/db"}]}]}}}}'
  run _recovery_detect_data_mount "$sts_json" "/data/db"
  [ "$status" -eq 0 ]
  IFS=$'\x1f' read -r volume mount <<< "$output"
  [ "$volume" = "data" ]
  [ "$mount" = "/data/db" ]
}

@test "detect_data_mount matches the longest prefix when data_path is nested under the mount" {
  local sts_json='{"spec":{"template":{"spec":{"containers":[{"volumeMounts":[
    {"name":"datadir","mountPath":"/bitnami/mongodb"}
  ]}]}}}}'
  run _recovery_detect_data_mount "$sts_json" "/bitnami/mongodb/data/db"
  [ "$status" -eq 0 ]
  IFS=$'\x1f' read -r volume mount <<< "$output"
  [ "$volume" = "datadir" ]
  [ "$mount" = "/bitnami/mongodb" ]
}

@test "detect_data_mount picks the longest matching prefix among several volumeMounts" {
  local sts_json='{"spec":{"template":{"spec":{"containers":[{"volumeMounts":[
    {"name":"root-vol","mountPath":"/bitnami"},
    {"name":"datadir","mountPath":"/bitnami/mongodb"}
  ]}]}}}}'
  run _recovery_detect_data_mount "$sts_json" "/bitnami/mongodb/data/db"
  [ "$status" -eq 0 ]
  IFS=$'\x1f' read -r volume mount <<< "$output"
  [ "$volume" = "datadir" ]
  [ "$mount" = "/bitnami/mongodb" ]
}

@test "detect_data_mount fails soft when no volumeMount prefixes the data path" {
  local sts_json='{"spec":{"template":{"spec":{"containers":[{"volumeMounts":[{"name":"data","mountPath":"/some/other/path"}]}]}}}}'
  run _recovery_detect_data_mount "$sts_json" "/data/db"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "detect_data_mount fails soft when the container has no volumeMounts at all" {
  local sts_json='{"spec":{"template":{"spec":{"containers":[{"image":"mongo:7"}]}}}}'
  run _recovery_detect_data_mount "$sts_json" "/data/db"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ── _recovery_detect_run_as_user ────────────────────────────────────────────

@test "detect_run_as_user reads the container-level securityContext" {
  local sts_json='{"spec":{"template":{"spec":{"containers":[{"securityContext":{"runAsUser":2000}}]}}}}'
  run _recovery_detect_run_as_user "$sts_json"
  [ "$status" -eq 0 ]
  [ "$output" = "2000" ]
}

@test "detect_run_as_user falls back to the pod-level securityContext" {
  local sts_json='{"spec":{"template":{"spec":{"securityContext":{"runAsUser":999},"containers":[{"image":"mongo:7"}]}}}}'
  run _recovery_detect_run_as_user "$sts_json"
  [ "$status" -eq 0 ]
  [ "$output" = "999" ]
}

@test "detect_run_as_user guesses 1001 from a bitnami image when no securityContext is set" {
  local sts_json='{"spec":{"template":{"spec":{"containers":[{"image":"docker.io/bitnami/mongodb:7.0.0"}]}}}}'
  run _recovery_detect_run_as_user "$sts_json"
  [ "$status" -eq 0 ]
  [ "$output" = "1001" ]
}

@test "detect_run_as_user guesses 999 from a non-bitnami image when no securityContext is set" {
  local sts_json='{"spec":{"template":{"spec":{"containers":[{"image":"mongo:7"}]}}}}'
  run _recovery_detect_run_as_user "$sts_json"
  [ "$status" -eq 0 ]
  [ "$output" = "999" ]
}

# ── _recovery_auto_patch_init_container ─────────────────────────────────────

@test "auto_patch_init_container no-ops when the init container is already present" {
  export MOCK_STS_JSON='{"spec":{"replicas":3,"template":{"spec":{"initContainers":[{"name":"data-recovery"}],"containers":[{"image":"mongo:7"}]}}}}'
  run _recovery_auto_patch_init_container "mongodb" "mongodb-recovery-config"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "${TEST_TMPDIR}/patch-calls.log" ]
}

@test "auto_patch_init_container fails soft when the recovery ConfigMap does not exist yet" {
  export MOCK_CM_EXISTS=0
  run _recovery_auto_patch_init_container "mongodb" "mongodb-recovery-config"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ ! -s "${TEST_TMPDIR}/patch-calls.log" ]
}

@test "auto_patch_init_container fails soft when the image cannot be read" {
  export MOCK_STS_JSON='{"spec":{"replicas":3,"template":{"spec":{"containers":[{}]}}}}'
  run _recovery_auto_patch_init_container "mongodb" "mongodb-recovery-config"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "auto_patch_init_container fails soft when replicas is zero" {
  export MOCK_STS_JSON='{"spec":{"replicas":0,"template":{"spec":{"containers":[{"image":"mongo:7"}]}}}}'
  run _recovery_auto_patch_init_container "mongodb" "mongodb-recovery-config"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "auto_patch_init_container fails soft when no volumeMount matches the live data path" {
  export MOCK_STS_JSON='{"spec":{"replicas":3,"template":{"spec":{"containers":[{"image":"mongo:7","volumeMounts":[{"name":"other","mountPath":"/var/lib/other"}]}]}}}}'
  run _recovery_auto_patch_init_container "mongodb" "mongodb-recovery-config"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ ! -s "${TEST_TMPDIR}/patch-calls.log" ]
}

@test "auto_patch_init_container patches in the init container using the live-detected mount/runAsUser and locks the partition" {
  # _RECOVERY_DATA_PATH is normally upgraded by recovery_resolve_data_paths
  # (live mongod dbPath detection) before the caller script ever reaches
  # gates; set it directly here to simulate that already having happened,
  # matching the mock fixture's /data/db layout below (the module-load-time
  # default is the bitnami literal, which would not match this fixture).
  export _RECOVERY_DATA_PATH="/data/db"
  export MOCK_STS_JSON='{"spec":{"replicas":3,"template":{"spec":{"containers":[{"image":"mongo:7","securityContext":{"runAsUser":999},"volumeMounts":[{"name":"data","mountPath":"/data/db"}]}]}}}}'
  run _recovery_auto_patch_init_container "mongodb" "mongodb-recovery-config"
  [ "$status" -eq 0 ]
  [ "$output" = "patched" ]

  local body
  body=$(cat "${TEST_TMPDIR}/patch-calls.log" | _compact)
  [[ "$body" == *'"name":"data-recovery"'* ]] || { echo "$body" >&2; false; }
  [[ "$body" == *'"name":"data","mountPath":"/data/db"'* ]] || { echo "$body" >&2; false; }
  [[ "$body" == *'"name":"recovery-config-vol","mountPath":"/recovery-config"'* ]] || { echo "$body" >&2; false; }
  [[ "$body" == *'"configMap":{"name":"mongodb-recovery-config"}'* ]] || { echo "$body" >&2; false; }
  [[ "$body" == *'"runAsUser":999'* ]] || { echo "$body" >&2; false; }
  [[ "$body" == *'"partition":3'* ]] || { echo "$body" >&2; false; }
  [[ "$body" == *'"recovery/auto-patched":"true"'* ]] || { echo "$body" >&2; false; }
}

@test "auto_patch_init_container uses the bitnami-nested mount path for the wipe target but the shallower mountPath for the volumeMount" {
  # _RECOVERY_DATA_PATH is normally upgraded by recovery_resolve_data_paths
  # (live mongod dbPath detection) before the caller script ever reaches
  # gates; set it directly here to simulate that already having happened.
  export _RECOVERY_DATA_PATH="/bitnami/mongodb/data/db"
  export MOCK_STS_JSON='{"spec":{"replicas":2,"template":{"spec":{"containers":[{"image":"docker.io/bitnami/mongodb:7","volumeMounts":[{"name":"datadir","mountPath":"/bitnami/mongodb"}]}]}}}}'

  run _recovery_auto_patch_init_container "mongodb" "mongodb-recovery-config"
  [ "$status" -eq 0 ]
  [ "$output" = "patched" ]

  local body
  body=$(cat "${TEST_TMPDIR}/patch-calls.log" | _compact)
  [[ "$body" == *'"name":"datadir","mountPath":"/bitnami/mongodb"'* ]] || { echo "$body" >&2; false; }
  [[ "$body" == *'find/bitnami/mongodb/data/db-mindepth1-delete'* ]] || { echo "$body" >&2; false; }
  [[ "$body" == *'"runAsUser":1001'* ]] || { echo "$body" >&2; false; }
}

@test "auto_patch_init_container returns failure when the patch call itself fails" {
  export MOCK_PATCH_FAIL=1
  export MOCK_STS_JSON='{"spec":{"replicas":3,"template":{"spec":{"containers":[{"image":"mongo:7","volumeMounts":[{"name":"data","mountPath":"/data/db"}]}]}}}}'
  run _recovery_auto_patch_init_container "mongodb" "mongodb-recovery-config"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ── _recovery_revert_auto_patch ─────────────────────────────────────────────

@test "revert_auto_patch no-ops when the STS was never auto-patched" {
  export MOCK_STS_JSON='{"metadata":{"annotations":{}},"spec":{"replicas":3,"template":{"spec":{"containers":[{"image":"mongo:7"}]}}}}'
  run _recovery_revert_auto_patch "mongodb"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "${TEST_TMPDIR}/patch-calls.log" ]
}

@test "revert_auto_patch removes exactly the auto-added init container/volume and clears the annotation" {
  export MOCK_STS_JSON='{"metadata":{"annotations":{"recovery/auto-patched":"true"}},"spec":{"replicas":3,"template":{"spec":{"initContainers":[{"name":"data-recovery"}],"containers":[{"image":"mongo:7"}]}}}}'
  run _recovery_revert_auto_patch "mongodb"
  [ "$status" -eq 0 ]
  [ "$output" = "reverted" ]

  local body
  body=$(cat "${TEST_TMPDIR}/patch-calls.log" | _compact)
  [[ "$body" == *'"name":"data-recovery","$patch":"delete"'* ]] || { echo "$body" >&2; false; }
  [[ "$body" == *'"name":"recovery-config-vol","$patch":"delete"'* ]] || { echo "$body" >&2; false; }
  [[ "$body" == *'"recovery/auto-patched":null'* ]] || { echo "$body" >&2; false; }
}

@test "revert_auto_patch returns failure (best-effort) when the patch call itself fails" {
  export MOCK_PATCH_FAIL=1
  export MOCK_STS_JSON='{"metadata":{"annotations":{"recovery/auto-patched":"true"}},"spec":{"replicas":3,"template":{"spec":{"containers":[{"image":"mongo:7"}]}}}}'
  run _recovery_revert_auto_patch "mongodb"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ── recovery_reset wiring ────────────────────────────────────────────────────

@test "recovery_reset reports auto_patch_reverted true when the STS carries the auto-patched annotation" {
  export MOCK_STS_JSON='{"metadata":{"annotations":{"recovery/auto-patched":"true"}},"spec":{"replicas":3,"template":{"spec":{"initContainers":[{"name":"data-recovery"}],"containers":[{"image":"mongo:7"}]}}}}'
  run recovery_reset "mongodb" "mongodb-recovery-config" 3
  [ "$status" -eq 0 ]
  [[ "$output" == *'"auto_patch_reverted":true'* ]] || { echo "$output" >&2; false; }

  local body
  body=$(cat "${TEST_TMPDIR}/patch-calls.log" | _compact)
  [[ "$body" == *'"name":"data-recovery","$patch":"delete"'* ]] || { echo "$body" >&2; false; }
}

@test "recovery_reset reports auto_patch_reverted false when the STS was never auto-patched" {
  export MOCK_STS_JSON='{"metadata":{"annotations":{}},"spec":{"replicas":3,"template":{"spec":{"containers":[{"image":"mongo:7"}]}}}}'
  run recovery_reset "mongodb" "mongodb-recovery-config" 3
  [ "$status" -eq 0 ]
  [[ "$output" == *'"auto_patch_reverted":false'* ]] || { echo "$output" >&2; false; }
}
