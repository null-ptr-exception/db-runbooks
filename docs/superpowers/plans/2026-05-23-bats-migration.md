# BATS Test Framework Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the manually crafted shell-script test harness with BATS (bats-core + bats-support + bats-assert), organized as directory-per-suite with self-contained test cases.

**Architecture:** A shared helper (`tests/test_helper/common_setup.bash`) provides `common_setup`, `http_post`, and `wait_for_task`. Each suite is a directory (`tests/common/`, `tests/mariadb/`, `tests/mongodb/`) containing `.bats` files — one per operation. `scripts/install-bats-libs.sh` handles bats-support/bats-assert installation. CI installs bats via apt.

**Tech Stack:** BATS (bats-core), bats-support, bats-assert, jq, curl, kubectl

**Spec:** `docs/superpowers/specs/2026-05-23-bats-migration-design.md`

---

### Task 1: Install script and .gitignore

**Files:**
- Create: `scripts/install-bats-libs.sh`
- Modify: `.gitignore`

- [ ] **Step 1: Create `scripts/install-bats-libs.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
TARGET="$(cd "$(dirname "$0")/../tests/test_helper" && pwd)"
for lib in bats-support bats-assert; do
  if [ ! -d "${TARGET}/${lib}" ]; then
    git clone --depth 1 "https://github.com/bats-core/${lib}.git" "${TARGET}/${lib}"
  fi
done
```

Make it executable:

```bash
chmod +x scripts/install-bats-libs.sh
```

- [ ] **Step 2: Add .gitignore entries**

Append to `.gitignore`:

```
tests/test_helper/bats-support/
tests/test_helper/bats-assert/
```

- [ ] **Step 3: Run the install script to verify it works**

```bash
mkdir -p tests/test_helper
scripts/install-bats-libs.sh
```

Expected: `tests/test_helper/bats-support/` and `tests/test_helper/bats-assert/` directories exist. Run again to verify idempotency — should produce no output.

- [ ] **Step 4: Commit**

```bash
git add scripts/install-bats-libs.sh .gitignore
git commit -m "build: add bats-support/bats-assert install script"
```

---

### Task 2: Shared test helper

**Files:**
- Create: `tests/test_helper/common_setup.bash`

This file provides all shared functions used by every `.bats` file. No `.bats` files exist yet — we verify it loads correctly in Task 3.

- [ ] **Step 1: Create `tests/test_helper/common_setup.bash`**

```bash
#!/usr/bin/env bash

# Load bats helper libraries
HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
load "${HELPER_DIR}/bats-support/load.bash"
load "${HELPER_DIR}/bats-assert/load.bash"

# ---------------------------------------------------------------------------
# common_setup — call from setup_file in each .bats file
#
# Sources .env, sets URL variables, optionally creates a TOKEN.
# Usage:
#   setup_file() { common_setup; }                   # no token
#   setup_file() { common_setup --create-token; }    # with token
# ---------------------------------------------------------------------------
common_setup() {
  ROOT_DIR="$(cd "${HELPER_DIR}/../.." && pwd)"
  export ROOT_DIR

  # shellcheck source=/dev/null
  source "${ROOT_DIR}/.env"

  export MARIADB_AQSH_URL="http://${CLUSTER_DBS_IP}:30081"
  export MONGODB_AQSH_URL="http://${CLUSTER_DBS_IP}:30082"
  export FEDAUTH_URL="http://${CLUSTER_AUTH_IP}:30080"
  export CLUSTER_DBS_IP

  if [[ "${1:-}" == "--create-token" ]]; then
    export TOKEN
    TOKEN=$(kubectl --context kind-cluster-apps -n app-a create token test-client --duration=10m)
  fi
}

# ---------------------------------------------------------------------------
# http_post <url> <json_body>
#
# Sets HTTP_CODE and HTTP_BODY (exported so @test blocks can read them).
# ---------------------------------------------------------------------------
http_post() {
  local url="$1" body="$2"
  local response
  response=$(curl -s -w '\n%{http_code}' \
    -X POST "$url" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body")

  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

# ---------------------------------------------------------------------------
# wait_for_task <base_url> <task_id> [max_wait_seconds]
#
# Polls GET <base_url>/tasks/<task_id> until status is completed or failed.
# Sets TASK_RESPONSE to the final JSON body.
# Returns 0 on completed, 1 on failed/timeout.
# ---------------------------------------------------------------------------
wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-300}"
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(curl -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${base_url}/tasks/${task_id}")
    export TASK_RESPONSE

    status=$(echo "$TASK_RESPONSE" | jq -r '.status' 2>/dev/null || true)

    if [[ "$status" == "completed" ]]; then
      return 0
    elif [[ "$status" == "failed" ]]; then
      echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2
      return 1
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}
```

