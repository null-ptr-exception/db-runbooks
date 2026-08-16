# Quality gates — the full inventory

Reference for the summary in `AGENTS.md` → *Quality Gates*. Read `AGENTS.md`
for the four owner types and the three commands worth running before every
push. Read this when you need the complete picture: exact commands, CI job
costs, and what is not covered at all.

The expensive mistake this document exists to prevent: believing something is
enforced when it isn't. You skip it, push, and find out 30–75 minutes later —
or never, because nothing runs it.

## Owner types

| Owner | Meaning | What you must do |
|-------|---------|------------------|
| 🔧 **hook-enforced** | Blocked mechanically at commit/push/tool-call time | Don't re-do it by hand. **Currently empty** — no git hooks, no pre-commit, no PreToolUse guards |
| ⚙️ **CI-only** | Runs only in GitHub Actions; nothing local blocks you | Run it locally before pushing, or pay a full CI cycle per mistake |
| 🧠 **convention** | Written down here or in `docs/`, no automation | Apply it deliberately; nothing will stop you |
| 👁️ **unenforced** | Config exists but nothing invokes it, or a convention with no reader | Highest risk. Assume nobody is checking |

## ⚙️ CI-only — cheap, run locally first

Everything in the `lint` job is seconds locally and is where most CI failures
come from. There is no `make lint` target yet; run them directly.

| Check | Local command | Cost |
|-------|---------------|------|
| ShellCheck | `find . -type f -name '*.sh' -print0 \| xargs -0 --no-run-if-empty shellcheck --severity=warning -x` | seconds |
| Bats unit tests | `bats --recursive tests/unit` | ~seconds |
| Hadolint | `docker run --rm -i hadolint/hadolint hadolint --ignore DL3008 --ignore DL4006 - < Dockerfile` | seconds |
| Image build | `docker build -t db-runbooks:ci .` | ~1 min |

**ShellCheck.** `-x` plus `.shellcheckrc`'s `external-sources=true` are both
required — `lib/*.sh` is sourced at runtime, not inlined, so without them the
sourced definitions are invisible and real findings are missed.

⚠️ `scripts/preflight.sh` does **not** install shellcheck unless
`PREFLIGHT_INSTALL_SHELLCHECK=1` is set; CI apt-installs it as a fallback. A
green local run can therefore mean "never actually ran". Check
`command -v shellcheck` before trusting a clean result.

**Hadolint.** CI uses `hadolint/hadolint-action`; the `--ignore` flags above
match its `ignore:` list, so keep them in sync if CI's list changes.

**Bats unit tests.** Mocked `kubectl`, no cluster needed — the only fast
correctness signal in the repo. It includes the task input-surface snapshots
(`tests/unit/aqsh/*.bats`), which are a deliberate tripwire on the public API:

- `mariadb_public_inputs.bats` pins the exact ordered `input:` list per task
- `task_inputs.bats` forbids `context` / `K8S_CONTEXT` as a task input on
  either gateway, while asserting `lib/k8s.sh` keeps it for local CLI use
- `mariadb_namespace_patterns.bats` covers the `pattern:` constraints

⛔ A red snapshot is a question, not a chore. Re-justify the field against the
layer decision ([`task-authoring.md`](../agent/task-authoring.md)) **before**
updating the snapshot.

It also carries the registry drift check —
`resolution_registry_drift.bats` asserts the namespaced task families in
`tasks-*.yaml` are exactly the families listed in
[`resolution-tiers.md`](resolution-tiers.md), in both directions (a new family
with no row, and a row for a family that no longer exists). Exact set equality
with no exemption list, because an allowlist is itself a registry and would
drift the same way. It runs in `lint`, not a shard, so it cannot fall through
the `mongodb` shard-list gap below.

And `task_authoring_triggers.bats` pins the trigger metadata that the agent
adapters must each carry in their own format — the glob list in
[`task-authoring.md`](../agent/task-authoring.md) and `AGENTS.md`, and the
`description:` in the Claude skill. The guidance body itself is a single file
that adapters point at, so only the triggers can drift; this catches that.

## ⚙️ CI-only — expensive, don't discover failures here

These integration suites need real Kind clusters and cannot be meaningfully
shortened. The timeouts are the worst-case cost of one wrong push. (`tests/unit`
is not here — it is mocked and belongs to the cheap table above.)

| Suite | Local command | CI timeout |
|-------|---------------|-----------:|
| `tests/mariadb` | `bats tests/mariadb/` | 30 min |
| `tests/mariadb-legacy` | `bats tests/mariadb-legacy/` | 60 min |
| `tests/mongodb` (4 shards) | `bats tests/mongodb/` | 75 min |
| `tests/infra` | `bats tests/infra/` | 30 min |
| `tests/aqsh` | `bats tests/aqsh/` | 30 min |

⚠️ **The `mongodb` job is sharded by filename in `ci.yaml` and nothing
auto-discovers new files.** A new `tests/mongodb/*.bats` that isn't added to a
shard list silently never runs in CI. The shards are `core`, `recovery`, `pbm`,
and `reconfig`; each pays the full ~15–20 min `setup_suite` cost, which is why
splitting below the file level would not help.

⚠️ The self-hosted runners are persistent, and teardown swallows its own
failures (`|| true`). The `mongodb` job force-deletes `cluster-a`/`cluster-b`/
`registry` before creating anything for exactly this reason; a cancelled run can
otherwise leave stale clusters — including stale Helm-deployed ClusterRoles —
for the next run to silently reuse.

## 👁️ Unenforced — nobody is checking these

| Item | Status |
|------|--------|
| `.yamllint.yaml` | Config exists; **no CI job, Makefile target, or hook invokes yamllint**. Run `yamllint .` by hand if you care |
| `actionlint.yaml` | Same — config exists, actionlint is never run |
| `--context` on every `kubectl` | Convention, zero enforcement. Two Kind clusters are live at once; the wrong context is real damage, not a lint nit |
| Task ↔ script existence | Nothing checks that a `script:` in `tasks-*.yaml` points at a file that exists |
| Task ↔ docs drift | Nothing checks that a new task got a `docs/<db>/*.md` page or a README table row |
| Stable reason codes | Documented as stable, but no test pins the strings. Renaming one is a silent breaking change for callers |

The first four are the obvious candidates for the first hooks this repo adds:
local cost is seconds, they trip often, and each can be scoped with a `files:`
pattern.

## 🧠 Conventions with no automation

| Convention | Where |
|------------|-------|
| Which layer a value belongs to | `AGENTS.md` → *Configuration Layers*; decision procedure in [`task-authoring.md`](../agent/task-authoring.md) |
| How a tier resolves, per family | [`resolution-tiers.md`](resolution-tiers.md) |
| `--context` on every `kubectl` | `AGENTS.md` → *kubectl Contexts* |
