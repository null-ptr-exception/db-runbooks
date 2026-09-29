<!-- branch: claude/tender-pascal-n9fh1d-ea-bats-error-gate
     title:  ci: gate *.bats on ShellCheck errors
     merge first: #115, #116, #117, #119; then rebase onto main -->

Part of #108.

The lint job's ShellCheck step covers `*.sh` and `*.bash` only, so a mid-test `! cmd` in a `.bats` file (SC2314, error) reaches main unchecked. This adds a second invocation to the "Run ShellCheck" step: tracked `*.bats` at `--severity=error -x`, with the same pinned `$shellcheck` (#117) and the same fail-closed empty-match check. The warning-level pass is unchanged.

## Verify

The step's `run:` body, extracted from `ci.yaml` and run under `bash -e`:

| Change | rc | Output |
|---|---|---|
| none | 0 | `shellcheck 0.10.0` |
| `restore-in-place.bats:90` back to a mid-body `! grep` | 123 | `SC2314 (error): In Bats, ! does not cause a test failure.` |
| pathspec `'*.bats'` → `'*.bats-nomatch'` | 1 | `no *.bats files matched — refusing to report a vacuous pass` |

`actionlint` 1.7.12 and `yamllint .`: clean.

Not covered: 22 test-final `! grep` sites are note-level SC2314 and pass this gate; see the stage b PR.
