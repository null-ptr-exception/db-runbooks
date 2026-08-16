#!/usr/bin/env bats

# The project guide is AGENTS.md, so that every coding agent reads it and not
# just Claude Code. CLAUDE.md is a stub that imports it.
#
# ~128 references across the codebase were rewritten from "CLAUDE.md" to
# "AGENTS.md" in one mechanical pass. Nothing stops the old name creeping back
# in — a copy-pasted script header, an agent trained on the old layout, a
# reverted hunk — and a comment pointing at a 16-line stub sends the reader
# nowhere useful. This pins the rename.

setup_file() {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
  export REPO_ROOT
}

# Three files may name the old path, each for a structural reason: the stub
# itself, AGENTS.md where it explains the import, and this test, which cannot
# grep for a string without containing it. That is a closed set fixed by the
# layout, not an exemption list that grows as people add violations — a fourth
# entry means the rename is regressing and belongs in the diff, not in here.
@test "nothing references CLAUDE.md except the stub and AGENTS.md" {
  run bash -c "cd '$REPO_ROOT' && grep -rl 'CLAUDE\.md' \
    --include='*.md' --include='*.yaml' --include='*.yml' \
    --include='*.sh' --include='*.bats' . 2>/dev/null \
    | sed 's|^\./||' \
    | grep -vx 'CLAUDE.md' \
    | grep -vx 'AGENTS.md' \
    | grep -vx 'tests/unit/aqsh/project_guide_reference.bats' | sort"

  if [ -n "$output" ]; then
    echo "These files still point at CLAUDE.md, which is now a 16-line stub." >&2
    echo "The project guide is AGENTS.md — update the reference:" >&2
    echo "$output" >&2
  fi

  [ -z "$output" ]
}

@test "CLAUDE.md imports AGENTS.md on its first line" {
  local first
  first="$(head -1 "${REPO_ROOT}/CLAUDE.md")"

  # Claude Code expands @path imports at session start. If this line is lost,
  # Claude silently loses the entire project guide while every other tool that
  # reads AGENTS.md keeps working — a failure mode nothing else here detects.
  [ "$first" = "@AGENTS.md" ]
}

@test "AGENTS.md carries the project guide, not a pointer to it" {
  # Guards against someone reversing the direction of the import and leaving
  # AGENTS.md as a stub, which would break every non-Claude agent.
  run grep -c '^## ' "${REPO_ROOT}/AGENTS.md"
  [ "$status" -eq 0 ]
  [ "$output" -ge 8 ]

  run grep -q '^## Configuration Layers$' "${REPO_ROOT}/AGENTS.md"
  [ "$status" -eq 0 ]
}
