<!-- branch: claude/tender-pascal-n9fh1d-eb-sc2314-all
     title:  test: make last-line negated greps robust and gate all SC2314
     merge first: F and E-a; then rebase onto main and replace #F/#EA with their PR numbers -->

Part of #108. Stacked on #F and #EA; merge those first.

A `! grep` that is the last command of a test fails the test only while it stays last; a line added after it silences it (note-level SC2314). tests/unit has 20 such sites. All 20 are now `run ! grep`; each is still the last line of its test. Six files use a run flag for the first time and get `bats_require_minimum_version 1.5.0`. A third ShellCheck invocation gates SC2314 at any severity: `--severity=style --include=SC2314 -x`.

No behaviour change.

## Verify

```bash
git ls-files -z -- '*.bats' | xargs -0 shellcheck --severity=style --include=SC2314 -x -f gcc | wc -l   # 0.10.0
```
main: 20. This branch: 0.

`bats --recursive tests/unit` (1.13.0): BW02 0; pass/fail identical to main.

Mutation per site: `grep() { return 0; }` before the assertion, `unset -f grep` after it.

| Form | Result |
|---|---|
| main `! grep` | 20/20 ok |
| this branch `run ! grep` | 20/20 not ok at the assertion |

The CI step body under `bash -e`:

| Change | rc |
|---|---|
| none | 0 |
| `local-e2e/cleanup.bats:25` back to a test-final `! grep` | 123 (`SC2314 (style)`) |
| same site on the stage a step | 0 |

Not covered: other style/info findings in `*.bats` stay ungated.
