@AGENTS.md

<!-- The project guide lives in AGENTS.md so that every coding agent reads the
     same file, not just Claude Code. The line above is a CLAUDE.md import:
     Claude expands it at session start, so nothing is lost by the move.
     Keep Claude-specific instructions below this comment, never above it. -->

## Claude Code

- `.claude/skills/task-authoring/` is a thin adapter over
  [`docs/agent/task-authoring.md`](docs/agent/task-authoring.md). It carries the
  trigger `description:` and nothing else — edit the guidance in the neutral
  file, not in the adapter.
- Adding a trigger path means editing it in three places (the neutral doc,
  `AGENTS.md`, and the adapter's `description:`);
  `tests/unit/aqsh/task_authoring_triggers.bats` fails if they disagree.
