#!/usr/bin/env bats
#
# Contract test for the aqsh `include:` config model.
#
# The runbook images use a main config per DB (`task-<db>.yaml`) that owns the
# global `defaults:` and pulls the task list in via `include:` (`tasks-<db>.yaml`).
# aqsh enforces that an INCLUDED file must not define its own `defaults:`.
#
# These tests run the EXACT aqsh version the repo ships (parsed from ./Dockerfile)
# against the REAL aqsh-tasks/*.yaml files, so the suite breaks if someone
# reintroduces a `defaults:` block into an included file or breaks the include
# wiring.

setup_file() {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
  command -v docker >/dev/null 2>&1 || skip "docker not available"

  AQSH_IMAGE="$(grep -m1 '^FROM' "${REPO_ROOT}/Dockerfile" | awk '{print $2}')"
  [[ -n "$AQSH_IMAGE" ]] || skip "could not resolve aqsh base image from Dockerfile"

  # Build an image that mirrors the repo Dockerfile's config layer: every
  # task*.yaml dropped flat into /etc/aqsh so relative includes resolve.
  local ctx="${BATS_FILE_TMPDIR}/ctx"
  mkdir -p "$ctx"
  cp "${REPO_ROOT}"/aqsh-tasks/task*.yaml "$ctx/"
  cat > "${ctx}/Dockerfile" <<EOF
FROM ${AQSH_IMAGE}
COPY task*.yaml /etc/aqsh/
EOF
  SHIPPED_IMG="aqsh-include-shipped:bats"
  docker build --platform linux/amd64 -q -t "$SHIPPED_IMG" "$ctx" >/dev/null \
    || skip "could not build aqsh test image (offline?)"

  export REPO_ROOT AQSH_IMAGE SHIPPED_IMG
}

teardown_file() {
  [[ -n "${SHIPPED_IMG:-}" ]] && docker rmi -f "$SHIPPED_IMG" >/dev/null 2>&1 || true
}

# Start aqsh against $1 and return its early startup logs in $output. A valid
# config makes aqsh proceed past loading (then block retrying Redis), so we read
# logs from a detached container rather than wait for exit. Avoids `timeout`,
# which is absent on macOS.
startup_logs() {
  local tasks_path="$1" cid
  cid="$(docker run -d --platform linux/amd64 "$SHIPPED_IMG" \
    -tasks "$tasks_path" -mode worker)"
  # Poll the logs until a load verdict appears (or we time out) instead of a
  # fixed sleep — startup timing varies and a hard wait flakes in CI.
  local deadline=$((SECONDS + 15))
  while true; do
    output="$(docker logs "$cid" 2>&1)"
    [[ "$output" == *"loaded tasks config"* \
      || "$output" == *"failed to load tasks config"* \
      || "$output" == *"must not define defaults"* ]] && break
    (( SECONDS >= deadline )) && break
    sleep 0.5
  done
  docker rm -f "$cid" >/dev/null 2>&1 || true
}

@test "mariadb main config loads its include cleanly" {
  startup_logs /etc/aqsh/task-mariadb.yaml
  [[ "$output" == *"loaded tasks config"* ]]
  [[ "$output" != *"failed to load tasks config"* ]]
  [[ "$output" != *"must not define defaults"* ]]
}

@test "mongodb main config loads its include cleanly" {
  startup_logs /etc/aqsh/task-mongodb.yaml
  [[ "$output" == *"loaded tasks config"* ]]
  [[ "$output" != *"failed to load tasks config"* ]]
  [[ "$output" != *"must not define defaults"* ]]
}

@test "included task lists define no top-level defaults" {
  # Fast structural guard: an included file must not start a `defaults:` block.
  run grep -n '^defaults:' "${REPO_ROOT}/aqsh-tasks/tasks-mariadb.yaml"
  [ "$status" -ne 0 ]
  run grep -n '^defaults:' "${REPO_ROOT}/aqsh-tasks/tasks-mongodb.yaml"
  [ "$status" -ne 0 ]
}

@test "regression: aqsh still rejects an included file that defines defaults" {
  # Reintroduce a defaults block into the included file and confirm the loader
  # refuses it — proving the include contract is enforced, not assumed.
  command -v docker >/dev/null 2>&1 || skip "docker not available"
  local ctx="${BATS_TEST_TMPDIR}/ctx"
  mkdir -p "$ctx"
  printf 'include:\n  - tasks-mariadb.yaml\n' > "${ctx}/task-mariadb.yaml"
  printf 'defaults:\n  queue: mariadb\ntasks:\n  x:\n    script: x.sh\n' \
    > "${ctx}/tasks-mariadb.yaml"
  cat > "${ctx}/Dockerfile" <<EOF
FROM ${AQSH_IMAGE}
COPY task-mariadb.yaml /etc/aqsh/task-mariadb.yaml
COPY tasks-mariadb.yaml /etc/aqsh/tasks-mariadb.yaml
EOF
  local img="aqsh-include-regression:bats"
  docker build --platform linux/amd64 -q -t "$img" "$ctx" >/dev/null \
    || skip "could not build aqsh test image (offline?)"

  run docker run --rm --platform linux/amd64 "$img" \
    -tasks /etc/aqsh/task-mariadb.yaml -mode worker
  docker rmi -f "$img" >/dev/null 2>&1 || true

  [ "$status" -ne 0 ]
  [[ "$output" == *"must not define defaults"* ]]
}
