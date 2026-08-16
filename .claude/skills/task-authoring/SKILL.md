---
name: task-authoring
description: How to add or change an aqsh task in this repo — deciding which layer a value belongs to (task input vs internal config vs auto-detect vs hardcoded fallback), the *_DEFAULT naming rule, fail-soft detection, RBAC resourceNames coupling, and the gating/result-code contract. Use whenever editing aqsh-tasks/tasks-mariadb.yaml or aqsh-tasks/tasks-mongodb.yaml, adding or renaming an `input:` field, adding a *_DEFAULT setting to aqsh-tasks/config/*.env, writing a script under aqsh-tasks/scripts/, or touching tests/chart/templates/*-rbac.yaml. Also use when reviewing any diff that touches those files, when unsure whether a value should be caller-suppliable, or when introducing a new reason code. SKIP for pure test edits, docs-only changes, or infra/ cluster wiring.
---

# task-authoring

**Read [`docs/agent/task-authoring.md`](../../../docs/agent/task-authoring.md) now** — it is the
full decision procedure, worked examples, and checklist.

That file is the source of truth and is deliberately not duplicated here: the
same content is reached by agents that read `AGENTS.md` instead of Claude
skills, and one copy cannot drift from another. This file exists only to give
Claude Code the trigger contract in the `description` above.
