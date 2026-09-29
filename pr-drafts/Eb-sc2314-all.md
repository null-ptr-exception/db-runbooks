<!-- branch: claude/tender-pascal-n9fh1d-eb-sc2314-all
     title:  test: make last-line negated greps robust and gate all SC2314
     merge first: #115, #116, #117, #119, then the F and E-a PRs; then rebase onto main -->

Part of #108.

A `! grep` that is the last command of a test fails the test only while it stays last; a line added after it silences it (note-level SC2314). tests/unit has 22 such sites. All 22 are now `run ! grep`; each is still the last line of its test. Seven files use a run flag for the first time and get `bats_require_minimum_version 1.5.0`. A third ShellCheck invocation gates SC2314 at any severity: `--severity=style --include=SC2314 -x`.

No behaviour change.

## Verify

```bash
git ls-files -z -- '*.bats' | xargs -0 shellcheck --severity=style --include=SC2314 -x -f gcc | wc -l   # 0.10.0
```
Before: 22. After: 0.

`bats --recursive tests/unit` (1.13.0): 589 ok, 0 not ok, 0 BW02.

Mutation per site: `grep() { return 0; }` before the assertion, `unset -f grep` after it.

| Form | grep matches, a line follows |
|---|---|
| old `! grep` | 22/22 ok |
| new `run ! grep` | 22/22 not ok at the assertion |

The CI step body under `bash -e`:

| Change | rc |
|---|---|
| none | 0 |
| `local-e2e/cleanup.bats:25` back to a test-final `! grep` | 123 (`SC2314 (style)`) |
| same change, stage a's step | 0 |
| pathspec `'*.bats'` → `'*.bats-nomatch'` | 1 |

Not covered: other style/info/warning findings in `*.bats` stay ungated.