- [ ] **Step 2: Verify the file parses without syntax errors**

```bash
bash -n tests/test_helper/common_setup.bash
```

Expected: no output (clean parse).

- [ ] **Step 3: Commit**

```bash
git add tests/test_helper/common_setup.bash
git commit -m "feat: add shared BATS test helper with common_setup, http_post, wait_for_task"
```

---

### Task 3: common/auth.bats

**Files:**
- Create: `tests/common/auth.bats`
- Reference: `tests/common/test.sh:16-48` (original tests 1, 2a, 2b)

- [ ] **Step 1: Create `tests/common/auth.bats`**

```bash
setup_file() {
  load '../test_helper/common_setup'
  common_setup
}

@test "fedauth health check returns 200" {
  run curl -s -o /dev/null -w '%{http_code}' "${FEDAUTH_URL}/health"
  assert_output "200"
}

@test "unauthenticated request to aqsh-mariadb returns 401" {
  run curl -s -o /dev/null -w '%{http_code}' "${MARIADB_AQSH_URL}/health"
  assert_output "401"
}

@test "unauthenticated request to aqsh-mongodb returns 401" {
  run curl -s -o /dev/null -w '%{http_code}' "${MONGODB_AQSH_URL}/health"
  assert_output "401"
}
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n tests/common/auth.bats
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add tests/common/auth.bats
git commit -m "test: add auth.bats for fedauth health and unauthenticated rejection"
```

---

### Task 4: common/hello_task.bats

**Files:**
- Create: `tests/common/hello_task.bats`
- Reference: `tests/common/test.sh:50-146` (original tests 3-5b)

- [ ] **Step 1: Create `tests/common/hello_task.bats`**

```bash
setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
}

@test "hello task completes with expected logs via aqsh-mariadb" {
  http_post "${MARIADB_AQSH_URL}/tasks/common%2Fhello" '{"name": "World"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')

  wait_for_task "$MARIADB_AQSH_URL" "$task_id" 30

  # Verify logs contain expected output
  local logs
  logs=$(curl -s -m 5 \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: text/event-stream" \
    "${MARIADB_AQSH_URL}/tasks/${task_id}/logs?follow=false" 2>/dev/null || true)

  echo "$logs"  # visible on failure
  [[ "$logs" == *"Hello, World!"* ]]
}

@test "hello task submits via aqsh-mongodb" {
  http_post "${MONGODB_AQSH_URL}/tasks/common%2Fhello" '{"name": "World"}'
  assert_equal "$HTTP_CODE" "202"
}
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n tests/common/hello_task.bats
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add tests/common/hello_task.bats
git commit -m "test: add hello_task.bats for task submission, polling, and log verification"
```

---

### Task 5: common/in_pod.bats

**Files:**
- Create: `tests/common/in_pod.bats`
- Reference: `tests/common/test.sh:148-197` (original test 6)

- [ ] **Step 1: Create `tests/common/in_pod.bats`**

```bash
setup_file() {
  load '../test_helper/common_setup'
  common_setup

  # Wait for test-client pod to be ready
  if ! kubectl --context kind-cluster-apps -n app-a wait \
    --for=condition=Ready pod -l app=test-client --timeout=120s >/dev/null 2>&1; then
    echo "test-client pod not ready within 120s" >&2
    return 1
  fi

  TEST_POD=$(kubectl --context kind-cluster-apps -n app-a \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  export TEST_POD
}

@test "in-pod request to aqsh-mariadb returns 202" {
  run kubectl --context kind-cluster-apps -n app-a exec "$TEST_POD" -- \
    sh -c 'curl -s -o /dev/null -w "%{http_code}" \
      -X POST "http://'"${CLUSTER_DBS_IP}"':30081/tasks/common%2Fhello" \
      -H "Authorization: Bearer $(cat /var/run/secrets/tokens/token)" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"from-pod\"}"'
  assert_output "202"
}

@test "in-pod request to aqsh-mongodb returns 202" {
  run kubectl --context kind-cluster-apps -n app-a exec "$TEST_POD" -- \
    sh -c 'curl -s -o /dev/null -w "%{http_code}" \
      -X POST "http://'"${CLUSTER_DBS_IP}"':30082/tasks/common%2Fhello" \
      -H "Authorization: Bearer $(cat /var/run/secrets/tokens/token)" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"from-pod\"}"'
  assert_output "202"
}
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n tests/common/in_pod.bats
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add tests/common/in_pod.bats
git commit -m "test: add in_pod.bats for cross-cluster in-pod request tests"
```

---

### Task 6: mariadb/restart.bats

**Files:**
- Create: `tests/mariadb/restart.bats`
- Reference: `tests/mariadb/test.sh` (original tests 7-9)

