#!/usr/bin/env bats
# =============================================================================
# Unit tests for aqsh-tasks/scripts/mongodb/recovery/setup-data-recovery.sh.
#
# Mocks kubectl to verify --profile bitnami vs --profile standard select the
# correct volume name / mount path / wipe path / runAsUser, without needing a
# real cluster. Captures the StatefulSet patch payload (the `-p` argument to
# `kubectl patch`) to a file so assertions can inspect it with jq.
#
# This script has no other test coverage: tests/mongodb/recovery.bats and
# recovery_custom_naming.bats only ever call it with --profile standard
# against a real cluster, so --profile bitnami's volume/mount/uid selection
# was previously unverified anywhere.
# =============================================================================

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mongodb/recovery/setup-data-recovery.sh"
  export SCRIPT

  export MOCK_IMAGE="mongo:7"
  export MOCK_REPLICAS="3"

  mkdir -p "${TEST_TMPDIR}/bin"

  # ── Mock kubectl ──────────────────────────────────────────────────────────
  cat > "${TEST_TMPDIR}/bin/kubectl" << 'KUBECTL_EOF'
#!/usr/bin/env bash
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context|--namespace|-n) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

cmd="${args[0]:-}"
case "$cmd" in
  get)
    # get statefulset NAME -o jsonpath='{...image...}{"\t"}{...replicas...}'
    # Plain `-` (not `:-`): an explicitly empty MOCK_IMAGE must stay empty so
    # the "image cannot be read" test can simulate that failure.
    printf '%s\t%s' "${MOCK_IMAGE-mongo:7}" "${MOCK_REPLICAS-3}"
    exit 0 ;;
  apply)
    cat > /dev/null   # consume the ConfigMap YAML on stdin
    exit 0 ;;
  patch)
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ "${args[$i]}" == "-p" ]]; then
        printf '%s' "${args[$((i + 1))]}" > "${TEST_TMPDIR}/captured-patch.json"
      fi
    done
    exit 0 ;;
esac
exit 0
KUBECTL_EOF
  chmod +x "${TEST_TMPDIR}/bin/kubectl"
}

# Extract a field via jq from the captured StatefulSet patch payload.
_patch_field() {
  jq -r "$1" "${TEST_TMPDIR}/captured-patch.json"
}

# ── Profile selection ─────────────────────────────────────────────────────

@test "--profile bitnami selects volume=datadir, mount=/bitnami/mongodb, runAsUser=1001" {
  run "${SCRIPT}" --context ctx --namespace ns --sts mongodb --profile bitnami
  [ "$status" -eq 0 ]
  [ "$(_patch_field '.spec.template.spec.initContainers[0].volumeMounts[0].name')" = "datadir" ]
  [ "$(_patch_field '.spec.template.spec.initContainers[0].volumeMounts[0].mountPath')" = "/bitnami/mongodb" ]
  [ "$(_patch_field '.spec.template.spec.initContainers[0].securityContext.runAsUser')" = "1001" ]
  _patch_field '.spec.template.spec.initContainers[0].args[0]' | grep -q '/bitnami/mongodb/data/db'
}

@test "--profile standard selects volume=data, mount=/data/db, runAsUser=999" {
  run "${SCRIPT}" --context ctx --namespace ns --sts mongodb --profile standard
  [ "$status" -eq 0 ]
  [ "$(_patch_field '.spec.template.spec.initContainers[0].volumeMounts[0].name')" = "data" ]
  [ "$(_patch_field '.spec.template.spec.initContainers[0].volumeMounts[0].mountPath')" = "/data/db" ]
  [ "$(_patch_field '.spec.template.spec.initContainers[0].securityContext.runAsUser')" = "999" ]
  _patch_field '.spec.template.spec.initContainers[0].args[0]' | grep -q '/data/db'
}

@test "patch locks the rolling-update partition at the current replica count" {
  export MOCK_REPLICAS="5"
  run "${SCRIPT}" --context ctx --namespace ns --sts mongodb --profile standard
  [ "$status" -eq 0 ]
  [ "$(_patch_field '.spec.updateStrategy.rollingUpdate.partition')" = "5" ]
}

@test "init container image matches the StatefulSet's current container image" {
  export MOCK_IMAGE="mongo:6.0.5"
  run "${SCRIPT}" --context ctx --namespace ns --sts mongodb --profile standard
  [ "$status" -eq 0 ]
  [ "$(_patch_field '.spec.template.spec.initContainers[0].image')" = "mongo:6.0.5" ]
}

# ── Validation / error paths ──────────────────────────────────────────────

@test "rejects an unknown profile" {
  run "${SCRIPT}" --context ctx --namespace ns --sts mongodb --profile turbo
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown --profile"* ]]
}

@test "rejects when image cannot be read from the StatefulSet" {
  export MOCK_IMAGE=""
  run "${SCRIPT}" --context ctx --namespace ns --sts mongodb --profile standard
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not read image"* ]]
}

@test "rejects when replica count is zero (would not lock the StatefulSet)" {
  export MOCK_REPLICAS="0"
  run "${SCRIPT}" --context ctx --namespace ns --sts mongodb --profile standard
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to set partition"* ]]
}

@test "rejects when replica count is non-numeric" {
  export MOCK_REPLICAS="abc"
  run "${SCRIPT}" --context ctx --namespace ns --sts mongodb --profile standard
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to set partition"* ]]
}

@test "usage error when a required flag is missing" {
  run "${SCRIPT}" --context ctx --namespace ns --sts mongodb
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}
