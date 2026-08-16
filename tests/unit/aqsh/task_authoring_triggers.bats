#!/usr/bin/env bats

# The task-authoring guidance has one body (docs/agent/task-authoring.md) that
# every agent adapter points at, so the body cannot drift. What each adapter
# must carry itself is its trigger metadata — and that IS duplicated, because
# no tool can read another's format:
#
#   docs/agent/task-authoring.md   glob list (source of truth)
#   AGENTS.md                      glob list, for agents that read AGENTS.md
#   .claude/skills/.../SKILL.md    `description:`, the only thing Claude sees
#                                  when deciding whether to load the skill
#
# Two copies of a list is a registry, and registries drift. This pins them.

setup_file() {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
  export REPO_ROOT
  SSOT="${REPO_ROOT}/docs/agent/task-authoring.md"
  AGENTS="${REPO_ROOT}/AGENTS.md"
  SKILL="${REPO_ROOT}/.claude/skills/task-authoring/SKILL.md"
  export SSOT AGENTS SKILL
}

# The bullet list between the TRIGGER-GLOBS markers, one glob per line.
globs_between_markers() {
  sed -n '/TRIGGER-GLOBS-START/,/TRIGGER-GLOBS-END/p' "$1" \
    | sed -n 's/^- `\(.*\)`$/\1/p'
}

@test "AGENTS.md trigger globs match docs/agent/task-authoring.md" {
  run bash -c "$(declare -f globs_between_markers); \
    diff <(globs_between_markers '$SSOT') <(globs_between_markers '$AGENTS')"

  if [ "$status" -ne 0 ]; then
    echo "Trigger glob lists have drifted." >&2
    echo "  '<' = in docs/agent/task-authoring.md only" >&2
    echo "  '>' = in AGENTS.md only" >&2
    echo "$output" >&2
  fi

  [ "$status" -eq 0 ]
}

@test "Claude skill description covers every trigger glob" {
  local description missing=""
  description="$(sed -n 's/^description: //p' "$SKILL")"

  [ -n "$description" ]

  while IFS= read -r glob; do
    # A recursive "dir/**" is written as the plain directory prefix in prose.
    local needle="${glob%\*\*}"
    case "$description" in
      *"$needle"*) ;;
      *) missing="${missing}${missing:+, }${glob}" ;;
    esac
  done < <(globs_between_markers "$SSOT")

  if [ -n "$missing" ]; then
    echo "SKILL.md description does not mention: ${missing}" >&2
    echo "Claude only sees the description when deciding to load the skill," >&2
    echo "so a path missing from it is a path the skill will not trigger on." >&2
  fi

  [ -z "$missing" ]
}

# Guards the extractor: a marker rename or a reformat of the bullet list would
# otherwise make both sides empty and pass the diff above while checking nothing.
@test "trigger glob extraction returns a non-empty list" {
  run globs_between_markers "$SSOT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -gt 0 ]
}