- [ ] **Step 1: Create `tests/mariadb/restart.bats`**

```bash
setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
}

@test "restart task completes successfully" {
  http_post "${MARIADB_AQSH_URL}/tasks/restart" '{"namespace": "mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"
}

@test "restart advances StatefulSet generation and all replicas ready" {
  local before_generation
  before_generation=$(kubectl --context kind-cluster-dbs -n mariadb-1 \
    get statefulset mariadb -o jsonpath='{.status.observedGeneration}')

  http_post "${MARIADB_AQSH_URL}/tasks/restart" '{"namespace": "mariadb-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MARIADB_AQSH_URL" "$task_id"

  # Wait for pods to be ready after restart
  kubectl --context kind-cluster-dbs -n mariadb-1 wait pod \
    -l app.kubernetes.io/name=mariadb \
    --for=condition=Ready --timeout=120s >/dev/null 2>&1

  local after_generation ready replicas
  after_generation=$(kubectl --context kind-cluster-dbs -n mariadb-1 \
    get statefulset mariadb -o jsonpath='{.status.observedGeneration}')
  ready=$(kubectl --context kind-cluster-dbs -n mariadb-1 \
    get statefulset mariadb -o jsonpath='{.status.readyReplicas}')
  replicas=$(kubectl --context kind-cluster-dbs -n mariadb-1 \
    get statefulset mariadb -o jsonpath='{.status.replicas}')

  echo "generation: ${before_generation} → ${after_generation}, ready: ${ready}/${replicas}"
  assert [ "$after_generation" -gt "$before_generation" ]
  assert_equal "$ready" "$replicas"
  assert [ "$ready" != "0" ]
}
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n tests/mariadb/restart.bats
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add tests/mariadb/restart.bats
git commit -m "test: add mariadb/restart.bats for restart lifecycle tests"
```

---

### Task 7: mongodb/sanity_check.bats

**Files:**
- Create: `tests/mongodb/sanity_check.bats`
- Reference: `tests/mongodb/test.sh:1-70` (original test 10)

- [ ] **Step 1: Create `tests/mongodb/sanity_check.bats`**

```bash
setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
}

@test "sanity-check completes without critical issues" {
  http_post "${MONGODB_AQSH_URL}/tasks/sanity-check" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  local result_status pass_count warn_count fail_count
  result_status=$(echo "$TASK_RESPONSE" | jq -r '.result.status // "unknown"')
  pass_count=$(echo "$TASK_RESPONSE" | jq -r '.result.pass // 0')
  warn_count=$(echo "$TASK_RESPONSE" | jq -r '.result.warn // 0')
  fail_count=$(echo "$TASK_RESPONSE" | jq -r '.result.fail // 0')

  echo "sanity result: status=${result_status} pass=${pass_count} warn=${warn_count} fail=${fail_count}"
  assert [ "$result_status" != "critical" ]
}
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n tests/mongodb/sanity_check.bats
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add tests/mongodb/sanity_check.bats
git commit -m "test: add mongodb/sanity_check.bats for sanity-check lifecycle test"
```

---

### Task 8: mongodb/restart.bats

**Files:**
- Create: `tests/mongodb/restart.bats`
- Reference: `tests/mongodb/test.sh:72-149` (original tests 11-12)

- [ ] **Step 1: Create `tests/mongodb/restart.bats`**

```bash
setup_file() {
  load '../test_helper/common_setup'
  common_setup --create-token
}

@test "restart task completes successfully" {
  http_post "${MONGODB_AQSH_URL}/tasks/restart" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"
}

@test "restart advances StatefulSet generation and all replicas ready" {
  local before_generation
  before_generation=$(kubectl --context kind-cluster-dbs -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.status.observedGeneration}')

  http_post "${MONGODB_AQSH_URL}/tasks/restart" '{"namespace": "mongo-1"}'
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$MONGODB_AQSH_URL" "$task_id"

  # Wait for pods to be ready after restart
  kubectl --context kind-cluster-dbs -n mongo-1 wait pod \
    -l app=mongodb \
    --for=condition=Ready --timeout=120s >/dev/null 2>&1

  local after_generation ready replicas
  after_generation=$(kubectl --context kind-cluster-dbs -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.status.observedGeneration}')
  ready=$(kubectl --context kind-cluster-dbs -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.status.readyReplicas}')
  replicas=$(kubectl --context kind-cluster-dbs -n mongo-1 \
    get statefulset mongodb -o jsonpath='{.status.replicas}')

  echo "generation: ${before_generation} → ${after_generation}, ready: ${ready}/${replicas}"
  assert [ "$after_generation" -gt "$before_generation" ]
  assert_equal "$ready" "$replicas"
  assert [ "$ready" != "0" ]
}
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n tests/mongodb/restart.bats
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add tests/mongodb/restart.bats
git commit -m "test: add mongodb/restart.bats for restart lifecycle tests"
```

