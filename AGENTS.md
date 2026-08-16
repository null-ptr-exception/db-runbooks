# AGENTS.md — entry point for coding agents

Vendor-neutral entry point. Every coding agent working in this repository should
read the two documents below; nothing about them is specific to one tool.

## 1. The project guide — read first, always

**[`CLAUDE.md`](CLAUDE.md)** is the project guide: cluster contexts, namespaces,
architecture, ports, and the small set of rules whose violation is expensive and
which nothing automates.

The filename is historical, not a statement of scope. Roughly 120 references
throughout the codebase point at it by name (task YAML comments, script headers,
per-task docs), so renaming it is a separate, mechanical change rather than
something to do in passing. It is the project guide for every agent.

> ⛔ The single most expensive rule in it: **two Kind clusters are live at the
> same time, so every `kubectl` command needs `--context`.** Nothing enforces
> this — no hook, no lint, no test.

Claude Code loads `CLAUDE.md` automatically. Tools that read this file instead
should read it explicitly before making changes.

## 2. Adding or changing an aqsh task

**[`docs/agent/task-authoring.md`](docs/agent/task-authoring.md)** — the decision
procedure for which layer a value belongs in (task input vs internal config vs
auto-detect vs hardcoded fallback), the `*_DEFAULT` naming rule, fail-soft
detection, RBAC `resourceNames` coupling, and the gating/result-code contract.

A task input is a **public API promise**: once it ships you can add fields but
never remove one. Read that document before editing any of:

<!-- TRIGGER-GLOBS-START -->
- `aqsh-tasks/tasks-mariadb.yaml`
- `aqsh-tasks/tasks-mongodb.yaml`
- `aqsh-tasks/config/*.env`
- `aqsh-tasks/scripts/**`
- `tests/chart/templates/*-rbac.yaml`
<!-- TRIGGER-GLOBS-END -->

## Before you push

Three checks, seconds each, that catch most CI failures:

```bash
find . -type f -name '*.sh' -print0 | xargs -0 --no-run-if-empty shellcheck --severity=warning -x
bats --recursive tests/unit
docker run --rm -i hadolint/hadolint hadolint --ignore DL3008 --ignore DL4006 - < Dockerfile
```

The integration suites need real Kind clusters and cost 30–75 minutes per CI
cycle. Not everything outside those three commands does: the image build is
another cheap local check, and `yamllint`/`actionlint` have config files that
nothing in this repo ever runs.
Full inventory of what is and isn't enforced:
[`docs/internal/quality-gates.md`](docs/internal/quality-gates.md).

## How this repository routes agent instructions

| Layer | File | Loaded |
|-------|------|--------|
| Always-on project guide | `CLAUDE.md` | Automatically by Claude Code; explicitly by agents reading this file |
| Task-authoring procedure | `docs/agent/task-authoring.md` | On demand — this is the source of truth, not a copy |
| Claude Code adapter | `.claude/skills/task-authoring/SKILL.md` | By Claude when its `description` matches the work |

Adapters **point at** `docs/agent/task-authoring.md` rather than copying it, so
there is exactly one version of the content. What each adapter does carry is its
own trigger metadata — the glob list above, and the `description` in the Claude
skill. That is a registry with two copies, so
`tests/unit/aqsh/task_authoring_triggers.bats` asserts they stay identical.

**Adding an adapter for another tool** (Cursor `.cursor/rules/*.mdc` with
`globs:`, Copilot `.github/instructions/*.instructions.md` with `applyTo:`):
copy the glob block between the `TRIGGER-GLOBS` markers, point the body at
`docs/agent/task-authoring.md`, and extend the drift test to cover the new file.
Don't add an adapter for a tool nobody here uses — an unused adapter is a
registry entry that will drift unnoticed.

> **Honest limitation:** tools with no trigger mechanism (this file is always
> loaded in full) get a pointer, not on-demand loading. They must choose to read
> `docs/agent/task-authoring.md`. Claude Code, Cursor, and Copilot can load it
> only when it is relevant. That gap is a property of the tools, not something
> this layout can close.
