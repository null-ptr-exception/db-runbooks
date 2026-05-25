# BATS Test Framework Migration

Migrate the integration test suite from manually crafted shell scripts to BATS (Bash Automated Testing System) with bats-support and bats-assert.

## Goals

- Structured test cases with proper setup/teardown lifecycle
- TAP output and better failure reporting
- Eliminate duplicated polling logic and inconsistent patterns
- Each database type (mariadb, mongodb) gets its own expandable test suite

## File Structure

```
tests/
  test_helper/
    common_setup.bash       # Shared setup: load libs, source .env, URLs, TOKEN, helpers
    bats-support/           # git-cloned, .gitignored
    bats-assert/            # git-cloned, .gitignored
  common/
    auth.bats               # Federated auth health + unauthenticated rejection
    hello_task.bats         # Hello task lifecycle (submit, poll, logs)
    in_pod.bats             # Cross-cluster in-pod requests
  mariadb/
    restart.bats            # Restart task lifecycle (submit, poll, verify)
  mongodb/
    sanity_check.bats       # Sanity-check task lifecycle
    restart.bats            # Restart task lifecycle (submit, poll, verify)
scripts/
  install-bats-libs.sh      # Clone bats-support + bats-assert into tests/test_helper/
  test.sh                   # Simplified: runs `bats tests/`
```

Each suite is a directory. New operations are added as new `.bats` files — no existing files need modification.

## Shared Helpers (common_setup.bash)

### Setup

`common_setup()` is called from each .bats file's `setup_file`. It:

1. Sources `.env` for cluster IPs
2. Sets `MARIADB_AQSH_URL`, `MONGODB_AQSH_URL`, `FEDAUTH_URL`
3. Creates `TOKEN` via `kubectl --context kind-cluster-apps -n app-a create token test-client --duration=10m`
4. Exports all of the above as `BATS_*` variables so they survive across tests in the file

### wait_for_task

Shared polling function replacing 3 duplicated loops:

```bash
wait_for_task <base_url> <task_id> [max_wait_seconds]
```

- Polls `GET <base_url>/tasks/<task_id>` with Bearer TOKEN
- Returns 0 on `completed`, 1 on `failed` or timeout
- Stores the final JSON response in `$TASK_RESPONSE`
- Default timeout: 300s
- Polls every 5s (not every 1s)

### http_post

Helper to POST and capture both body and HTTP code:

```bash
http_post <url> <json_body>
```

Sets `$HTTP_CODE` and `$HTTP_BODY`. Uses `jq` exclusively (no python3).

## Test Suites

### common/ — Infrastructure Tests

#### auth.bats

```
setup_file    → common_setup (no TOKEN needed for these)
@test "fedauth health check returns 200"
@test "unauthenticated request to aqsh-mariadb returns 401"
@test "unauthenticated request to aqsh-mongodb returns 401"
```

#### hello_task.bats

```
setup_file    → common_setup, create TOKEN
@test "hello task completes with expected logs via aqsh-mariadb"
@test "hello task submits via aqsh-mongodb"
```

The mariadb hello test combines submission + polling + log verification — sequential steps in one scenario.

#### in_pod.bats

```
setup_file    → common_setup (TOKEN comes from projected volume inside pod)
@test "in-pod request to aqsh-mariadb returns 202"
@test "in-pod request to aqsh-mongodb returns 202"
```

### mariadb/ — MariaDB Test Suite

#### restart.bats

```
setup_file    → common_setup, create TOKEN

@test "restart task completes successfully"
  → submit restart, assert 202, poll until completed

@test "restart advances StatefulSet generation and all replicas ready"
  → record before-generation, submit restart, poll until completed,
    assert generation advanced, assert ready == replicas
```

Each test is self-contained — it performs its own submission, polling, and verification.
Shared helpers (`http_post`, `wait_for_task`) keep the boilerplate minimal.

Future files: `backup.bats`, `failover.bats`, etc.

### mongodb/ — MongoDB Test Suite

#### sanity_check.bats

```
setup_file    → common_setup, create TOKEN

@test "sanity-check completes without critical issues"
  → submit sanity-check, assert 202, poll until completed,
    assert result.status != "critical"
```

#### restart.bats

```
setup_file    → common_setup, create TOKEN

@test "restart task completes successfully"
  → submit restart, assert 202, poll until completed

@test "restart advances StatefulSet generation and all replicas ready"
  → record before-generation, submit restart, poll until completed,
    assert generation advanced, assert ready == replicas
```

Same self-contained pattern as mariadb/restart.bats.

## Test Independence

Each `@test` block owns its full lifecycle: setup, action, and verification. No test depends on another test having run first. This means some tests repeat work (e.g., both restart tests submit and poll), but each can be understood, run, and debugged in isolation.

## Dependencies and Installation

### bats-core

Installed via system package:
- CI: `apt-get install -y bats`
- Local: developer installs via their package manager

### bats-support + bats-assert

Installed via `scripts/install-bats-libs.sh`:

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

`.gitignore` entry:
```
tests/test_helper/bats-support/
tests/test_helper/bats-assert/
```

## CI Changes

Integration job in `.github/workflows/ci.yaml`:

1. Add `bats` to the `apt-get install` line
2. Add step: `Run scripts/install-bats-libs.sh`
3. Change test execution from `./scripts/test.sh` to `bats tests/` (or keep `scripts/test.sh` as a wrapper)
4. Remove summary-line parsing — BATS exit code is sufficient, TAP output is self-documenting

## scripts/test.sh

Simplified to:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Install helper libs if not present
"${SCRIPT_DIR}/install-bats-libs.sh"

bats --recursive "${ROOT_DIR}/tests/"
```

## Patterns Fixed in Migration

| Before | After |
|--------|-------|
| `python3 -c "import sys,json; ..."` | `jq` exclusively |
| Double curl (body + code separately) | Single curl with `-w '\n%{http_code}'` |
| `eval "$varname=\$output"` | Eliminated (no run_cmd needed) |
| Manual test numbering (Test 1, Test 7...) | Descriptive `@test` names |
| Manual pass/fail counters | BATS TAP output + bats-assert |
| Copy-pasted 300s polling loops | Shared `wait_for_task` helper |
