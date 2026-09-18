#!/usr/bin/env bash
# One standalone Bats file in a fresh Docker daemon. No host kubeconfig/socket
# is mounted; fixed cluster/registry names are private to this invocation.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_FILE="${1:-tests/mariadb-legacy/replication_link.bats}"
case "$TEST_FILE" in
  tests/*.bats) ;;
  *) echo 'Pass one repository-relative E2E .bats file (not a directory).' >&2; exit 2 ;;
esac
[[ "$TEST_FILE" != *..* && -f "$ROOT_DIR/$TEST_FILE" ]] || exit 2
ARTIFACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/db-runbooks-e2e.XXXXXX")"
chmod 700 "$ARTIFACT_DIR"
CONTAINER="db-runbooks-e2e-$(date +%s)-$$"
created=false
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ "$created" == true ]]; then
    docker inspect "$CONTAINER" --format '{{json .State}}' >"$ARTIFACT_DIR/container-state.json" 2>/dev/null || true
    docker logs "$CONTAINER" >"$ARTIFACT_DIR/daemon.log" 2>&1 || true
    docker cp "$CONTAINER:/workspace/e2e.tap" "$ARTIFACT_DIR/e2e.tap" >/dev/null 2>&1 || true
    if ! docker rm -f -v "$CONTAINER" >/dev/null; then
      echo "Failed to remove isolated E2E container: $CONTAINER" >&2
      [[ "$rc" -ne 0 ]] || rc=1
    fi
  fi
  echo "Local E2E exit=$rc; artifacts: $ARTIFACT_DIR"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
bash "$ROOT_DIR/scripts/local-e2e/cleanup-stopped.sh"
# Privileged is needed for the nested daemon/Kind. It is intentionally given
# no host mounts or published ports. Bound resource use on shared laptops.
mkdir "$ARTIFACT_DIR/tools-context"
cp "$ROOT_DIR/.mise.toml" "$ARTIFACT_DIR/tools-context/.mise.toml"
cp "$ROOT_DIR/scripts/local-e2e/Dockerfile" "$ARTIFACT_DIR/tools-context/Dockerfile"
cp "$ROOT_DIR/scripts/local-e2e/ttl-entrypoint.sh" "$ARTIFACT_DIR/tools-context/ttl-entrypoint.sh"
docker build --iidfile "$ARTIFACT_DIR/tools-image-id" "$ARTIFACT_DIR/tools-context"
TOOLS_IMAGE="$(cat "$ARTIFACT_DIR/tools-image-id")"
docker run -d --privileged --name "$CONTAINER" \
  --label db-runbooks.local-e2e=true \
  --cpus "${LOCAL_E2E_CPUS:-4}" --memory "${LOCAL_E2E_MEMORY:-4g}" \
  --memory-swap "${LOCAL_E2E_MEMORY:-4g}" \
  -e LOCAL_E2E_MAX_SECONDS="${LOCAL_E2E_MAX_SECONDS:-3600}" \
  -e DOCKER_TLS_CERTDIR= "$TOOLS_IMAGE" \
  dockerd --host=unix:///var/run/docker.sock >"$ARTIFACT_DIR/container-id"
created=true
echo "Isolated container: $CONTAINER; test: $TEST_FILE; artifacts: $ARTIFACT_DIR"
# Diagnose daemon startup separately from copying the worktree or running Bats.
ready=false
for ((attempt=0; attempt<30; attempt++)); do
  if docker exec "$CONTAINER" timeout 5 docker info >/dev/null 2>&1; then
    ready=true
    break
  fi
  [[ "$(docker inspect "$CONTAINER" --format '{{.State.Running}}')" == true ]] || break
  sleep 1
done
[[ "$ready" == true ]] || { echo 'Isolated Docker daemon failed to become ready; see daemon.log.' >&2; exit 1; }
# Copy the actual worktree, including new files, without git metadata, runtime
# credentials, or local helpers/tool caches. Never bind-mount the host socket.
tar -C "$ROOT_DIR" --exclude=.git --exclude=tests/test_helper/bats-support \
  --exclude=tests/test_helper/bats-assert --exclude=tests/test_helper/bats-mock \
  --exclude=runtime-values.yaml -cf - . \
  | docker exec -i "$CONTAINER" sh -c 'mkdir -p /workspace; tar -xf - -C /workspace'
docker exec -e DOCKER_HOST=unix:///var/run/docker.sock "$CONTAINER" \
  bash /workspace/scripts/local-e2e/inside.sh "$TEST_FILE" 2>&1 | tee "$ARTIFACT_DIR/run.log" &
# Waiting on an async job lets INT/TERM traps run immediately rather than
# waiting for the foreground docker exec pipeline to finish.
wait "$!"
