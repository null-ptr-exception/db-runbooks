<!-- branch: claude/tender-pascal-n9fh1d-f-bats-min-version
     title:  test: declare bats 1.5.0 where run flags are used
     merge first: nothing (based on main 7039bd3) -->

Part of #107.

bats prints BW02 for every `run` with a flag (`run !`, `run --separate-stderr`) unless the file declares a minimum version. This adds `bats_require_minimum_version 1.5.0` at the top level of the four unit files that use run flags. preflight installs bats 1.13.0; the function exists from 1.7.0. No e2e `.bats` file uses run flags.

No behaviour change.

## Verify

```bash
git ls-files '*.bats' | xargs grep -lE '^\s*run\s+(!|-)'
```
```
tests/unit/lib/logging.bats
tests/unit/local-e2e/isolation.bats
tests/unit/mariadb/logical-restore.bats
tests/unit/mariadb/restore-in-place.bats
```

`bats --recursive tests/unit` (1.13.0), 627 tests:

| | BW02 |
|---|---|
| main | 19 (logging 7, logical-restore 4, restore-in-place 6, isolation 2) |
| this branch | 0 |

Pass/fail is identical to main.

Raising the call to `99.0.0` in `isolation.bats` stops the file: `BATS_VERSION=1.13.0 does not meet required minimum 99.0.0`.

Not covered: files that start using run flags later need the same line.