---

### Task 9: Update scripts/test.sh

**Files:**
- Modify: `scripts/test.sh`

Replace the entire file. The old version sourced shell scripts and tracked pass/fail counters. The new version just runs bats.

- [ ] **Step 1: Rewrite `scripts/test.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Install helper libs if not present
"${SCRIPT_DIR}/install-bats-libs.sh"

bats --recursive "${ROOT_DIR}/tests/"
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n scripts/test.sh
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add scripts/test.sh
git commit -m "refactor: rewrite test.sh to run bats"
```

---

### Task 10: Update CI workflow

**Files:**
- Modify: `.github/workflows/ci.yaml`

- [ ] **Step 1: Add `bats` to the lint job's apt-get install**

In the `lint` job, add `bats` to the install line so ShellCheck can resolve `load` when linting `.bats` files (optional but avoids warnings):

Change:
```yaml
          sudo apt-get install -y shellcheck python3-pip
```
To:
```yaml
          sudo apt-get install -y shellcheck python3-pip bats
```

- [ ] **Step 2: Add `bats` to the integration job's apt-get install**

In the `Install integration dependencies` step, change:

```yaml
          sudo apt-get install -y gettext-base jq
```

To:

```yaml
          sudo apt-get install -y gettext-base jq bats
```

- [ ] **Step 3: Add bats-libs install step before integration tests**

Add a new step after "Deploy sandbox" and before "Run integration tests":

```yaml
      - name: Install BATS helper libraries
        run: ./scripts/install-bats-libs.sh
```

- [ ] **Step 4: Simplify the integration test step**

Replace the existing `Run integration tests` step and remove the `Verify integration result` step. BATS exit code is sufficient.

Replace:
```yaml
      - name: Run integration tests
        id: integration_tests
        shell: bash
        run: |
          set +e
          LOG_FILE="${RUNNER_TEMP}/integration-test.log"

          ./scripts/test.sh | tee "${LOG_FILE}"
          TEST_EXIT=${PIPESTATUS[0]}

          SUMMARY_LINE="$(grep -E '=== Results: [0-9]+ passed, [0-9]+ failed ===' "${LOG_FILE}" | tail -n 1 || true)"
          if [ -n "${SUMMARY_LINE}" ]; then
            FAILED_COUNT="$(echo "${SUMMARY_LINE}" | sed -E 's/=== Results: [0-9]+ passed, ([0-9]+) failed ===/\1/')"
            SUMMARY_FOUND=true
          else
            FAILED_COUNT=""
            SUMMARY_FOUND=false
          fi

          {
            echo "test_exit=${TEST_EXIT}"
            echo "summary_found=${SUMMARY_FOUND}"
            echo "failed_count=${FAILED_COUNT}"
          } >> "${GITHUB_OUTPUT}"
```

With:
```yaml
      - name: Run integration tests
        run: ./scripts/test.sh
```

Remove the entire `Verify integration result` step (it parsed the old summary format which no longer exists).

- [ ] **Step 5: Verify YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yaml'))"
```

Expected: no output (clean parse).

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/ci.yaml
git commit -m "build: update CI to use bats for integration tests"
```

---

### Task 11: Remove old test scripts

**Files:**
- Delete: `tests/common/test.sh`
- Delete: `tests/mariadb/test.sh`
- Delete: `tests/mongodb/test.sh`

- [ ] **Step 1: Delete old test scripts**

```bash
rm tests/common/test.sh tests/mariadb/test.sh tests/mongodb/test.sh
```

- [ ] **Step 2: Verify no references remain**

```bash
grep -r 'source.*tests/' scripts/ .github/ || echo "No references found"
```

Expected: "No references found" (the old `scripts/test.sh` that sourced these was replaced in Task 9).

- [ ] **Step 3: Commit**

```bash
git add -u tests/
git commit -m "chore: remove old shell-script test harness"
```

---

### Task 12: Verify ShellCheck passes on all new files

**Files:** (read-only verification)

- [ ] **Step 1: Run ShellCheck on all .sh and .bats files**

```bash
find . -type f \( -name '*.sh' -o -name '*.bats' \) -not -path './.git/*' -not -path './tests/test_helper/bats-*' -print0 \
  | xargs -0 --no-run-if-empty shellcheck --severity=warning -x
```

Expected: no warnings. If there are warnings, fix them in the relevant files and amend the previous commit for that file.

- [ ] **Step 2: Commit any fixes**

Only if step 1 produced warnings:

```bash
git add -u
git commit -m "fix: resolve shellcheck warnings in bats test files"
```
